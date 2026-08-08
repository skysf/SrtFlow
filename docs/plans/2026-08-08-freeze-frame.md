# 规划：定格（Freeze Frame）

- 日期：2026-08-08
- 状态：**已实现并实机验证**（2026-08-08）。v2 按评审意见重做了提交模型与
  分辨率政策；实施与实测结果见文末 §8，长期约束见
  [docs/architecture/freeze-frame.md](../architecture/freeze-frame.md)。
- 范围：Video Edit 工具栏新增「定格」——把播放头下那一帧抽成图片，在播放头处
  把原段切成两半，图片作为一段静止画面插在中间，后面的内容顺推。

## 1. 背景

工具栏现在有分割、裁头尾、删除、分离音频，但没法「把这一帧停住」。

关键判断：**这个功能不需要写任何合成器代码**。仓库里已经有完整的图片素材管线
（`StillImageClipFactory` 把图转成静帧循环视频 → 当普通剪辑用，见
`VideoEditProject.addImages`），定格段直接走它，天生支持转场、变速、画中画、
关键帧、导出，一处特判都不用加。符合 AGENTS.md「轻量化优先 / 复用优先」。

## 2. 已拍板的产品参数

| 项 | 决定 |
|---|---|
| 默认时长 | **2 秒**（插进去就是普通图片段，拖边缘可改，上限 60s） |
| PNG 存哪 | **工程文件所在文件夹**；工程还没保存过 → **Downloads** |
| 波纹范围 | **只推主轨 + 音频轨**；字幕、形状标注、画中画都不动 |
| 适用轨道 | **主轨 + 画中画**都支持 |

## 3. 提交模型：**转码成功后一次性提交**（v2 改动）

原方案抄图片导入的「占位块先上轨、后台转完再替换」，评审指出三个真问题：
异步窗口里目标段可能被改/删、连按两次会并发、以及转码失败时现有代码会用
**第二次 `perform`** 删占位块（`VideoEditProject.swift:560`）——
「一步撤销」的承诺在失败路径上是假的。

所以定格**不用占位流程**，改成事务式：

```
入口：抓快照（目标 clip 的 id / track / sourceURL / sourceStart /
      sourceDuration / speed / timelineStart、切点、documentGeneration）
      + 置 isFreezing
  ↓  抽帧 → 写 PNG → ffmpeg 转静帧 → probeVideo
  ↓  全部成功？
     否 → notice + 删掉这张还没被时间线引用的 PNG + 收工（时间线一动不动）
     是 → CAS：工程代号没变、clip 还在、上面那组关键字段和快照一致、
           **还在同一条轨**、**准入条件整个重跑一遍**（isFreezeEligible）
           → 一次 perform{} 提交，再以「时间线里真有这一段」确认成功
                             ↓ 任何一条不成立 → 同上，当作失败处理
```

收益：

- 定格段**创建即完整**（`sourceURL` 直接是静帧 mp4，`needsStillConversion` 全程
  为 false），撤销/重做严格一步，不需要任何回滚合同。
- 预览不会出现 1~2 秒的黑洞（占位块预览是跳过的）。
- 代价：按下按钮到时间线变化有 1~2 秒延迟。期间 `importingCount` 转圈 +
  **按钮置灰**（`isFreezing` 单飞，连按两次 ⇧⌘F 不会产生两个请求）。

## 4. 顺带修掉的性能 bug（已实测）

`StillImageClipFactory` 现在的命令是 `-loop 1 -i x.png -t 60 -r 2`。
`-loop 1` 的**输入**帧率默认 25fps（image2 demuxer 的默认值），于是 ffmpeg 要
解码 **1500 次**那张 PNG，再丢到只剩 120 帧输出。用 4K 图实测（本机 M1，
`vendor/ffmpeg`）：

| 命令 | 输出 | 耗时 |
|---|---|---|
| 现状（4K 图 → 压到 1080p） | 120 帧 | **19.4s** |
| 改用 `h264_videotoolbox` 硬编 | 120 帧 | 20.5s（证明瓶颈**不在编码器**） |
| 加 `-framerate 2`（其余不变） | 120 帧 | **~1s** |
| 加 `-framerate 2` 且不缩放（4K 原尺寸） | 120 帧 | **2.2s** |

