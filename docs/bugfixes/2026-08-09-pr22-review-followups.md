# 2026-08-09 PR#22 复审四连：忘升格式版本、检测敢猜、metadata 绕开可听合同、选择不互斥

- **日期**：2026-08-09
- **来源**：PR #22（`fix/subtitle-panel-translation-and-track-ux`）合并前复审，
  base..b72a30b 三个 P1 + 一个 P2，均未发布即修复
- **相关**：[2026-08-09-subtitle-translate-after-same-language](2026-08-09-subtitle-translate-after-same-language.md)
  （本次是它的 follow-up）、
  [architecture/video-edit-project-file](../architecture/video-edit-project-file.md)、
  [architecture/subtitle-language-flow](../architecture/subtitle-language-flow.md)、
  [architecture/subtitle-track-visibility-and-layout](../architecture/subtitle-track-visibility-and-layout.md)、
  [2026-08-04-transform-review](2026-08-04-transform-review.md)（同一个「忘升版本」的坑）

## 症状

1. **[P1] 用旧版打开新工程，字幕排版被静默删光。** 新版把 `subtitleLayout`
   （位置/换行宽度/字号倍率）和 `subtitleHidden`（眼睛）存进工程，但
   `latestFormatVersion` 还是 5。只认 v5 的旧版照常打开，用户随手编辑一下
   触发自动保存 —— 两个键消失，字幕位置/宽度/字号回默认，**导出画面跟着变**；
   本来设了「不要烧字幕」的工程还会把字幕烧进成片。
2. **[P1] 自动检测把错误模型判成成功。** 只装了中文模型的 Mac 上放英文视频，
   Auto-detect 会「成功」选中中文，整轨按中文模型生成一串乱码字幕 ——
   用户看到的是「字幕生成完成」，不是「检测不出来，请手选」。
3. **[P1] 隐藏的主轨仍在替素材「指定语言」。** 隐藏英文主轨 + 可听日文
   overlay 的工程：检测拿英文当最高优先级候选（还是唯一允许触发模型下载的
   那个），探针却抽的是日文 overlay。
4. **[P2] 先点形状、再点字幕 cue，预览上同时挂两套框。** 反方向同理；
   切工程之后，上一条工程的 cue 选择还留着。

## 根因

### 一、`latestFormatVersion` 又忘了 +1

2026-08-04 的 transform 评审已经把这条写死过：**判断要不要升版本，问的不是
「新版能不能读旧文件」，而是「旧版拿到新文件会不会毁数据」。** 这次两个字段
都走了宽容 Codable（缺键回退），于是「新读旧」一路绿灯，
`subtitle-track-visibility-and-layout.md` 里甚至白纸黑字写着
「`subtitleHidden` 走宽容 Codable，不升 formatVersion」—— 宽容解码只解决
一个方向，另一个方向只有版本闸门能拦。

更糟的是自检**帮着守住了错误行为**：`checks/ProjectFile` 里有一条
`check(VideoEditProjectFile.latestFormatVersion == 5, "reader 上限应是 v5")`。
拿常量跟自己比是自反断言，版本忘了升它照样绿，还顺手把「v6 必须拒开」钉成了
合同 —— 正是 2026-08-07 那轮点名的假绿形态。

### 二、阈值订在了错误模型的分数之下

`minimumConfidence = 0.45` 的注释写着「只兜『候选里没有正确语言』」。但同一
批实测数据里，错误模型（zh_CN 转英文音频）的加权分是 **0.55**，实测上限
**0.74** —— 全都在 0.45 之上。所以「兜底」从来没兜住过：
`pick([wrongModel])` 会自信地返回它。没有 confidence 的词按中性 0.5 计，
同样过线，于是「系统一个证据都没给」也算检测成功。

生产代码还有第二道口子：`candidates.count == 1` 时**整段探针跳过**，直接采用。
候选表是「这台 Mac 装了哪些模型」决定的，跟素材说什么语言毫无关系 ——
只装一个模型时，任何语言的视频都会被判成那个语言。这与架构文档写的
「候选之外的语言检测不出来，失败文案必须引导手选，不许硬猜」直接冲突：
文档说不许硬猜，实现留了一条零证据的捷径。

