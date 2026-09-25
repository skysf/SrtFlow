# 2026-09-25 松手重建预览把每个素材重新打开一遍、还白叫醒整个编辑器

## 症状

接着[拖动会话住在时间线的 @State 里](2026-09-25-drag-session-in-timeline-state.md)那一轮量：
拖动每拍已经降到 3–4 ms，一次「拖一段音频 30 拍」还是要 800 多毫秒 CPU、2 秒墙钟，大头在**松手那一下**。
南极工程（77 段、9 条音轨）松手一次的账（进程内冒烟驱动的 `perf` 快照）：

| 计数 | 修前 |
| --- | --- |
| `composition.assetOpen`（开素材文件） | **63** |
| `composition.build` | 1 |
| `meters.tapCreate`（电平表 tap） | 22 |
| `project.willChange`（工程发「要变了」） | **6** |

## 根因

两处，互不相干：

1. **每次重建都把每个素材重新打开。** `VideoEditCompositionBuilder.build` 里那个「同一个文件出现几段
   只开一次」的 `assets` 字典是**这一次 build 的局部变量**：一松手 `scheduleRebuild` → 250 ms 防抖 →
   `build(from:)` 整个重来，工程里每个文件重新 `AVURLAsset(url:)` + `loadTracks`，文件头逐个重新
   解析。61 个文件、每次松手。
2. **重建的开始和结束都在工程上发通知。** `isRebuildingPreview`（给工具栏那个小转圈用的）和
   `renderSize` 都是工程上的 `@Published`，`scheduleRebuild` 开头写一次、收尾各写一次（`renderSize`
   十有八九没变）。工程上每发一次 `objectWillChange`，订阅工程的所有视图（提示修饰器、轨道头、
   工具栏、检查器、转场库的 33 张卡片）就各重算一遍 —— 为的只是一个转圈。

## 修复

- 新文件 `VideoEditMediaAssetCache.swift`：`MediaAssetCache` 按**路径 + 文件身份**缓存 `AVURLAsset`；
  builder 的 `asset(for:)` 走它，`composition.assetOpen` 从此只记真开了文件的那几次。身份是
  inode + 卷（换成了别的文件：删了再放回同名的、先写临时文件再改名盖过来）**加上大小 + 修改时间**
  （原地改写：`ffmpeg -y` 往同一个输出路径写是截断重写，inode 不变）—— 比存盘的书签缓存
  （[案例](2026-09-24-autosave-rebuilds-bookmarks-every-save.md)）多认两样：书签跟着 inode 走，原地改写
  不影响它；缓存的 asset 却已经读过旧的文件头，接着用会按旧的采样表去读新内容。路径不存在不缓存、
  照旧现开，让 builder 自己跳过那一段。最多 256 个，超了丢最久没用的。
- 「正在重建」挪出工程：新文件 `VideoEditPreviewRebuildStatus.swift` 里一个小 `ObservableObject`
  （`PreviewRebuildStatus`，只在变了时发）和唯一订阅它的转圈（`PreviewRebuildSpinner`）；工程里的两处
  判断（快路径让路、冒烟的「落定」）直接读值。`renderSize` 没变不写。
- 长期约束写进[工程文件与素材重链接](../architecture/video-edit-project-file.md)「运行中素材只开一次」；
  [预览性能 ratchet](../architecture/preview-perf-ratchet.md)第二节注明 `assetOpen` 的口径。

### 第一版错在哪

第一版把 `isRebuildingPreview` 直接摘掉 `@Published`，理由是「没有视图读它」—— 其实工具栏那个转圈
就在读（`if project.isRebuildingPreview { ProgressView() }`）。不发通知的值被视图读，转圈就只在别的
东西碰巧叫醒整个编辑器时才更新。实测没卡住，全靠重建收尾时 `PlayerClock.attachItem` / `seek` 无条件写
自己的 `@Published`，根视图订阅着时钟、顺手把转圈也重画了 —— 哪天时钟改成「没变不写」（那正是下一步要
做的），转圈就会一直转下去。复审时 grep 一遍 `isRebuildingPreview` 才发现。

## 验证

同一份工程拷贝、同一份步骤表（`perf.json` 的「拖一段音频 30 拍」，含松手重建 + 0.6 s 落定），各连跑
两遍、计数两遍一模一样。修前是在同一份代码上临时把 builder 改回现开、把两次发通知补回来量的：