**`-framerate 2` 是纯性能修复，不改任何输出**，独立成一条 bugfix。

### 分辨率政策：只给定格帧开原生尺寸，照片路径一个字不改（v2 改动）

原方案要把全局上限从 1080p 抬到 4K。评审指出这是产品改动而非性能修复：
Auto 画布取 `mainClips.compactMap(\.info).first?.displaySize`
（`VideoEditCompositionBuilder.swift:452`），**图片开场的工程会从 1080p 预览/导出
变成 4K**；而且 `3840:2160` 是横屏边界，2160×3840 竖图会被压成 1215×2160，
根本谈不上「4K 全分辨率」。两条都成立。

改成：

- **拖进来的照片**：1920×1080 上限一个字没动，Auto 画布行为零变化，
  白拿 `-framerate 2` 的提速。缓存键从 `-v2` 升到 `-v3`，**不是因为参数变了**，
  是要作废升级前可能留下的半成品。
- **定格帧**：**只在真的会被缩时**才走原生政策（完全不加 scale，只留偶数宽高的
  pad）。尺寸没过照片上限时两条政策产出完全一样，那就统一走照片政策 ——
  这样政策才能从 `info.displaySize` 唯一反推出来。
- 机制：`stillVideo(for:ffmpeg:nativeResolution:)` 带显式政策参数，缓存文件名按
  政策分开（`-v3.mp4` / `-native-v1.mp4`），**`cachedStillVideo(for:nativeResolution:)`
  也必须显式带政策**（「两条都查、原生优先」会让同一张 PNG 被两种政策共用时串线）。
- 唯一判据是 `StillImageClipFactory.needsNativeResolution(for:)`，它对「源尺寸」
  和「产物尺寸」给出同一个答案，所以缓存被系统清掉后能从工程文件里存着的
  `info.displaySize` 反推出原政策。重生成路径（`refreshStillClips` →
  `regenerateStills`）按 **(图, 政策)** 分组，落地时只更新同政策的段。

### 缓存原子性（评审附加项，一并修）

`StillImageClipFactory` 现在直接往最终路径写、且只用 `fileExists` 判命中：
转码被中断或并发跑同一个 key，会留下**永久命中的半成品 mp4**。
改成先写 `<key>.partial.mp4`、成功后同目录 `moveItem` 原子改名。

## 5. 改动清单

### 5.1 `Sources/SrtFlow/StillImageClipFactory.swift`

- 输入加 `-framerate 2`。
- 加 `nativeResolution` 参数（跳过 scale）+ 分政策的缓存键（`-v3` / `-native-v1`），
  `cachedStillVideo(for:nativeResolution:)` **按政策路由，不再两种都查**。
  唯一判据 `needsNativeResolution(for:)`，另开 `cacheFileURL(...)` 给自检造缓存用。
- 临时文件 + 原子改名（直接搬、失败再看目标在不在，避开 TOCTOU）。
- 注释写清「输入帧率必须跟着输出帧率走」这条坑。

### 5.2 新文件 `Sources/SrtFlow/VideoEditFreezeFrame.swift`

`VideoEditProject` 的扩展，单独开文件 —— `VideoEditProject.swift` 已在 AGENTS.md
的超标待瘦身名单里，不再往里堆。

**`freezeTarget()` / `canFreezeFrame` / `isFreezeEligible(_:at:)`**，禁用条件：

- 纯音频段、图片段、还在转静帧的占位段；
- **选中多段且不止一段包着播放头 → 直接返回 nil**（「不猜」不能又回落到主轨）；
- **所在轨被藏起来 → 禁用**（隐藏轨在预览和导出里都当不存在）；
- **主轨上牵扯转场的段 → 禁用**（`participatesInMainTransition`）：转场的 45%
  上限会因为切短而重算，画面位移就不等于定格时长，而音频只顺推固定时长 ——
  实测错位 0.325s。这是 v3 收严的最重要一条；