### 三、`metadataLanguageTag` 自己又扫了一遍时间线

`TranscriptionTask.detectSourceLocale` 已经收到过滤后的 `[SoundClip]`
（`soundClips(in:)` 复刻的可听合同），但 `metadataLanguageTag(state:)` 拿的是
`state.mainClips + state.audioTracks.flatMap(\.clips)`：不理 `mainHidden`、
不理 `lane.isHidden`、不理 `isMuted`/`volume`，还整个漏掉带声音的 overlay。
这是 2026-08-06 案例「可听性只有一份合同」教训的原样复发 —— 那次刚把
`soundClips(in:)` 抄成合同，这次新增的消费者又自己发明了一套子集。

### 四、互斥规则散在三个地方，漏了两条边

`selectedClipIDs.didSet` 清 shape、`selectedShapeID.didSet` 清 clip、
`selectSubtitleCue` 清 clip —— 三处各写各的，谁也没负责 shape ↔ cue 这一对。
`closeCurrentDocument` 手抄了两行清理，字幕 cue 是后加的字段，没人回去补第三行。
**只要互斥是靠「每个入口自己记得清」实现的，加第三类选择的那天就一定会漏。**

## 修复

### 一、工程格式升到 v6

- `VideoEditProjectFile.latestFormatVersion` 5 → 6，版本史补齐 v5/v6 两行。
- `TimelineState.requiresFormatVersion6` 新登记项：`subtitleLayout` +
  `subtitleHidden`（`VideoEditFormatVersion.swift`，判据注释写清「为什么这两个
  字段旧版丢了会毁数据」）。writer 一律写 latest（v5 起的既有政策），
  v1–v5 继续宽容读取。
- 自检重写：写盘版本号一律**写死 6**（外部真值，不引用常量）；新增
  「v6 往返布局+隐藏」「v5 老工程缺两个键 → layout=nil / hidden=false，
  且既有字段照常读回」「v7 必须拒开」；删掉 `latestFormatVersion == 5` 那条
  自反断言。

### 二、检测改成 fail-closed

- `SubtitleLanguageDetection.minimumConfidence` 0.45 → **0.80**。取值理由写进
  注释：判别区间是实测的 (0.74, 0.91)，0.80 落在中段偏保守一侧，离错误模型
  上限留 0.06、离正确模型下限留 0.11。**并且把这两个边界做成断言** ——
  以后谁想调这个数，先得让 `minimumConfidence > 0.74` 和 `<= 0.91` 两条过。
- 无置信度的中性分抽成具名常量 `unknownConfidence = 0.5`，配一条结构性断言
  `unknownConfidence < minimumConfidence`：**「系统没给证据」永远不许过线**。
  平台哪天整体不回报置信度，全候选一起跌到 0.5 → 检测失败 → 引导手选，
  这正是 fail-closed 要的结局。
- 删掉生产代码里的 `candidates.count == 1` 捷径：**候选只有一个也要过探针**。
- 短素材策略保持不变但写明白：词数不足时退回全体比较，放宽的只是「谁有资格
  参赛」，置信度门槛一步不让。

### 三、metadata 只消费冻结的可听快照

- 新文件 `SubtitleGen/SubtitleAudibleClips.swift`：把 `SoundClip` /
  `soundClips(in:)` 从 `TranscriptionTask` 搬出来（那个类是
  `@available(macOS 26)` 的 `@MainActor` 状态机，自检编不动），再加
  `detectionSources(in:)` —— 从快照里挑探针（必须是磁盘上真实存在的文件）
  并排出 metadata 查询顺序，**探针打头**。
- `metadataLanguageTag(state:)` → `metadataLanguageTag(in clips: [SoundClip])`；
  `detectSourceLocale` 的 `state:` 参数**直接删掉**。它在类型上就够不着
  `TimelineState`，也就不可能再分叉出第二套声音来源 —— 比注释和 code review
  都可靠。

### 四、互斥收进一个值类型