| 计数 / 时间 | 修前 | 修后 |
| --- | --- | --- |
| `composition.assetOpen` | 63 | **0** |
| `project.willChange` | 6 | **3** |
| 视图 body 次数 | 753 | 659（含转圈自己的 2 次：出现、消失） |
| 进程 CPU | 857–860 ms | 752–786 ms |
| 墙钟（含 250 ms 防抖 + 重建 + 0.6 s 落定） | 2021–2026 ms | 1889–1925 ms |

开 63 个文件的活大半是等 I/O，CPU 看不全；用户感受到的是**预览多久才回来**，所以冒烟驱动的 `perf`
快照从这次起多记一份墙钟 `wallMs`。转圈的 body 在整轮测试里只在这一步出现、正好 2 次（重建开始、结束），
别的视图不再为它重算。

自检 `scripts/check-preview-composition.sh` 新增 `checks/PreviewComposition/AssetCache.swift`：同一份
状态建两次，第二次一个文件都不重开、三个时刻取出来的帧和第一次一样；同一路径换成黑视频（删了
再拷 = 新 inode）之后必须重开、帧变黑；再建又命中；**原地改写**成白视频（`FileHandle` 截断重写，
用例先确认 inode 没变）之后也必须重开、帧变白。212 项全绿。**反向验证**：缓存不比 inode → 「换成黑视频
之后取出来的帧必须是黑的」红；只比 inode + 卷（第一版）→ 「原地改写过也必须重开」和「原地改写成白视频
之后帧必须是白的」红（实测亮度 0.0：拿着旧 asset 读新文件，读出来还是黑的）；builder 改回现开 → 「第二次
建合成不许重开」红。「转圈只订阅自己那个开关」钉在 `checks/preview-perf-wiring.sh` 最后一节（工程上不许有
发通知的重建开关、工具栏用 `PreviewRebuildSpinner`、别的视图不许直接读值），反向两条都红过。

真窗口功能回归（同一驱动、1180×860）：点选、转场卡片、拖音频 / 文字 / 字幕 cue（译文跟着走）、框选、
裁切、刀片、音量点、跨轨、插入缝、⌘A / ⌘⇧A、文字换行照常；重建落定之后转圈不在。

## 之后：防抖 250 → 120 ms（单独一个提交）

`scheduleRebuild` 的防抖只为把一阵子里的连续改动并成一次重建（连按 ⌘Z、连按 ⌫ 这类，间隔短于防抖就
并得住）；滑杆和拖动走 `liveApply`、松手才排一次重建，不靠它并。250 ms 时松手到预览回来白等那么久，
降到 120 ms：同一步（拖一段音频 30 拍）墙钟 1889–1925 → **1793–1807 ms**，计数一个不变（CI 的
`PreviewBench` 每一刀之间等 0.6 s，`composition.build` 的次数不受影响）。同一轮里整份步骤表的 body 总数还少了
一轮（2077 → 1848），那是自动保存的 2 秒防抖碰巧把两次存盘并成了一次 —— 脚本节奏的巧合，不算这一刀的账。

## 教训 / 防回归

- **「一次 build 内只开一次」和「这次会话里只开一次」是两回事。** 局部变量的缓存挡不住「每次松手
  整个重来」；跨 build 的缓存必须自己按文件身份失效，别按路径。**身份要覆盖原地改写**：inode 只认得
  「换了一个文件」，认不得「同一个文件被重写了」。
- **`@Published` 是给视图用的。** 一个大 `ObservableObject` 上每发一次 `objectWillChange` 就是整个编辑器
  一轮重算；只有一个小视图关心的状态，放进只有它订阅的小对象里。**说「没有视图读它」之前先 grep**：
  不发通知的值被视图读，界面就只在碰巧别的东西刷新时才对 —— 这种错平时看不出来。
- **CPU 不动不等于没省。** 进程 CPU 只看到算的那部分，等 I/O 看不见；量「用户等多久」要看墙钟。
- 还留着的：每次重建 22 个电平表 tap 照旧新建（tap 挂在新合成音轨上，合成换了就得换）；要省它得
  「只换变了的轨、在现有 `AVMutableComposition` 上局部改」，风险在
  [推子与电平表](../architecture/audio-mixer.md)第三节第 2、7 条，先做对账再动。重建收尾时时钟无条件写
  `@Published`（`attachItem` / `seek`）、根视图订阅时钟，那一轮整个编辑器的重算还在。