- **播放头落在主轨叠化区里 → 禁用**（`isInsideMainTransition`）：那一帧是两段
  合成出来的，从单个源素材抽帧必然对不上。

准入条件独立成 `isFreezeEligible`，**入口和提交前的 CAS 各跑一次** —— 异步窗口
里用户可以加转场、挪轨、藏轨。

**`freezeFrameAtPlayhead()`** —— 按 §3 的事务流程，沿用
`documentGeneration` / `isCurrentGeneration` / `trackImportTask` 守卫：

1. **抽帧**：`AVAssetImageGenerator`，`appliesPreferredTrackTransform = true`，
   `dynamicRangePolicy = .forceSDR`（显式写死，让色调映射可预期；HDR 见 §7），
   **前后容差都设 `.zero`**。零容差失败才退回半帧容差，且半帧要用
   **source 空间**的容差（`KeyframeTrack.sourceTolerance(frameRate:speed:)`
   已经是现成的、注释里专门讲过这个空间陷阱）。取回的 `actualTime` 与请求时刻
   相差超过半帧时记进 notice —— VFR / 低帧率素材上「所见即所定」是尽力而为。
   源时刻用现成的 `clip.sourceTime(atTimeline:)`（自动处理变速和裁头尾）。
2. **写 PNG**：`<工程文件夹 ?? Downloads>/<素材名>-freeze-<00m12s34>.png`，
   文件名里的 `/` `:` 先净化，重名自动加 `-2`/`-3`。
3. **转静帧 + 探测**：`StillImageClipFactory.stillVideo(...)`（政策由
   `needsNativeResolution(for:)` 按这一帧的实际像素尺寸决定，不是无条件原生）
   → `probeVideo`。**任何一步失败或 CAS 不过，都删掉这张 PNG**（它还没被任何
   时间线引用），时间线一动不动。
4. **提交**：一次 `perform {}`：
   1. `VideoEditProject.split()` 在播放头切开目标段；
   2. 同轨切口右边的所有段 `timelineStart += 2`；
   3. 定格段插在左半后面（磁吸开着 `packMain()` 会重排，磁吸关着靠第 2 步
      手动推 —— 一条代码路径两种情况都对）；
   4. **目标在主轨时**：音频轨上跨切口的段也 `split()` 切开，切口右边的音频段
      同样右移 2s（不切开的话它的后半段会比画面早 2 秒）。目标在画中画轨时
      只推那一条轨，不动全局音频。

**第 4 步整体抽成 `TimelineState` 上的纯函数**（`insertFreeze(_:after:at:)`），
不碰 AVFoundation / ffmpeg / 磁盘 —— 这样 §8 的时间线回归能在 checks 里
无 GUI 跑（照 `checks/ProjectFile`、`checks/PlayerClock` 的现有先例）。

**定格段继承什么**：placement / crop / rotation / flip / opacity / overlayFraction /
overlayAnchor 全部照抄原段（PNG 是未裁剪的原始帧，继承 crop 后画面完全一致）。
原段**有关键帧动画**时，用现成的 `animatedPlacement` / `animatedRotation` /
`animatedOpacity` 取那一刻的值烘成静态值、`animation` 置 nil —— 否则接缝处画面会跳。
`transitionAfter = .none`（两边硬切），不进 `linkGroup`。

### 5.3 `Sources/SrtFlow/VideoEditProject.swift`

两处去掉 `private` 给新文件用，不改逻辑：
`static func split(_:clipID:at:)`、`func probeVideo(_:)`。

### 5.4 `Sources/SrtFlow/VideoEditView.swift`

剪刀右边加 `ToolbarIcon(icon: "snowflake")`，help
「Freeze the frame at the playhead」，快捷键 **⇧⌘F**（当前未占用），
置灰条件 `!project.canFreezeFrame || project.isFreezing`。

### 5.5 本地化

`en.lproj` / `zh-Hans.lproj` 各补：按钮 help、抽帧失败、写图失败、
转码失败、「素材在定格过程中被改动，请重试」、actualTime 偏差提示。

### 5.6 文档（AGENTS.md 硬规则）