- 新文件 `VideoEditSelection.swift`：`EditSelection` 三个字段全
  `private(set)`，唯一的改法是 `selectClips` / `selectShape` /
  `selectSubtitleCue` / `clear` / `pruneClips` / `pruneSubtitleCue`。
  每个 select 都清另外两类，**漏边在类型层面不可能发生**。
- `VideoEditProject` 的 `selectedClipIDs` / `selectedShapeID` /
  `selectedSubtitleCueID` 改成它的计算属性门面（`@Published var selection`
  负责发通知），所有既有调用点一字不改。
- `closeCurrentDocument` 改调 `clearSelection()`；预览空白点击、时间线空白
  点击也统一成它（时间线原本漏 cue、预览原本漏 shape，现在两边同一语义）。
- 失效 cue 的清理挂在 `state` 的 `didSet` —— 时间线的**所有**写入都经过那里，
  删字幕轨 / 外挂新 .srt / 重新生成换掉整轨 cue 身份时自动摘掉旧选择。
  只在真选着 cue 时才遍历，拖布局框那种高频写入不额外付代价，
  **一步撤销的语义（liveApply + endLiveEdit）没有改动**。

## 验证

### 自检（全部做过反向验证，先红后绿）

| 撤掉的修复 | 实测红的条数 |
| --- | --- |
| `latestFormatVersion` 6 → 5 | ProjectFile **8** 条（写盘版本号那批全线红） |
| 版本闸门放开成 `<= 99` | ProjectFile **2** 条（v7 拒开 + 未来版本拒开） |
| `subtitleHidden` 缺键回退改 true、`subtitleLayout` 不落盘 | ProjectFile **4** 条 |
| `minimumConfidence` 0.80 → 0.45 | SrtFlowCoreChecks **9** 条 |
| `soundClips` 退回旧的「扫 mainClips+audioTracks、不看隐藏/静音」 | ProjectFile **5** 条 |
| `detectionSources` 不看 fileExists、metadata 不以探针打头 | ProjectFile **2** 条 |
| `EditSelection` 退回散装互斥（漏两条边 + clear 漏 cue + 不 prune） | ProjectFile **4** 条 |
| 把 `candidates.count == 1` 捷径加回去 | 接线守卫红 |
| `closeCurrentDocument` 改回只清剪辑 | 接线守卫红 |

**接线守卫**（新增，挂在 `scripts/check-project-file.sh` 末尾，不单开
check-all 条目）：自检编不动 `VideoEditProject` / `TranscriptionTask` 这两个
App 类型，所以「函数被没被调用、参数对不对」在源码层面钉住 —— 要求
`selection = EditSelection()`、`pruneSubtitleCueSelection()`、
`clearSelection()`、`SubtitleAudibleClips.detectionSources(in:` 、
`metadataLanguageTag(in clips: [SoundClip])` 存在，禁止
`state.mainClips + state.audioTracks` 与 `candidates.count == 1` 再出现。
这一条直接冲着 2026-08-07 Phase 2–4 的病根去：**纯函数写对了但没被接上**。

### 命令

- `swift build --arch arm64`：零错误（仅既有的 NSEvent Sendable 警告）。
- `scripts/check-all.sh`：**11 项全绿**（脚本当前就是 11 项，本次没有新增
  第 12 项 —— 接线守卫并进了 project-file 这一项里）。
  - `SrtFlowCoreChecks` 678 项、`check-project-file` 161 项。
- `git diff --check`：干净。

### GUI 冒烟（真实窗口，2026-08-09，macOS 26）

按 docs/testing/gui-smoke-testing.md：`SrtFlowDev.app`（改名 + ad-hoc 签名）+
`SRTFLOW_SMOKE_VIDEO=tone.mp4:tone.srt`。素材是 vendor/ffmpeg 现造的
**25s testsrc2 + 440Hz 纯音调（无人声）+ 3 条 cue 的 .srt** —— 纯音调正是
「检测不出来」的低可信素材。按窗口 ID 截图，每次注入后截图核实再走下一步。