- `docs/bugfixes/2026-08-08-still-clip-loop-decode-slow.md`：静帧转码 19s 的
  症状 → 根因（`-loop 1` 输入帧率默认 25fps）→ 修复 → §4 实测表 → 教训。
- `docs/bugfixes/` 再补一条静帧缓存半成品（原子改名）的案例。
- 定格的行为约定（事务式提交、推主轨+音频、不动字幕/形状/画中画、
  叠化区禁用、撤销后 PNG 留盘）落到 `docs/architecture/`，案例和代码注释链过去。
- 本文件 + 上述案例都要回 `AGENTS.md` 补索引行。

## 6. 已知代价（明确不做）

- **字幕、形状标注、画中画都不跟着推**：定格点之后会和画面差 2 秒，需要手动补。
  （字幕/形状是拍板行为；**画中画**是评审第 4 条点出的遗漏，现补进本表。）
- **主轨上牵扯转场的段定格按钮是灰的**：转场的 45% 上限会因为切短而重算，
  画面位移就不等于定格时长，音频却只顺推固定时长 —— 实测错位 0.325s。
  想定格先把那条转场去掉。（⌘B 分割也有同样的长度重算，只是它不推音频。）
- **播放头在主轨叠化区里时也是灰的** —— 不支持对合成画面定格。
- **隐藏轨上的段不给定格** —— 隐藏轨在预览和导出里都当不存在。
- **成功提交后那张 PNG 留在工程文件夹里** —— 重做要靠它。失败/取消/过期请求
  产生的 PNG 会被删掉，不留垃圾。
- 工程另存到别的文件夹后，老的定格 PNG 不跟着搬；文件还在原处就能正常打开，
  被挪走才会触发现有的重链接提示。
- 未保存工程时 PNG 落 Downloads，之后保存工程也不会把它搬过去。
- 定格段最长 60 秒（`StillImageClipFactory.stillDuration` 的现有约束）。
- **HDR 素材的定格帧是 SDR**：整条静帧管线就是 SDR（yuv420p、无 HDR 元数据），
  `forceSDR` 只是把这件事写死成可预期的。要真正保住 HDR 得换 HEIF + HDR 编码，
  超出本次范围。

## 7. 验收

**A. 纯时间线回归**（新增 `checks/FreezeFrame/`，无 GUI、无 ffmpeg，跑纯函数）：
磁吸开/关各一遍、转场边界（叠化区禁用 + 带转场时的长度重算）、
多条音频轨跨切口切开与右移、主轨 vs 各条画中画 lane、关键帧烘焙数值、
撤销/重做严格一步。

**B. 事务与并发**：连按两次 ⇧⌘F（应只出一段）、转码过程中删除/移动/改速目标段
（CAS 应拒绝并删掉 PNG）、中途切工程、构造转码失败（临时把 ffmpeg 路径指歪）
→ 核对时间线零变化、PNG 不残留。

**C. 构建与既有自检**：`swift build --arch arm64`（Rosetta 终端必须带 `--arch`）、
`swift run SrtFlowCoreChecks`、`scripts/check-project-file.sh`
（定格 PNG 要能跟着存盘/重链接走）、`checks/no-hardcoded-fps.sh`。

**D. 真实窗口冒烟**（`docs/testing/gui-smoke-testing.md`）：`SRTFLOW_SMOKE_VIDEO`
导入视频 → 播放头挪到中间 → 定格 → 截图核对主轨变三段、中间段就是那一帧、
⌘Z 一步还原、PNG 出现在预期目录。

**E. 分辨率**：4K/Retina 录屏上定格，核对插入段**不糊**；同时核对**拖照片进来的
Auto 画布尺寸与修改前完全一致**（证明分辨率政策没外溢）。竖屏素材各跑一遍。

## 8. 实施结果（2026-08-08）

### 落地时与计划的差异

- 纯值变换单独开了 `Sources/SrtFlow/VideoEditTimelineEdits.swift`，
  `split` 从 `VideoEditProject`（超标文件）**搬了出来**成为
  `TimelineState.split(clipID:at:)`；定格段的构造也做成
  `EditClip.makeFreezeClip(...)`，好让关键帧烘焙能进自检。