1. **shape → cue**：Add ▸ Rectangle（形状当场选中，预览出现八把手变换框、
   检查器显示 Rectangle）→ 点轨道上第一条 cue → **变换框消失**、字幕拖框出现、
   检查器回到 Project、播放头跳进该条（0:01.1）。
2. **cue → shape**：接着点预览里的矩形 → **字幕拖框消失**、变换框回来、
   轨道上 cue 取消高亮。两向互斥都是一套框，没有并存。
3. **布局调整 → 存盘 → 重开**：拖字幕框体上移 → ⌘S 存成
   `~/Movies/smoke-pr22.srtflowproj`。文件实测
   **`formatVersion = 6`**、`subtitleLayout = {marginLeft 80, marginRight 80,
   marginBottom 381, fontScale 1}`（默认 marginBottom 是 54，381 就是这次拖上去
   的量）。File ▸ New Project（空工程，**无残留选择**）→ 从 Recent Projects
   重开 → 字幕仍渲染在抬高后的位置，且**没有**悬空拖框。
4. **隐藏字幕不预览/不烧录**：点字幕轨眼睛 → 图标变 eye.slash（橙）、行灰显、
   预览字幕消失。导出面板出现橙字
   「Subtitle track is hidden — nothing will be burned.」。**真跑了一次导出**，
   对产物 2.0s 处抽帧（cue 1 的区间是 1–4s）：画面里**没有字幕**，但那个矩形
   形状**烧进去了** —— 证明叠层管线确实在跑，字幕的缺席来自 `subtitleHidden`
   而不是「什么都没渲染」。
5. **Auto-detect 低可信引导手选**：Source language 保持 Auto-detect →
   Generate Subtitles → 确认替换 → 探针跑完后面板出红字
   **「Couldn't confidently detect the spoken language. Pick it in the panel
   and generate again.」**，时间线上原有的 3 条 cue **原封不动**（没有被一轨
   乱码顶掉）。

**这次冒烟没有覆盖到的**（如实记录，别当已验证）：

- 冒烟证明的是 fail-closed **这条路走得通**；「阈值 0.45 会放行错误模型」和
  「单候选直接采用」这两个具体回归由自检 + 反向验证钉住，纯音调素材区分不了
  它们（无人声时词流本来就空）。
- 「隐藏的英文主轨 + 可听的日文 overlay」这个 metadata 反例没有真机复现 ——
  需要两份带不同音轨语言 metadata 的真实素材，本次只由 checks/ProjectFile 的
  可听快照用例 + 接线守卫覆盖。
- 「调整后导出的烧录位置/宽度/字号与预览逐像素一致」不在本次范围（原有
  人肉清单里的条目，仍待发版前过）。

## 教训 / 防回归

1. **同一个坑第二次踩，说明防线建在了注释上。** 2026-08-04 已经写过「加字段
   必须升版本」，这次照样漏 —— 因为唯一的守卫是一条自反断言。**版本号这类
   「必须随改动同步变化」的常量，断言里要写死外部真值**，拿常量跟自己比等于
   没写。
2. **阈值必须由数据反推，并且把数据本身钉成断言。** 「0.45 只兜极端场景」是
   拍脑袋，同一份实测里错误模型就在它之上。修法不只是换个数，而是把
   (0.74, 0.91) 这个判别区间写成两条 check —— 下一个人调参时会被区间挡住，
   而不是被一句注释劝住。
3. **「没得挑」不是「挑对了」。** 单候选直接采用、无置信度按中性计，两处都是
   把「零证据」当成了「弱证据」。涉及会整轨生效的自动判定，默认结局必须是
   失败 + 引导手选。
4. **合同要靠类型强制，不靠调用方自觉。** 三处修法同一形状：删掉
   `detectSourceLocale` 的 `state:` 参数、`EditSelection` 字段全
   `private(set)`、可听快照只有一个具名产地。**能让错误写法编不过，就别写在
   注释里。**
5. **纯函数写对 ≠ 被接上。** 自检编不动的 App 类型，接线用扫描守卫补 ——
   一条 grep 比再评审一轮便宜（2026-08-07 Phase 2–4 教训的复用）。