- 定格时长常量落在 `FreezeFrame.defaultDuration`（纯值文件里），不是
  `VideoEditProject` 上。
- 多加了一道保险：`committed` 以 `state.clip(with: freeze.id) != nil` 为准，
  不因为调过 `perform` 就算成功（`perform` 在无变化时会直接返回）。

### 实测

| 项 | 结果 |
|---|---|
| `scripts/check-freeze-frame.sh` | 50/50 通过（新增） |
| `scripts/check-project-file.sh` | 120 项 0 失败（含新增的分辨率政策回归） |
| `swift run SrtFlowCoreChecks` | 644 项通过 |
| 预览合成 / 导出帧率 / alpha 合成 / no-hardcoded-fps | 全绿 |
| 真机：2560×1440 素材在 2.17s 定格 | 总长 0:10 → **0:12**，主轨 1 → 3 段 |
| 定格段分辨率 | **2560×1440 · 1:00**（没被压到 1080p） |
| 抽的是不是那一帧 | 对源逐帧算 PSNR：第 65 帧（t=2.1667，正是播放头所在帧）23.3dB，邻帧全是 18.5dB；均值 RGB 与源差 ~1/255，无偏色 |
| ⌘Z | 一次回到 0:10 / 1 段，撤销箭头置灰 —— **严格一步** |
| 连按两次 ⇧⌘F | 只出一段（0:12 而非 0:14），第二次连 PNG 都没写 —— 单飞生效 |
| 转码窗口内撤掉目标段 | CAS 拒绝（`clip=false`），PNG 被删干净，时间线零变化 |
| 静帧转码耗时 | 2560×1440 实测 0.878s（修 `-framerate` 之前 4K 要 19.4s） |

### 第二轮评审后的修正（同日）

| 问题 | 修法 |
|---|---|
| **P1** 牵扯转场的主轨段定格会让声画永久错开（实测 0.325s） | 这类段一律不给定格（`participatesInMainTransition`），入口和 CAS 各查一次 |
| **P1** 同一张 PNG 被定格段和普通图片段共用时两条缓存政策串线 | 政策收敛成唯一判据 `needsNativeResolution(for:)`；查缓存必须显式带政策；重转按 (图, 政策) 分组且只更新同政策的段 |
| **P2** 升级前留下的半成品缓存仍会永久命中；搬运有 TOCTOU | 照片缓存键升 `-v3`；改成直接搬、失败再看目标在不在，并清理临时文件 |
| **P2** CAS 身份太弱（没记 track、没排除隐藏轨） | `FreezeRequest` 记 `track`；准入条件抽成 `isFreezeEligible`，CAS 整个重跑一遍；隐藏轨排除 |
| **P2** drift 是源时间却拿时间线半帧比；PNG finalize 失败留半截文件 | 统一用源空间半帧；写盘失败在方法内部就删掉半截文件 |

顺带把「只在真的会被缩时才走原生政策」定死了：尺寸没过照片上限时两条政策产出
完全一样，统一走照片政策，这样政策才能从 `info.displaySize` 唯一反推。

新增回归：转场重新限长 × 音频顺推的错位数字（`checks/FreezeFrame`，50 项）、
同一张 PNG 的两条政策：分成两项重转任务、缓存命中按政策路由、落地只更新同政策的段（`checks/ProjectFile`，120 项）。
实机复验：2560×1440 → 原生 2560×1440；1280×720 → 照片政策且产物仍是 1280×720。

### 排查记录（留给下次）

CAS 那项一开始看着像 bug：PNG 留下了、时间线却没变。加临时日志才看清是**测试
时序**问题 —— ⌘Z 有时落在提交**之后**，撤销掉的是新定格本身，而已提交定格的
PNG 是**按设计**保留给重做的。真正落进转码窗口时（日志 `cas: clip=false`），
拒绝和清理都正确。教训：定格的异步窗口只有 ~1.2s，靠 sleep 卡时序不可靠，
判断成败要看日志而不是猜时间线状态。
