# 规划：原生字幕生成（语音转写 + 翻译）

- 日期：2026-08-06（同日评审修订：分层可用性、canonical/companion 模型、
  sidecar 缓存、按需 formatVersion、里程碑重排等 18 条决定已确认落实）
- 状态：**Phase 0–4 已实现并实测**（2026-08-06，含真实窗口端到端冒烟：
  生成 → 翻译 → 双语预览）；Phase 5 代码已落地，长素材回归与 17.2 的
  实机验证项待跑。各 Phase 实况见第 16 节。
- ⚠️ 2026-08-07 起：本文的「构建基线 tools 5.9 / .v14」与「能力按 macOS
  14/15/26 分层」已被**录屏计划的全局 macOS 15 决策取代**（见
  [录屏计划 §14](2026-08-06-native-screen-recording.md)）。现行分层是
  **15/26**：翻译自基线即可用，语音生成仍需 26+。历史正文按 §14.7 的约定
  保留原样，不改写过去的设计记录。
- 范围：为 SrtFlow 增加完全本地的「语音 → 原文字幕 → 翻译字幕 → 烧录/导出」能力，
  按 macOS 版本分层交付（见 1.1）。

## 0. 证据约定（本文所有结论的可信度标记）

每条 Apple API 结论都带以下一种标记：

- **[SDK]** 已在本机 `MacOSX26.5.sdk`（CommandLineTools，Swift 6.3.3）的
  swiftinterface / 头文件中逐字确认。引用路径形如
  `SDK:Speech.framework/.../arm64e-apple-macos.swiftinterface:335`。
- **[Apple 文档]** 已从 developer.apple.com 官方文档（JSON 数据源）逐句确认。
- **[WWDC25-277]** 已从 WWDC25 Session 277《Bring advanced speech-to-text to your
  app with SpeechAnalyzer》官方转录稿确认。
- **[实测]** 已在本机（macOS 26.5.2，Apple M1）跑命令验证。
- **[待验证]** 以上渠道都无法确认，**必须通过技术原型或真实设备/视频验证后才能承诺**，
  不得凭印象写进对用户的承诺。

本机环境 [实测]：macOS 26.5.2 (25F84)，SDK 26.5，Swift 6.3.3，Apple M1。

---

## 1. 目标、非目标与隐私边界

### 1.1 目标：按 macOS 版本分层交付

构建基线**保持不变**：`swift-tools-version: 5.9` + `platforms: [.macOS(.v14)]`
（`Package.swift:1/:8`）。新能力全部用 availability 隔离，按运行时系统版本分层：

| 运行系统 | 能力 |
| --- | --- |
| macOS 14 | 现有全部功能不变；新功能入口置灰并说明版本要求 |
| macOS 15–25 | 可对**现有/导入**的字幕轨做本地翻译（Translation 核心 15+），译文预览与导出 |
| macOS 26+ | 完整能力：语音转写生成原文字幕 + 翻译 + 双语烧录/导出矩阵 |

1. 在剪辑页对当前工程的音视频做**完全本地**的语音识别，生成原文字幕（26+）。
2. 用 Apple Translation framework 把原文字幕（生成的或外挂/导入的）翻译成
   目标语言字幕（15+）。
3. 原文/译文是**两条关联轨道**：canonical 原文轨 = `TimelineState.subtitle`，
   companion 译文轨共享 cue ID 与时间（见第 7、8 节）。
4. 导出矩阵（第 13 节）：无字幕视频 / 原文烧录 / 译文烧录 / 双语烧录 /
   独立原文 SRT/VTT / 独立译文 SRT/VTT，及自由组合。
5. 长视频可用：流式/分段处理，不整段驻留内存（第 14 节）。

### 1.2 非目标（V1）

- **不升级 swift-tools-version、不切 Swift 6 language mode、不提部署下限**
  （理由与风险见 3.1）。
- 不做启发式自动语言检测（SpeechDetector / 能量 VAD / 多 locale 试识别 /
  融合打分 / 低置信弹窗）。**需求保留**，单列为 V2（见 3.7），
  等基础转写稳定后再做。
- 不承诺 DictationTranscriber 后备。`SpeechTranscriber.isAvailable == false`
  或 locale 不支持时**明确提示不支持**；DictationTranscriber 列为未来 Phase，
  经真机验证后才可能承诺（见 3.6）。
- 不使用 DeepSeek、OpenRouter 或任何云端 API / API Key。
- 不捆绑 Whisper 或任何第三方模型。
- 不做 MP4/MOV 内嵌软字幕轨（现有 `-c:s mov_text` 软字幕能力在烧录队列已存在，
  `Sources/SrtFlowCore/FFmpegCommand.swift:133-136`，但本功能第一版不扩展到生成字幕）。
- 不以 Foundation Models 作为识别或翻译核心；最多列为未来可选的「字幕润色」。
- 不做通用「AI Provider」抽象层 —— 目前只有 Apple 原生一种真实实现，
  按仓库「复用优先、抽象克制」原则（AGENTS.md 全局原则 2），先写具体类；
  出现第二个真实实现时再抽象。
- **V1 只允许一条原文轨 + 一条关联译文轨**；多译文语言、多说话人分轨都是后话。
- 不把词级转写缓存塞进工程文件（缓存走 sidecar，见第 11 节）。

### 1.3 隐私边界

- 音频与文本**不出本机**：SpeechAnalyzer 端侧模型 [WWDC25-277]；
  Translation「All translations using the class are processed on the user's device」
  [Apple 文档]。
- 唯一的网络活动是**系统**按需下载语音/翻译模型（Apple 服务器，系统管理），
  App 本身不发起任何内容上传。
- App 无 sandbox/entitlements，`packaging/Info.plist` 当前无任何权限声明
  （调查确认，见第 2.6 节）；新增功能是否触发 TCC 权限见第 3.5 节。

---

## 2. 仓库当前实现调查

全部结论来自实际源码阅读（2026-08-06），引用真实文件与类型。

### 2.1 最低系统版本与构建（评审决定：一律不动）

- `Package.swift:1` `swift-tools-version: 5.9`；`Package.swift:8` `platforms: [.macOS(.v14)]`。
  **两者保持不变。**
- 历史实验记录（作为「为什么不升」的证据保留）[实测]：`.macOS(.v26)` 写进
  manifest 需要 swift-tools-version ≥ 6.2（tools 5.9/6.0/6.1 报 `'v26' is
  unavailable`）。但 `platforms` 是**部署下限**而非 API 上限 —— 调用 macOS 26 API
  根本不需要 `.macOS(.v26)`，用 `@available` / `if #available` 门控即可
  （编译验证见 3.1 [实测]）。
- **升 tools 6.x 的连带风险（明确规避）**：swift-tools-version 6.x 默认把包切到
  Swift 6 language mode（严格并发检查），现有全仓库代码（@MainActor 单例、
  裸 `Task`、跨 actor 传值）都要过一遍并发迁移审判，与本功能无关且风险不可控。
  本规划**不升 tools、不切语言模式**。
- 构建链注意：Rosetta 终端必须 `swift build --arch arm64`
  （docs/build/build-and-packaging.md）。

### 2.2 字幕数据模型（已存在且完整，无需重建）

- `SubtitleCue`（`Sources/SrtFlowCore/SubtitleModels.swift:116`）：`id: UUID`、
  `index`、`start/end: TimeInterval`（秒）、`text`、ASS 样式字段、`rawOverride`。
- `SubtitleDocumentModel`（同文件 :164）：`cues + styles + format + scriptInfo`，
  带 `reindex()/addCue(after:)/removeCues(ids:)`。
- 解析/序列化五格式（txt/srt/vtt/ass/ssa）双向：
  `SubtitleParser`/`SubtitleSerializer`（`Sources/SrtFlowCore/SubtitleCodec.swift:4/:257`）；
  编码探测加载 `SubtitleLoader`（`Sources/SrtFlow/BurnInWorkspace.swift:47`）。
- 剪辑页时间线已内嵌字幕：`TimelineState.subtitle: SubtitleDocumentModel?` +
  `subtitleURL`（`Sources/SrtFlow/VideoEditModels.swift:543-544`），随工程存盘。
  **评审定调：`TimelineState.subtitle` 就是唯一 canonical 原文轨；`subtitleURL`
  只表示「原文来自哪个外挂文件」，生成的原文没有外挂文件（置 nil）。**
- 时间线有只读字幕行（`VideoEditTimelineView.swift:418`）；预览按播放时间查 cue
  叠 `BurnInSubtitleOverlay`（`VideoEditView.swift:168-201`）——注意现状是
  `cues.last { ... }` 单 cue 查询（:200），重叠 cue 只显示一条，第 9 节要改。
- cue 编辑 UI 已存在于烧录页：`SubtitleEditPanel`（`Sources/SrtFlow/SubtitleEditPanel.swift:52`），
  表格编辑 start/end/text、存回文件、Export As 转格式。它编辑的是**外部字幕文件**
  而非工程内字幕轨，与本功能的消费者清单（8.9）互不影响。
- **现状缺口**：剪辑页字幕 cue 不可编辑；剪辑页无独立 SRT/VTT 导出入口；
  全仓库无任何语音识别/翻译代码。

### 2.3 轨道模型与时间映射

- `TimelineState`（`VideoEditModels.swift:533`）：`mainClips`（主视频轨，唯一，
  磁吸）+ `overlayTracks: [EditLane]`（画中画）+ `audioTracks: [EditLane]`（音频轨）
  + `subtitle` + `shapes` + `canvasRatio`。全值类型，撤销=整份快照替换。
- `EditClip`（:338）：`sourceStart/sourceDuration`（源时间）+ `timelineStart` +
  `speed`；`timelineDuration = sourceDuration / speed`（:451）；`isMuted/volume`；
  `linkGroup`（detachAudio 关联音频，`VideoEditProject.swift:793`）。
- **源↔时间线换算先例**（`Sources/SrtFlow/VideoEditAnimation.swift:94-101`）：
  `sourceTime(atTimeline:) = sourceStart + (t - timelineStart) * speed`；
  `timelineTime(atSource:) = timelineStart + (s - sourceStart) / speed`。
  关键帧动画全部锚源时间 → 变速/分割自动正确（docs/architecture/keyframe-animation.md）。
- 变速 0.1–8×（`VideoEditProject.swift:723`）；分割 `split`（:610）；
  裁切改 `sourceStart/sourceDuration`（`liveTrim` :323）。
- 现有字幕 cue **按时间线时间对齐**（`VideoEditView.swift:197` 注释），
  挂接入口 `attachSubtitle`/`removeSubtitle`（`VideoEditProject.swift:549/:561`）。

### 2.4 .srtflowproj 存盘、formatVersion 与迁移

- 格式：pretty JSON + 原子写盘，顶层 `{formatVersion, savedAt, timeline, media}`
  （`Sources/SrtFlow/VideoEditProjectFile.swift:8`）。
- **`currentFormatVersion = 3`**（:20）。**无迁移代码**：新读旧靠手写宽容 Codable
  （`decodeIfPresent` + 默认值，`VideoEditModels.swift:754` 起；字符串枚举走
  `LenientCodableEnum`）；`formatVersion > current` 直接拒开（:181 版本闸门）。
- 既有教训（docs/bugfixes/2026-08-04-transform-review.md）：**加「旧版会静默丢掉」的
  字段必须升 formatVersion**；新版读旧文件永远宽容。本功能的落实方式是
  **按需写入 v4**（见 7.4），普通工程继续写 v3。
- 注意先例例外：`TimelineState.subtitle` 用的是 `SubtitleDocumentModel` 的**合成
  Codable**（`VideoEditModels.swift:985`），不是宽容解码 —— 新增实体不要再犯。
- 脏标记唯一入口 `state.didSet`（`VideoEditProject.swift:45-49`）；2 秒防抖自动保存
  （`VideoEditProjectDocument.swift:230`）；离散改动走 `perform`、连续改动走
  `beginLiveEdit/liveApply/endLiveEdit`（`VideoEditProject.swift:227/:254/:262`）。
  自动保存是**全量重写工程 JSON** —— 这正是词级缓存必须走 sidecar 的原因（第 11 节）。
- 素材重链接四层线索（`VideoEditProjectFile.swift:247`），字幕文件路径已在
  `mediaURLs` 网内（`VideoEditModels.swift:1022`）。
- 回归义务：`scripts/check-project-file.sh` + `checks/ProjectFile/main.swift`，
  加字段必须补用例。

### 2.5 AVFoundation 音视频读取

- 唯一 PCM 消费点：`WaveformCache`（`VideoEditTimelineView.swift:1278`，actor），
  `AVAssetReader + AVAssetReaderTrackOutput` 读 8kHz/16bit/单声道 PCM，
  `reader.timeRange` 限定剪辑区间 —— 转写取音频的直接先例（采样率需按识别器调整）。
- 预览混音：`VideoEditCompositionBuilder.build`（:187）AVMutableComposition +
  AVMutableAudioMix 音量 ramp（:639），与导出同账。
- 导出音频链：ffmpeg `atrim/asetpts/atempo/volume/adelay/amix`
  （`VideoEditExporter.swift:282-304`）。
- 音频元信息：`MediaProbe.probeWithAVFoundation`（`Sources/SrtFlow/MediaProbe.swift:106-137`，
  `loadTracks(withMediaType: .audio)`）—— 音轨语言 metadata（`language` /
  `extendedLanguageTag`）从这里扩展读取，用作源语言**预填**（3.7）。

### 2.6 导出、烧录、任务、临时文件

- 导出**全部走 vendor/ffmpeg 子进程**：`VideoEditExporter.shared.export(...)`
  （`VideoEditExporter.swift:28`）→ `VideoEditExportGraph.plan`（:152）生成
  `filter_complex` 图 → `FFmpegProcess.run`（`Sources/SrtFlow/FFmpegProcess.swift:49`，
  `-progress pipe:1`）→ `FFmpegProgressParser`（`Sources/SrtFlowCore/FFmpegProgress.swift:42`）。
- 字幕烧录已有：libass `subtitles` 滤镜排在滤镜图最后（`VideoEditExporter.swift:565-574`；
  `FFmpegCommand.swift:103`）；工作目录约定 `BurnInWorkspace`（`BurnInWorkspace.swift:17`）；
  ASS 生成 `BurnInStyle.assDocument`。
- 取消：`ExportCancellationToken`（`VideoEditPrerender.swift:7`）+ `FFmpegProcess.cancel()`
  （:137）。教训（docs/bugfixes/2026-08-05-export-prerender-review.md）：**每个阶段交界
  都要查 token**；失败路径**绝不碰用户目标文件**；输出走「临时名 → 校验 → 原子替换」
  （:76-85）。
- 无通用任务框架。最接近的模式：`EncodeQueue`（`Sources/SrtFlow/EncodeQueue.swift:56`，
  刻意串行的 @MainActor 队列，waiting/probing/running/finished/failed/cancelled 状态）
  和 `FFmpegProcess` 式封装。后台杂活用裸 `Task` + `documentGeneration` 防串工程
  （`VideoEditProject.swift:81-101`）。
- 临时文件：`NSTemporaryDirectory()/SrtFlow-<UUID>`（用完即删，defer 兜底）；
  可复用缓存在 `~/Library/Caches`，且**命中缓存也要先验证可用性**（「文件存在 ≠
  文件可用」，transform-review 教训）。
- `packaging/Info.plist` 无权限声明、无 entitlements、无 sandbox。
- `SrtFlow-Requirements.md:237` 把「自动语音识别生成字幕」写为**非目标** ——
  Phase 4 动工时该文档需同步改写（列入 17.3 待办）。

### 2.7 文件规模红线（实测行数）

| 行数 | 文件 | 状态 |
| --- | --- | --- |
| 1345 | `Sources/SrtFlow/VideoEditTimelineView.swift` | 超标，禁止再堆 |
| 1059 | `Sources/SrtFlow/VideoEditModels.swift` | 超标，新实体 Codable 放新文件 |
| 1057 | `Sources/SrtFlow/VideoEditProject.swift` | 超标，新方法放 extension 文件 |
| 886 | `Sources/SrtFlow/VideoEditExporter.swift` | 超标，导出矩阵逻辑放新文件 |
| 842 | `Sources/SrtFlow/VideoEditCompositionBuilder.swift` | 超标 |

新功能代码一律按职责开新文件（第 16 节列出全部计划文件），对上述文件只做
最小挂钩式改动。

---

## 3. Apple API 可行性

### 3.1 可用性与 availability 隔离策略（评审已定）

| API | 可用性 | 证据 |
| --- | --- | --- |
| `SpeechAnalyzer`（actor） | macOS 26.0+ | [SDK] Speech swiftinterface :207 |
| `SpeechTranscriber` | macOS 26.0+ | [SDK] :335 |
| `AssetInventory` / `AssetInstallationRequest` | macOS 26.0+ | [SDK] :12/:494 |
| `TranslationSession` 类本体（translate/batch/prepareTranslation） | macOS 15.0+ | [SDK] Translation swiftinterface :93/:179-184 |
| `TranslationSession.cancel()` / `isReady` / `canRequestDownloads` / `init(installedSource:target:)` | macOS 26.0+ | [SDK] :100-104/:185-188 |
| `TranslationSession.Strategy`（highFidelity/lowLatency） | **macOS 26.4+** | [SDK] :107-116 — 不使用 |
| `LanguageAvailability`（supportedLanguages/status） | macOS 15.0+ | [SDK] :15-38 |

**实施策略（本功能全部代码遵守）：**

1. `Package.swift` **一个字不改**：tools 5.9、`.macOS(.v14)`。
2. 新代码用 availability 隔离：
   - Translation 相关类型/文件整体 `@available(macOS 15.0, *)`；
   - SpeechAnalyzer 相关类型/文件整体 `@available(macOS 26.0, *)`；
   - 公共入口（工具栏按钮、菜单、面板挂钩）用 `if #available(...)` 门控，
     旧系统显示置灰入口 + 版本要求文案。
3. **不预设手写 `-weak_framework` 之类链接 flag**：先依赖工具链对「高于部署目标
   的框架」的默认弱链接行为；**macOS 14 真机/VM 启动验证列入验收**（15.4 / Phase 0）。
   若默认行为不成立再补链接设置（届时按实测补充本节）。
4. 若弱链接确实无法满足（Phase 0 证伪默认行为），经用户同意后允许把部署下限
   升到 `.v15`（仍不升 tools、不上 `.v26`）—— 这是唯一预授权的后备路径。

**Phase 0 编译/链接验证 [实测 2026-08-06]**：spike 程序（`@available` 门控的
SpeechAnalyzer + TranslationSession 完整调用）用
`swiftc -target arm64-apple-macos14.0` 编译，**零告警通过**；`otool -L` 显示
Speech 与 Translation 均被工具链**自动标记 weak** 链接 —— 策略第 3 条的前半
（编译与链接）成立，仅剩 macOS 14 实机启动待验收。

### 3.2 支持语言的运行时查询

- `SpeechTranscriber.supportedLocales / installedLocales`（async）[SDK :402-407]；
  `supportedLocale(equivalentTo:)` 做地区归一 [SDK :405]。
- `SpeechTranscriber.isAvailable: Bool` —— 「whether this module is available given
  the device's hardware and capabilities」[Apple 文档]，即硬件门槛是运行时事实，
  不是编译期常量。V1：false 即明确提示不支持（1.2）。
  **本机 M1 实测 `isAvailable == true`**；supportedLocales 共 30 个
  （de/en/es/fr/it/ja/ko/pt/yue/zh 系，无俄语/阿拉伯语/印地语等），
  installedLocales 预装 11 个（en 系 + zh_CN/zh_TW）[实测 2026-08-06] ——
  覆盖面有限，再次印证「语言列表只能运行时查询、不得承诺覆盖率」。
- `LanguageAvailability().supportedLanguages` + `status(from:to:)` 查询翻译语言对，
  三态 `installed / supported / unsupported` [SDK :26-33]。
- **UI 语言列表必须全部来自上述运行时查询**，不写死任何语言清单；
  不承诺任何固定的语言覆盖率（官方未公布保证值）。

### 3.3 模型安装、保留与释放

- 语音模型是从 Apple 服务器下载、**系统管理/保留/自动更新/跨 App 共享**的资产
  [Apple 文档 AssetInventory]。
- 生命周期：`AssetInventory.status(forModules:)`（四态
  unsupported/supported/downloading/installed [SDK :23-35]）→ 需要时
  `reserve(locale:)` → `assetInstallationRequest(supporting:)` 拿
  `AssetInstallationRequest`（`ProgressReporting`，`downloadAndInstall()`）
  [SDK :20/:35-36/:494-499] → 用完 `release(reservedLocale:)` [SDK :22]。
- **reservation 上限**：`AssetInventory.maximumReservedLocales`（运行时值，
  [SDK :13]）。官方明确「系统为限制存储与网络占用，只给每个 App 有限的 locale
  reservation 数量」[Apple 文档]。**具体数值官方未公布，运行时读取，不写死**
  （本机实测值 5 [实测 2026-08-06]，仅作参考，代码仍读运行时值）。
- 实测细节 [实测 2026-08-06]：`installedLocales` 含 en_US 时，
  `status(forModules:)` 对配好 attributeOptions 的模块仍可能返回 `supported`
  （非 installed）——**以 `status(forModules:)` + `assetInstallationRequest` 为准
  驱动安装流程**，不要拿 `installedLocales` 判断可用；已就绪时
  `downloadAndInstall()` 秒级返回。小体积/快速下载时
  `request.progress.fractionCompleted` 可能全程停在 0 直接完成 —— UI 进度条
  要能容忍「无中间值直接完成」。
- 首次下载成本：模型大小官方未承诺，**不得向用户宣称具体体积**；下载可能立即完成
  （系统预装或别的 App 已下载）[Apple 文档]。错误面：`SFSpeechError.Code` 新增
  `noModel / assetLocaleNotAllocated / tooManyAssetLocalesAllocated /
  cannotAllocateUnsupportedLocale / insufficientResources` [SDK :655-673]。
- 分析器资源：默认懒加载、析构卸载 [Apple 文档]；`SpeechAnalyzer.Options.
  modelRetention`（whileInUse/lingering/processLifetime）+ `SpeechModels.
  endRetention()` 可主动释放 [SDK :441-463/:251-253]。
- **并发限制**：系统限制同时进行的分析数量，超限抛不可预测错误 [Apple 文档]。
  → 任务必须**串行**（与 EncodeQueue 的串行先例一致）。

### 3.4 TranslationSession 生命周期（结构性约束，Phase 0 必验）

这是 Translation framework 最容易踩的坑，评审列为 **Phase 0 结构性验证项**，
最终任务状态机（第 10 节）在验证通过前不固化。

**已确认的 API 事实：**

- macOS 15 起，能触发**模型下载**的 session 只能由 SwiftUI
  `.translationTask(_:action:)` 修饰符提供；`prepareTranslation()`
  「Asks for permission to download translation languages without doing any
  translations」[Apple 文档] —— 下载许可交互属于系统，形态以实机为准 [待验证]。
- **session 与承载它的 view 生命周期绑定**：不得把 session 存进全局任务队列、
  单例或持久模型；翻译必须在 translationTask 闭包持有的 session 生命周期内执行
  [Apple 文档]。
- macOS 26 新增 `init(installedSource:target:)`：**不抛错的 convenience init**
  [SDK :188，无 `throws`]；它只用于**已经安装**的语言对 —— 模型未装时初始化仍
  成功，但翻译调用抛 `TranslationError.notInstalled`（macOS 26+ [SDK :82]），
  且该 session **无权请求下载**（`canRequestDownloads` 语义 [SDK :100]）。

**本机实测（macOS 26.5，CLI spike，[实测 2026-08-06]）：**

- `init(installedSource:target:)` 路径**可完全脱离 SwiftUI 工作**（已安装语言对
  en→zh-Hans 翻译成功）；`canRequestDownloads == false` 实测确认。
- 三态错误面逐一验证：`unsupported` 语言对（en→fi）→ 翻译抛
  `unsupportedTargetLanguage`；`supported` 但未装（zh-Hans→ja）→ 抛
  `notInstalled`；`installed` → 成功。`LanguageAvailability.status` 三态与
  错误一一对应，UI 错误路径可按此分支。
- **坑：Translation 栈依赖主队列被服务** —— 主线程被信号量阻塞时，连
  `LanguageAvailability.status` 都会**无限挂起**（无报错无超时）。App 内
  （run loop 常驻）无此问题；但 CLI 自检/checks 脚本必须用
  `dispatchMain()`/run loop 结构，不得阻塞主线程等待 async 结果。

**设计（待 Phase 0 验证后固化）：常驻 Translation Host**

- 主窗口视图层挂一个常驻的隐形 SwiftUI 节点 `TranslationHostView`，
  持有 `.translationTask(configuration)`；
- coordinator（@MainActor）只保存 **job / config / result**，不保存 session；
  提交翻译 = 更新 configuration 触发 translationTask 闭包，在闭包内用
  session 执行 `translate(batch:)` 并把结果回投 coordinator；
- macOS 26 的 `init(installedSource:target:)` 路径仅作为「已装语言对」的
  无 UI 便捷通道（批量重译等），**不承担下载**。

**Phase 0 必须先验证的行为（再定最终状态机）：**
模型下载交互、承载 view 关闭时任务命运、`cancel()` 行为、
重复提交任务、App 切换工程时 session/任务的清理。

### 3.5 权限

- WWDC25-277 中出现的权限只有**麦克风**权限（现场录制示例）。对「App 自己提供音频
  文件/缓冲做转写」的路径，Apple 官方资料中**未找到需要 Speech Recognition 权限的
  明文要求**；经典文档《Asking Permission to Use Speech Recognition》针对的是使用
  Apple 服务器的 SFSpeechRecognizer [Apple 文档]。
- **[实测 2026-08-06]**：无 `NSSpeechRecognitionUsageDescription`、无任何
  entitlement 的 CLI 进程对本地音频文件跑 SpeechAnalyzer 转写，**无 TCC 弹窗、
  无报错、结果正常** —— 文件转写路径确认不触发语音识别权限。
  打包成 .app 后的形态在 Phase 4 打包回归时复验一次（预期一致）。
- Translation 首次下载的系统交互形态见 3.4 [待验证]。

### 3.6 硬件差异与后备（V1 从简）

- Apple Silicon（本机 M1）：SpeechTranscriber 可用性以 `isAvailable` 为准 [SDK]，
  本机实测列入 Phase 0。
- Intel：macOS 26 仍支持部分 Intel 机型，`isAvailable` 在 Intel 上的实际取值
  官方未公布 [待验证]。**V1 对策：`isAvailable == false` → 明确提示本机不支持
  语音转写**（翻译能力不受影响），不做编译期分叉、不承诺后备。
- DictationTranscriber（「compatible with older devices」的系统听写模型
  [Apple 文档]；支持 `audioTimeRange` 与 `transcriptionConfidence` [SDK :115-130]）
  是**未来 Phase 的候选后备**：其语言覆盖差距、长音频表现、结果属性可靠性
  全部 [待验证]，验证通过前不写进任何用户可见承诺。
- Apple Intelligence 系统开关对 Speech/Translation 的具体影响无官方说明
  [待验证]；设计不依赖该开关状态，失败时走运行时状态查询的错误路径。

### 3.7 源语言选择：V1 手动为主，自动检测是 V2

**V1（本计划范围）：**

1. 音轨语言 metadata（`AVAssetTrack.language/extendedLanguageTag`，从
   `MediaProbe.probeWithAVFoundation` 扩展读取）**只用于预填**配置面板的
   源语言下拉框。
2. 没有 metadata 时，**用户手动选择源语言**（下拉列表来自 3.2 的运行时查询，
   标注已安装/需下载状态）。
3. 永远允许手动覆盖；选择记忆到工程的生成参数快照（7.2）。
4. 不做 SpeechDetector、能量 VAD、多 locale 试识别、融合打分、低置信确认弹窗
   —— 相应的文件、状态、测试与 Phase 0 项一并从 V1 删除。

**V2（需求保留，基础转写稳定后再做）：**

自动语言检测蓝图 —— 选人声样本（SpeechDetector 或能量 VAD）→ 在
「已安装语言 ∪ 用户勾选候选」内试识别 → `transcriptionConfidence` × 有效语音
覆盖率 × `NLLanguageRecognizer`（`languageConstraints` 限定候选集）融合打分 →
高置信自动采用、低置信弹确认。约束依旧成立：`SpeechTranscriber` 初始化必须给
`locale` [SDK :336]，**Apple 没有一步式「任意音频 → 语言」API**，不得宣称
「自动识别任意语言」；静默扫全部语言 = 不可控的 reservation/网络/存储成本
[Apple 文档]。V2 立项时再补细化方案与 SpeechDetector 资产依赖验证。

---

## 4. 完整数据流

```
素材文件(视频/音频)
  → ① 音频读取：AVAssetReader 按「被使用源区间」分窗流式读 PCM
       （WaveformCache 先例；采样率/格式按 bestAvailableAudioFormat 协商 [SDK :233-234]）
  → ② 源语言确定：metadata 预填 → 用户在配置面板确认/手选（V1 无自动检测）
  → ③ 转写：SpeechAnalyzer + SpeechTranscriber（macOS 26+；isAvailable=false
       则明确报不支持），finalized 结果带词级 audioTimeRange +
       transcriptionConfidence 属性，按素材源时间写入 sidecar 缓存（第 11 节）
  → ④ 字幕分段：每个 clip 实例从缓存截取词流 → 映射到时间线 → 时间线时间上
       成句/成 cue（第 6 节）→ 写入 canonical 原文轨（已有原文时须确认替换，第 8 节）
  → ⑤ 翻译：Translation Host（第 3.4 节）session.translate(batch:)（语义句级），
       回写 companion 译文轨，不改 cue ID/数量/时间
  → ⑥ 编辑：双轨 cue 编辑（第 8 节合同），走 perform/liveApply 进撤销栈
  → ⑦ 导出：烧录（ffmpeg subtitles 滤镜，现有管线）/ 独立 SRT/VTT
       （SubtitleSerializer，现有），矩阵见第 13 节
```

macOS 15–25 走 ⑤⑥⑦（对现有/导入字幕轨「翻译当前字幕」）；macOS 26+ 全链路。

---

## 5. 转写对象与时间映射

### 5.1 三个候选

- **A. 时间线最终混音**：把 AVMutableComposition+AudioMix 渲染成一条音频再转写。
  cue 直接落在时间线上，最贴合「观众听到的」。缺点：任何编辑（裁切/变速/分割）
  都使转写失效需整段重跑；变速音频（0.1–8×）识别质量受损；多条音轨混叠后
  无法归属来源。
- **B. 素材源文件整体转写**：每个素材转写全文件。缺点：裁掉的部分白转写
  （长素材只取一段时浪费数倍算力）；仍要做源→时间线映射。
- **C. 素材源文件的「被使用区间」转写（采用）**：对每个出声素材（主轨视频段的
  音频 + 音频轨段），按其 clip 的源区间转写，**词流锚素材源时间**存入缓存，
  分段时经 `timelineTime(atSource:)`（`VideoEditAnimation.swift:94-101` 的
  现成逆运算）映射为时间线 cue。

### 5.2 采用 C 的理由

1. **识别质量**：永远转写 1× 原速音频；变速/裁切/分割只做时间换算 ——
   这正是关键帧动画「源时间锚定、变速分割自动正确」的已验证先例
   （docs/architecture/keyframe-animation.md）。
2. **架构一致**：生成结果最终落成时间线 cue（canonical 原文轨与现有预览/烧录
   同一时间基准）。
3. **可缓存**：源时间词流按素材缓存（第 11 节，含区间账本），编辑后重新生成
   只重做截取+映射+分段，不重跑识别（缓存覆盖不足时只补缺口）。
4. **内存友好**：按区间流式读（第 14 节）。

### 5.3 裁切/分割边界合同（评审已定，Phase 0 真实音频验证）

1. **clip 源区间是半开区间** `[sourceStart, sourceStart + sourceDuration)`。
2. **跨边界单词按 timeRange 中点归属唯一 clip**：词的
   `midpoint = (start + end) / 2` 落在哪个 clip 的源区间就归谁 ——
   同一素材分割成相邻分片时，边界词**不重复、不遗漏**。
3. 归属后把词的时间范围 **clamp 到该 clip 的源区间**。
4. clamp 后**零时长（end ≤ start）的条目丢弃**。
5. 该合同的听感效果（分割点横跨句子时两侧字幕衔接是否自然）列入
   **Phase 0 真实音频验证**。

### 5.4 其他细节规则

- **映射发生在生成时一次性完成**；生成后再改时间线（裁切/变速/分割），已生成
  cue **不自动跟随**（与现有外挂字幕行为一致），用户可重新生成 —— 重新生成走
  缓存，成本低。该限制写进 UI 文案（17.3 列为待用户最终确认的产品体验项）。
- **变速 clip**：源区间转写 → `timelineTime(atSource:)` 换算，天然正确；
  分段约束在时间线时间上执行（第 6 节）。
- **多个视频片段**：按素材分组成批转写；同一时间窗多个素材同时出声（主轨+音频轨
  重叠）时，各素材的 cue 都投影到时间线，**V1 全部保留**，渲染按第 9 节的
  排序合同处理（SRT 允许时间重叠）。
- **多音轨**：`isMuted` 的 clip 跳过不转写；音频轨素材与主轨同等处理。
  第一版不做说话人分离。
- **无语音区间**：转写结果为空也要记入缓存的区间账本（「已分析、无语音」，
  见 11.2），避免反复重扫。

---

## 6. 字幕分段算法（时间基准：先映射、后约束）

输入是 sidecar 缓存中的**素材源时间词流** `(word, sourceTimeRange, confidence)`
（由 `SpeechTranscriber.Result` 的 AttributedString 词级属性展开 [SDK :418-433] +
AttributeScopes.SpeechAttributes [:169-191]；只用 **finalized** 结果，见 10.2）。
**SpeechAnalyzer 的原始结果不是可直接展示的字幕 cue** —— 必须经本节算法重排。

1. **缓存层保持素材源时间**：词流不含任何 clip 信息，与时间线解耦（这使缓存
   跨编辑复用成为可能）。
2. **每个 clip 实例先截取、再映射**：按 5.3 合同截取归属本 clip 的词 →
   逐词经 `timelineTime(atSource:)` 把 timeRange 映射到时间线。
3. **语义成句（时间线时间上）**：按识别文本自带的标点 + 词间停顿时长聚合成
   完整语义句。**标点输出已实测确认** [实测 2026-08-06]：SpeechTranscriber
   （en_US，默认选项）自动输出逗号/句号/问号，标点附着在所属词的 run 上
   （如 `"Hello,"`、`" marks?"`）；词级属性粒度为**真词级** —— 每个词一个
   `audioTimeRange`（如 `" is" [1.200–1.380]`）和一个 `transcriptionConfidence`。
   finalized 结果按句段返回（`range` 为句段级）。
   **先成句再翻译** —— 翻译输入是完整句子，不切半句。
4. **成 cue（时间线时间上执行全部约束）**：最短/最长持续时间、阅读速度上限
   （CPS）、最大行数、每行长度（中英文分别按字符数/词数）、停顿阈值 ——
   全部按**时间线时长**评估。约束参数集中于 `SubtitleSegmentationConfig`
   （纯值类型，默认值待产品确认后固化，不硬编码进逻辑）。
5. **同一素材在不同 speed 的 clip 上允许产生不同分段** —— 这是合同明确的
   预期行为（2× 的 clip 句子被压短，需要更碎的 cue 才能满足 CPS）。
6. **极端变速导致无解时不得假装满足**：如 8× 变速后任何切分都超 CPS 上限，
   生成照常完成，但 cue 打 `readingSpeedWarning` 标记（进 cueMeta，7.3），
   UI 明确告警；绝不静默输出「看起来合规」的假结果。
7. **边界吸附**：cue 边界吸附到词边界，不切词。
8. **翻译后重排版**：译文轨共享原文 cue 的 ID 与时间（第 7 节），译文文本按同一
   配置做行内折行；**翻译不改变 cue 数量、时间轴与关联身份**（硬约束）。
9. 低置信 cue（confidence 均值低于阈值）打标，UI 标色提示（呈现方式待产品确认）。

分段器放 `SrtFlowCore` 纯函数实现，用合成词流做单元测试（`SrtFlowCoreChecks`
现有模式）；**变速用例必须覆盖 0.1×、1×、2×、8×**（15.1）。

---

## 7. 数据模型与工程存盘

### 7.1 canonical 原文轨（评审已定）

- **`TimelineState.subtitle` 是唯一 canonical 原文轨**，不论原文来自外挂文件、
  导入还是语音生成。`subtitleURL` 只表示「原文来自哪个外挂文件」；
  语音生成的原文没有外挂文件，`subtitleURL = nil`。
- **不在任何新实体中重复保存 original** —— 译文与元数据挂在 companion 上。
- 从音频生成时若 `subtitle` 已存在：**必须确认替换**（对话框），确认后在
  **同一 `perform` 事务**内完成「替换原文 + 清空旧译文 + 清空旧 cueMeta」，
  一步撤销可整体恢复（第 8 节合同 0）。

### 7.2 companion 实体 `SubtitleCompanion`（新文件 `Sources/SrtFlowCore/SubtitleCompanion.swift`）

原方案的 `GeneratedSubtitleSet` 更名并裁剪，**只保存原文轨之外的关联状态**：

- `translation: SubtitleDocumentModel?` + `targetLanguage: String?`（BCP-47）——
  **关联规则：译文 cue 与原文 cue 使用同一个 `SubtitleCue.id`（UUID）、
  同 start/end**，关联身份即 ID 相等，无额外外键。
- `sourceLanguage: String?`（BCP-47；外挂字幕的翻译场景也要记）。
- `cueMeta: [UUID: CueMeta]`（7.3）。
- 生成来源/参数快照：`origin`（imported / generated）、转写模块类型、
  分段配置版本、生成时间。
- **V1 只允许一条原文轨 + 一条关联译文轨**（1.2）。
- 全部**手写宽容 Codable**（`decodeIfPresent` + 默认值，枚举走
  `LenientCodableEnum`），不踩 `subtitle` 合成解码的既有例外（2.4）。
- 任务状态（进行中/失败原因等）**不进工程文件**，运行时单例持有；
  工程里只持久化「上次生成参数 + 是否有未完成翻译」这类恢复线索。
- 词级转写缓存**不进工程文件**（第 11 节 sidecar）。

### 7.3 CueMeta 与集中维护合同（评审已定，全部规则必须有单元测试）

字段：`recognitionConfidence: Double?`、`translationStale: Bool`、
`origin`（generated / editedManually）、`readingSpeedWarning: Bool`、
**provenance**（`sourceAssetFingerprint` + `clipID` + `sourceTimeRange`，
支持重叠 cue 排序（第 9 节）、诊断与部分重新生成）。

维护规则集中在一个类型（如 `CueMetaStore`）里，调用方不得散落手改：

1. **删除 cue → 同步删除其 meta**（两轨与 meta 三方一致）。
2. **拆分**：第一条**保留原 ID**，第二条**新 UUID**；两轨（原文/译文）使用
   同一对 ID；两条 `translationStale = true`；人工拆分使
   `recognitionConfidence` 不再可靠 → 两条置 `nil`。
3. **合并**：保留首条 ID，删除其余条目的 meta；合并后 `translationStale = true`。
4. **人工改文本**：原文被人工修改 → 该 cue `translationStale = true` 且
   `recognitionConfidence` 置 `nil`（不再可靠）；译文被人工修改 → 清自己的
   stale（视为人工修正）。
5. **decode/normalize 后删除孤儿 meta**（meta 的 UUID 在两轨 cue 中都不存在时）。
6. provenance 在重新生成局部区间时用于定位受影响 cue。

### 7.4 formatVersion：reader 到 4，writer 按需写 3 或 4（评审已定）

- **reader 支持的 latest version = 4**：`VideoEditProjectFile` 版本闸门改为
  `formatVersion > 4` 拒开；读 v1–v4 全部宽容解码，零迁移代码。
- **writer 每次保存时动态决定写 3 还是 4**：判据是「当前工程是否存在任何
  **v4-only 持久数据**」（即旧版打开后会被静默丢掉的新字段）。
  - 判据实现为集中谓词（如 `TimelineState.requiresFormatVersion4`），**枚举
    全部 v4-only 字段**（当前 = `SubtitleCompanion` 存在且非空），
    **不是只检查某一个类型名** —— 谓词旁写清单注释，今后每加一个 v4-only
    字段必须同步登记，否则 review 打回。
  - 普通旧功能工程（没碰过新功能）**继续写 v3**，旧版 App 完全不受影响。
- **允许降回 v3**（评审明确）：用户删除全部 v4 数据（清掉译文与生成状态）后，
  下一次保存谓词为 false，自动写回 v3 —— 必须有回归测试覆盖这条降级路径。
- **缓存 sidecar 不参与 formatVersion**（它是可重建缓存，有自己的版本字段，11.3）。
- 回归：`checks/ProjectFile/main.swift` 补用例 —— v3 工程往返仍写 v3；
  加 companion 后写 v4 且往返无损；删除 companion 后回写 v3；伪造 v5 被拒开。

---

## 8. 编辑合同

所有改动走 `perform`/`liveApply`（`VideoEditProject.swift:227/:254`）——
撤销、脏标记、自动保存自动正确。合同规则（meta 维护细则见 7.3）：

0. **生成替换**：已有原文轨时从音频生成 → 确认对话框 → 同一 `perform` 事务内
   「替换 `subtitle` + 清空 companion 旧译文/meta」，一步撤销整体恢复（7.1）。
1. **改时间**：任一轨 cue 的 start/end 被改 → 同一 `perform` 事务内把另一轨同 ID
   cue 改成相同时间（一步撤销）。
2. **改原文文本**：同 ID 译文 cue `translationStale = true`；本 cue
   `recognitionConfidence` 置 nil（7.3 规则 4）。
3. **改译文文本**：清自己的 stale（视为人工修正）。
4. **删除**：两轨同删 + meta 同删（是否需要确认对话框待产品确认）。
5. **拆分**：按 7.3 规则 2 —— 首条保留原 ID、次条新 UUID、两轨一致；
   译文文本整体留在前半，后半译文置空 + 两条都标 stale（语义不可机械二分，
   提示用户重译）。
6. **合并**：原文文本拼接；按 7.3 规则 3 —— 沿用首条 ID、删其余 meta、标 stale。
7. **重译**：单条 / 选区 / 全部三个入口；只翻 `stale` 或显式选中的；
   重译复用第 6 节的语义句输入（按 cue 当前文本成句）。
8. **Undo/Redo 边界**：一次合同操作 = 一次 `perform` = 一步撤销；拖动调时间走
   `liveApply` 连续编辑收尾成一步。

### 8.9 消费者清单（原「下游零改动」结论作废）

引入译文轨后，以下消费者**都要改成显式选择 原文 / 译文 / 双语**（挂钩级改动，
矩阵逻辑放新文件）：

| 消费者 | 位置 | 改动 |
| --- | --- | --- |
| 预览字幕 overlay | `VideoEditView.swift:168-201` | 轨道选择 + 第 9 节多 cue 渲染合同 |
| 时间线字幕行 | `VideoEditTimelineView.swift:418` | 显示轨道选择（原文/译文），选中态 |
| 烧录导出 | `VideoEditExporter.swift:565-574` | 输入文档按矩阵选原文/译文/双语（13） |
| 独立 SRT/VTT 导出 | 新入口（13） | 按矩阵选轨 |
| `attachSubtitle` / `removeSubtitle` | `VideoEditProject.swift:549/:561` | 挂新外挂原文 = 替换合同（规则 0）；移除原文 → 同一事务处理 companion（清空译文/meta，需确认） |
| 双轨编辑器 | 新 `LinkedSubtitleEditor` | 原生双轨 |

不受影响：烧录页 `SubtitleEditPanel`（编辑外部字幕文件，不读工程内轨道，2.2）。

---

## 9. 重叠 cue 渲染合同（评审新增）

- **active cues 的定义**：时刻 t 的活动 cue = 所有 `start <= t < end` 的 cue。
  预览**不得再用 `cues.last { ... }` 单 cue 查询**（现状 `VideoEditView.swift:200`）。
- **稳定排序合同**：活动 cue 按排序键
  `(start 升序, 轨道秩, provenance.clipID, cue.id)` 排序；
  轨道秩 = 主轨 0、音频轨按 `audioTracks` 数组序 1..n、无 provenance 的
  （外挂/手工 cue）排最前。排序函数是 `SrtFlowCore` 里的**单一实现**，
  预览与烧录共用同一函数 —— 合同一致性靠共享代码保证，不靠两处「写得一样」。
- **预览**：返回全部活动 cue，按合同顺序纵向堆叠渲染（先到者在下，
  与 libass 对重叠事件的堆叠方向一致性在 Phase 3 实测对齐）。
- **烧录**：生成 ASS/SRT 时按同一合同排定事件顺序，libass 按事件序堆叠。
- **测试**：构造重叠 cue 工程 → 共享排序函数单元测试 + 预览/烧录抽帧一致性
  检查（15.1/15.3）。

---

## 10. 任务状态机与进度

新文件 `SubtitleGen/TranscriptionTask.swift`，模式对齐 `EncodeQueue`
（@MainActor、刻意串行、全局单例防视图销毁中断）。
**翻译阶段不持有 session**——经由 Translation Host（3.4）执行；
最终状态机形态在 Phase 0 的 host 生命周期验证通过后固化。

```
idle
 → preparingModels     AssetInventory.status → reserve → assetInstallationRequest
                       （Progress 直通 UI）；翻译侧 LanguageAvailability.status
                       →（需下载时）Translation Host 走 prepareTranslation
 → readingAudio        按素材被使用区间建 AVAssetReader（流式，不落整段）
 → transcribing        SpeechAnalyzer 逐素材串行；源语言已在配置面板确定（3.7）
 → segmenting          纯 CPU，秒级
 → translating         Translation Host session.translate(batch:) 流式回填；进度 = 句数
 → done / failed(SubtitleGenError) / cancelled
```

### 10.1 取消与生命周期

- **取消**：统一 `CancellationToken`（仿 `ExportCancellationToken`）+ Swift Task
  取消；**每个阶段交界查 token**（export-prerender-review 的核心教训）；
  转写中调 `cancelAndFinishNow()`（[SDK :224]），翻译中调
  `TranslationSession.cancel()`（macOS 26+ [SDK :185-186]；macOS 15–25 的
  取消形态随 Phase 0 host 验证确定）。
- **App 退出**：`applicationShouldTerminate` 处取消并清理临时文件（同自动保存
  flush 的生命周期边界意识，project-file-lifecycle 教训）。
- **工程切换**：任务绑 `documentGeneration`，切工程即作废取消；sidecar 转写缓存
  按素材存（11.2），跨工程天然可复用。
- **素材失效**：`resolve` 四层线索失败 → 该素材标记跳过并明示，不中断整任务；
  全部失效才 failed。
- **失败**：保留已完成的转写缓存；错误信息带阶段与可操作修复建议
  （对齐 FFmpegProcessError 的文案风格）。

### 10.2 进度与 volatile/finalized 规则（评审已定）

- **volatile results 只用于临时 UI 展示**（转写过程中的灰字预览），
  **绝不进入最终字幕或 sidecar 缓存**；只有 **finalized results 可以持久化**。
- **[实测 2026-08-06]** volatile/finalized 行为符合预期：volatile 结果逐词增量
  （`isFinal == false`，同一句段反复修订），finalized 结果按句段一次性给出
  （`isFinal == true`，带词级属性），`result.range` 与 `resultsFinalizationTime`
  随句段单调推进（0.84 → 3.00 → 4.98 → 6.27s）—— **适合驱动进度**。
  仍保留双进度设计选项：「音频已输入进度」（喂入分析器的时长占比）与
  「结果已 finalize 进度」，长素材实测后取舍。
- **总进度必须单调不倒退** —— 不因 volatile 修订、阶段切换或权重换算出现回退；
  阶段加权（模型准备按 Progress、转写按音频时长、翻译按句数），
  权重默认值待实测校准。

---

## 11. 转写缓存：sidecar + 区间账本（评审已定）

### 11.1 位置与形态

- **词级 `TranscriptAssetCache` 不进 pretty JSON 工程文件**（2 秒防抖全量重写
  会把每次编辑变成兆级 I/O，2.4）。
- 默认放 **`~/Library/Caches/SrtFlow/Transcripts/`** 下的**紧凑 sidecar**
  （紧凑编码，非 pretty JSON；必要时压缩）——系统视为可重建缓存，
  用户清理/迁移机器丢失都无害。
- **体积估算按每小时语音约 1–3 MB 起步**（词级条目 × 8–15k 词/小时），
  不得再写「数十 KB」；工程文件只保存最终字幕（canonical + companion）
  和必要的轻量生成信息（7.2）。
- **原子写入**（临时名 → 校验 → 原子替换）；**版本化**（缓存格式版本字段，
  不参与工程 formatVersion）；**校验**（长度/哈希，命中先验证可用性 ——
  「文件存在 ≠ 文件可用」教训）；**LRU/容量上限清理**（上限做成常量，实测后调）。
- **缓存丢失/损坏必须安全退化为重新转写**，绝不报错卡死用户流程。

### 11.2 区间账本（评审已定）

每个缓存条目记：

- **asset fingerprint**（路径+大小+时长，对齐 `MediaRecord` 既有线索）；
- **locale**；
- **transcriber kind / config / model version**（模块类型、关键选项、
  可获得的模型版本信息）；
- **normalized coveredSourceRanges**（已分析的源时间区间集合，规范化合并）——
  **「已分析但无语音」的区间也必须记为 covered**，避免反复重扫静音段；
- **timed words**（源时间词流，只含 finalized 结果）。

命中逻辑：

1. 需要区间 `desiredRanges` − `coveredRanges` = 缺口集合，**只补缺口**；
2. 缺口两侧允许带少量上下文 padding（数百毫秒~秒级，Phase 0 调），
   补转写结果与既有词流**按源时间合并去重**（重叠窗内以新结果覆盖旧结果）；
3. **素材指纹或 transcriber 配置变化 → 整条失效**重建。

### 11.3 临时文件与恢复

- 音频优先**不落盘**：AVAssetReader → `AnalyzerInput` AsyncSequence
  （`bufferStartTime` 对齐源时间轴 [SDK :243-248]）。若格式协商踩坑，后备方案：
  转 16kHz 单声道 CAF 落 `NSTemporaryDirectory()/SrtFlow-ASR-<UUID>/`，
  `inputAudioFile` 喂给分析器（官方支持的文件输入 [SDK :329-331]），defer 清理。
- **可恢复性**：任务崩溃/取消后已 finalize 的词流已落 sidecar，重跑只补缺口；
  翻译中断后重跑只翻缺的部分（按 cue 缺失/stale 判定）。
- **清理**：临时目录 defer + 启动时扫一次 `SrtFlow-ASR-*` 残目录删除；
  失败路径不碰任何用户文件（export-prerender-review 教训）。

---

## 12. UI 流程

新面板 `SubtitleGen/SubtitleGenPanel.swift`（剪辑页工具栏入口，
`if #available` 门控，见 3.1）：

1. **配置**：源语言（metadata 预填，无则必选，3.7）、目标语言（运行时
   `LanguageAvailability.supportedLanguages` + 状态过滤，标注「需下载」）、
   转写范围说明（第 5 节）。
2. **「翻译当前字幕」入口**（macOS 15+）：工程已有原文轨（外挂/导入/生成）时，
   可只跑翻译链路（④ 跳过，走 ⑤）。
3. **替换确认**：已有原文轨时从音频生成 → 确认对话框（8 合同 0）。
4. **首次模型下载**：语音模型走 `AssetInstallationRequest.progress` 进度条；
   翻译模型经 Translation Host 触发系统交互；两者都明示「由系统下载，
   体积与时间取决于系统」。不显示任何未承诺的体积数字。
5. **进度**：阶段名 + 阶段内进度 + 总进度（单调，10.2）+ 取消按钮（始终可用）；
   转写中可用 volatile 结果做灰字预览（不落任何持久层）。
6. **错误**：阶段化错误（模型下载失败/语言不支持/识别为空/翻译未安装…），
   每条带「重试/改设置/取消」动作；`SpeechTranscriber.isAvailable == false` 或
   locale 不支持时**明确提示本机/该语言不支持语音转写**（无后备，1.2）。
7. **完成后**：双轨字幕进时间线；编辑入口 = 时间线字幕行升级为可选中 +
   新双轨编辑器 `LinkedSubtitleEditor.swift`（参考 `SubtitleEditPanel` 表格模式，
   接 `perform`）；低置信 cue 标色；`readingSpeedWarning` cue 告警标识（6.6）。
8. **重新执行**：改语言/改分段参数/编辑后可整体或部分重跑（命中缓存则秒级）。
9. **macOS 14**：入口置灰 + 版本要求说明；**macOS 15–25**：只显示翻译入口。

---

## 13. 导出选择矩阵

| 视频 | 烧录 | 独立字幕文件 |
| --- | --- | --- |
| 导出 | 无 / 原文 / 译文 / 双语 | 无 / 原文 SRT / 原文 VTT / 译文 SRT / 译文 VTT（多选） |
| 不导出视频 | — | 同上任意组合（剪辑页新增导出入口，复用 `SubtitleSerializer`） |

- **双语烧录 V1 样式合同（评审已定）**：导出时临时合成双行 cue 文档 ——
  **原文在上、译文在下**，两行**复用同一个 `BurnInStyle`**；V1 不做两轨独立
  字号/颜色/位置，未来再扩展独立样式。走现有 libass `subtitles` 滤镜
  （排在滤镜图最后的既有约定），**不回写**存储模型。
- **命名**：`<视频名>.<lang>.srt`（如 `movie.zh-Hans.srt`、`movie.en.srt`）；
  同目录冲突追加 `-2/-3`；双语文件 `.<src>-<dst>.srt`。
- **冲突与失败保护**：先写临时名 → 读回校验（能解析、cue 数一致）→ 原子替换；
  任何失败**不删不动**用户已有文件（transform-review / export-prerender-review
  两条教训的直接应用）。
- 重叠 cue 的事件顺序按第 9 节合同。
- 第一版不做内嵌软字幕轨（非目标）。

---

## 14. 性能策略

- **流式为王**：AVAssetReader 按区间分块读 PCM → `AnalyzerInput` 序列，
  任何时刻内存只有秒级音频缓冲；分析器资源懒加载、用完 `endRetention()`
  释放 [Apple 文档/SDK]。
- **串行**：系统限制并发分析数 [Apple 文档]，任务全局串行（EncodeQueue 先例），
  多素材排队。
- **长视频**：离线分析官方定位为 long-form（讲座/会议）[WWDC25-277]；
  数小时单文件 `inputAudioFile` 的稳定性列入真实视频验证 [待验证]；
  若不稳，退化为按素材区间分片喂 `inputSequence`（天然已是分片结构，
  且区间账本使分片结果可累积）。
- **翻译**：`translate(batch:)` 批量 AsyncSequence，避免逐句往返；
  批次大小做成常量，待实测调。
- 波形/缩略图既有 actor 缓存不受新管线影响。

---

## 15. 测试计划

依托现有四层自检（`swift run SrtFlowCoreChecks`、`check-project-file.sh`、
`check-preview-composition.sh`、`check-export-alpha-compositing.sh`）+ GUI 冒烟
（docs/testing/gui-smoke-testing.md）扩展：

### 15.1 单元/核心自检（SrtFlowCoreChecks + 新 checks/SubtitleGeneration/）

- 分段器：合成词流（标点/停顿/超长句/无标点）→ cue 约束全部满足；
  **变速 0.1×、1×、2×、8× 四档**：同一源词流在不同 speed clip 上分段正确、
  约束按时间线时长评估、8× 无解时 `readingSpeedWarning` 如实打标；
  双语重排版不改 cue 数/时间/ID。
- 边界合同（5.3）：分割/裁切合成用例 —— 中点归属唯一、clamp 正确、
  零时长丢弃、相邻分片无重复无遗漏。
- 重叠 cue 排序合同（9）：共享排序函数的稳定性与全序性。
- CueMeta 合同（7.3）**全部规则**：删除/拆分/合并/人工改文本/孤儿清理。
- 区间账本（11.2）：规范化合并、缺口计算、padding 去重、指纹/配置失效。
- `SubtitleCompanion` 宽容 Codable：缺键/多键/坏枚举不崩。

### 15.2 工程存盘/重开（check-project-file.sh 增补）

- v3 工程往返**仍写 v3**（无 v4-only 数据不升版）；
- 加 companion → 写 v4 且往返无损；**删除全部 v4 数据 → 回写 v3**（降级路径）；
- v3 工程打开兼容；伪造 v5 文件被拒开；
- 缓存 sidecar 缺失/损坏 → 工程打开与重新生成均安全退化。

### 15.3 真实视频验收矩阵（真机 + 真实素材，GUI 冒烟脚本化部分+人工）

- 语言：英语、中文、至少一种其他语言（如日语）；无语言 metadata 的文件
  （验证手选流程）。
- 音频场景：静音段开头、纯音乐、背景噪声、多人讲话、远场。
- 长视频（≥1 小时）：内存曲线平稳、可取消、断点续跑（区间账本命中）。
- 取消与重试：每个阶段中点取消 → 状态干净、临时文件清空、重跑成功。
- 不支持语言 / 模型未安装 / 下载失败（断网）三条错误路径；
  `isAvailable == false` 提示文案路径（若可模拟）。
- 变速/裁切/分割/多片段的 cue 时间映射抽查（对照波形）；
  分割点横跨句子的边界听感（5.3 Phase 0 项的回归）。
- **重叠 cue 一致性**：构造主轨+音频轨同时出声工程 → 预览截图与烧录抽帧
  对比堆叠顺序（第 9 节合同）。
- 烧录：原文/译文/双语三种导出目检（双语 = 原文上译文下、同一样式，13）；
  SRT/VTT 各组合导出后用 `SubtitleParser` 回读校验 + 第三方播放器抽查。
- 真实窗口冒烟：改名启动、按窗口 ID 截图、替换确认对话框与进度条截图留档。

### 15.4 可用性分层验收（评审新增）

- **macOS 14 真机/VM 启动验证**：App 正常启动运行现有全部功能，新入口置灰
  —— 这是「不预设 -weak_framework」策略的验收闸门（3.1）。
- macOS 15–25（真机/VM 任一）：翻译入口可用、转写入口按版本置灰。
- macOS 26+（本机）：全功能。

---

## 16. 分阶段实施（评审重排）

每阶段独立可验证、可 `git revert` 回滚；只列计划文件，动工时创建。
新代码全部开新文件；对超标文件（2.7）只做挂钩级改动。

**Phase 0 — 技术原型（spike，不进产品代码）**（2026-08-06 已完成大半）
- ~~availability/弱链接编译验证~~ **已完成**：spike 以 `-target arm64-apple-macos14.0`
  编译零告警、自动 weak 链接（3.1）。剩：产物在 macOS 14 真机/VM 启动不崩（15.4）。
- ~~Speech 原型~~ **已完成**：TCC 无弹窗（3.5）、真词级 `audioTimeRange` + 自带
  标点（6.3）、volatile/finalized 与进度（10.2）、`maximumReservedLocales` 与
  安装流程细节（3.3）、本机 `isAvailable == true`（3.2）。
  剩：reserve 超限失败形态（Phase 4 顺手补）。
- ~~Translation CLI 原型~~ **已完成**：三态错误面、`init(installedSource:)`
  不抛错、主队列依赖坑（3.4）。
- **TranslationSession host 与下载生命周期**（未完，需 GUI 原型）：
  模型下载交互、承载视图关闭、取消、重复任务、切工程五种行为（3.4），
  验证后固化第 10 节状态机与 host 设计。
- **边界规则真实音频验证**（未完）：分割点横跨句子时 5.3 合同的听感效果。
- 产出：验证结论已回填本文（17.2 销号清单）；spike 源码留档
  `checks/SubtitleGenSpike/main.swift`（一次性原型，不接四层自检）。
  回滚：删原型目录。

**Phase 1 — 数据模型与编辑合同**（2026-08-06 已完成）
- 已落地文件：
  - `Sources/SrtFlowCore/SubtitleCompanion.swift` —— companion 实体
    （译文轨/CueMeta/生成快照，宽容 Codable，cueMeta 以 uuidString 为键编码）
    + `LinkedSubtitleEditing` 纯函数合同（第 8 节规则 1–6 + normalize）；
  - `Sources/SrtFlow/VideoEditFormatVersion.swift` —— `requiresFormatVersion4`
    判据（v4-only 字段登记清单）+ 读盘规范化；
  - `Sources/SrtFlow/VideoEditProjectSubtitleLink.swift` —— 合同的工程层入口
    （每条操作一次 perform；含合同 0 生成替换、setSubtitleTranslation）；
  - 挂钩级改动：`TimelineState` 挂 `subtitleCompanion` 字段（空 companion
    不落盘）；`VideoEditProjectFile` 拆 `latestFormatVersion = 4` /
    `baselineFormatVersion = 3`，写盘按需定版，读盘闸门升到 4 并规范化；
    `attachSubtitle`/`removeSubtitle` 同一事务清 companion。
- 验证 [实测 2026-08-06]：SrtFlowCoreChecks 234 项（含合同规则 1–6、宽容
  Codable、normalize）+ check-project-file.sh 87 项（含 v3 往返不抬版、
  companion→v4 往返无损、删光降回 v3、v5 拒开、孤儿数据读盘清理）+
  preview-composition 13 项 + export-alpha 全绿。
- 回滚：revert（v4 按需写入保证未用新功能的工程始终 v3，回滚零影响）。

**Phase 2 — 翻译现有/导入字幕（macOS 15+）**（2026-08-06 已完成）
- 已落地：`SubtitleGen/TranslationHost.swift`（TranslationJobCoordinator 只存
  job/config/result + 常驻零尺寸 TranslationHostView，session 不出
  translationTask 闭包；挂载于 MainWindowView）+
  `SubtitleGen/SubtitleTranslationService.swift`（句级 batch、三档重译、
  运行时目标语言查询）；`applyTranslations` 工程入口（一次 perform 回写、
  清 stale）；「翻译当前字幕」入口在 SubtitleGenPanel。
- 验证 [实测 2026-08-06]：真实窗口冒烟 en→zh 全链路成功（见 Phase 4 记录）。
  macOS 15–25 实机分层验收仍待做（本机 26.5）。

**Phase 3 — 预览与烧录导出矩阵**（2026-08-06 已完成）
- 已落地：预览 overlay 改多 cue + 合同排序 + 轨道选择
  （`VideoEditView.currentSubtitleText`，`cues.last` 单查询已废）；
  `TimelineState.subtitleLaneRank/subtitleDocument(for:)` 共享助手；
  `Sources/SrtFlowCore/SubtitleExportPlanner.swift`（命名/冲突/原子写/双语合成）；
  导出面板新增 `SubtitleGen/SubtitleExportSection.swift`（烧录 无/原文/译文/双语
  + 独立原文/译文 × SRT/VTT 多选，不导视频也可导字幕），`startExport` 按选择
  换 `state.subtitle`。
- 验证 [实测 2026-08-06]：规划器/排序合同单测全绿；双语预览真实窗口目检 OK。
  烧录三选一的抽帧一致性回归待真实素材批量跑（15.3）。

**Phase 4 — 语音转写（macOS 26+）**（2026-08-06 已完成）
- 已落地：`SubtitleGen/AudioWindowReader.swift`（AVAssetReader → 16k 单声道
  临时 CAF，窗口级 defer 清理）、`SpeechTranscriptionService.swift`
  （status(forModules:) 驱动安装、词级属性抽取、cancelAndFinishNow）、
  `TranscriptionTask.swift`（状态机、阶段交界查 token、账本只补缺口、
  每缺口落 sidecar、documentGeneration 绑定、willTerminate 取消、
  SrtFlow-ASR-* 残留清扫）、`TranscriptSidecarStore.swift`（紧凑 JSON、
  原子写、校验、64MB LRU）；`Sources/SrtFlowCore/SubtitleSegmentation.swift`
  + `TranscriptLedger.swift`（纯函数，Phase 1 已建单测这轮补齐）；
  `SubtitleGenPanel.swift`（分层 UI、metadata 预填、替换确认、进度/volatile
  灰字/错误）+ `LinkedSubtitleEditor.swift`（双轨表格，走合同入口）。
- 验证 [实测 2026-08-06]：**真实窗口端到端冒烟通过** —— `say` 合成语音视频 →
  SRTFLOW_SMOKE_VIDEO 导入 → 面板选 en_US → Generate 产出 4 条 cue（时间线
  字幕行可见）→ 选 Chinese Translate All → 双语预览「Hello there. / 你好。」
  正确叠放。语言下拉 30 locale 全来自运行时查询；无字幕时翻译区如实提示。

**Phase 5 — 长视频、恢复与性能收尾**（代码已落地，长素材回归待跑）
- 已落地：取消令牌贯穿全阶段、断点续跑（sidecar 每缺口即存）、LRU 容量
  清理、启动残留清扫、进度单调；翻译成功回执（冒烟发现的缺口，已补）。
- 待真实素材回归（15.3）：≥1 小时内存曲线、各阶段中点取消、断网/未装模型
  错误路径、烧录矩阵抽帧一致性。

**V2（不在本计划承诺内）**
- 自动语言检测（3.7 蓝图）；DictationTranscriber 后备（验证后）；
  多译文语言；两轨独立烧录样式。

---

## 17. 风险、未确认事项与待办

### 17.1 风险

- **弱链接默认行为未证实**：macOS 14 启动验证是 Phase 0 闸门；证伪则走
  预授权后备（升 `.v15`，3.1.4）。
- **Translation host 生命周期复杂度**：session 不可离开 SwiftUI 上下文，
  五种边界行为验证前状态机不固化（3.4）。
- **长音频稳定性**：数小时单文件分析属官方宣称场景但未实测；缓解=区间分片
  （账本天然支持累积）。
- **识别质量不可承诺**：官方无任何准确率数字；第三方基准不作承诺依据。
  UI 用置信度标色对冲。
- **分段阈值经验性**：需真实语料回归调参；配置集中、默认待定。
- **下载体验不可控**：模型体积/时长官方未承诺，首次使用体验依赖网络与系统。
- **无网络环境**：模型未装则功能不可用 —— 错误路径必须清晰。

### 17.2 未确认事项（Phase 0 销号清单，2026-08-06 spike 已销部分）

已销号（结论已回填正文，spike 源码见 Phase 0 产出）：

1. ~~文件转写 TCC~~ → **无需 usage key、无弹窗**（3.5 [实测]；打包形态 Phase 4 复验）。
2. ~~编译与弱链接~~ → **tools 5.9 + 目标 14 编译零告警，Speech/Translation 自动
   weak 链接**（3.1 [实测]）；仅剩 macOS 14 真机/VM 启动验收。
3. ~~maximumReservedLocales~~ → **本机 5**；安装流程以 `status(forModules:)` 为准
   （3.3 [实测]）。reserve 失败形态（超限第 6 个）未试，Phase 4 补。
4. ~~标点与词级粒度~~ → **自带标点、真词级 audioTimeRange + confidence**（6.3 [实测]）。
5. ~~volatile/finalized 与进度~~ → **isFinal 分流清晰、finalization 单调可驱动进度**
   （10.2 [实测]）。
6. ~~init(installedSource:) 行为~~ → **不抛错、无下载权、三态错误面全验证**；
   已安装语言对可脱离 SwiftUI 翻译（3.4 [实测]）。

仍待验证：

7. TranslationSession host 五连测：**正常执行路径已实测通过**（真实 App 内
   en→zh Translate All 成功，2026-08-06 冒烟）；剩「需下载语言对的系统交互」、
   视图关闭、取消、重复任务、切工程四种边界行为。
8. macOS 14 真机/VM 启动（弱链接落地验收）；macOS 15–25 翻译路径实机验证。
9. 超长音频单文件 `inputAudioFile` 稳定性与进度可报性（需真实长素材）。
10. 5.3 边界合同的真实音频听感（需真实讲话素材）。
11. Intel `isAvailable` 取值（待有条件时；V1 仅影响提示文案）。
12. CLI 自检脚本注意：Translation 相关 checks 必须 run loop 结构
    （3.4 主队列坑 [实测]）。

### 17.3 待办与遗留决策

1. ~~`SrtFlow-Requirements.md:237`「非目标：自动语音识别」条款需同步改写~~
   → **已改**（2026-08-06）：该条从「非目标」移除，改写为需求书 §4.9
   「字幕生成与翻译（本机）」并链回本文。
2. 分段默认阈值（行宽/时长/CPS/停顿）—— 可调实现已落
   `SubtitleSegmentationConfig`，默认值需产品拍板。
3. 生成后时间线再编辑 cue 不自动跟随、需手动重新生成 —— 产品体验是否接受
   待实际试用反馈。
4. 删除关联 cue 目前无确认弹窗（编辑器 Delete 直接删，一步撤销可恢复）；
   拆分后译文后半置空的规则是否接受。
5. 低置信/stale/语速告警目前是编辑器行内三枚图标（?、循环箭头、⚠），
   呈现样式待产品确认。
6. 冒烟发现的 UX 待打磨 —— 三条里两条**已修**（2026-08-06），详见
   [bugfixes/2026-08-06-subtitle-panel-language-defaults.md](../bugfixes/2026-08-06-subtitle-panel-language-defaults.md)：
   - ~~目标语言默认值应重排到已装语言优先（现取首个字母序）~~ → **已修**。
     实际比本条描述的严重：「翻译现成字幕」这条路径上源语言**可能一直是 nil**，
     那个字母序默认值不是暂时的而是最终生效的 —— 默认会把字幕翻成阿拉伯语。
     修法是排序补一层系统首选语言（已装 → 系统首选 → 字母序），并区分
     「用户选的」和「自动挑的」默认值。顺带修掉「对每个语言都假称需要下载」。
   - ~~面板 Picker 对不可用轨道的置灰在 segmented 样式下不生效~~ → **已修**：
     没有译文时干脆不显示该控件（原来点了会让预览字幕静默消失），读取侧另加兜底。
   - 时间线字幕行仍按原文轨几何显示（两轨同时间，几何一致，深度编辑走双轨
     编辑器）—— 这条是**已接受的设计**，不是待修项，保留在此备查。

（已由 2026-08-06 评审拍板，不再是开放问题：构建基线不动、分层可用性、
canonical/companion、按需 v4 与降级、sidecar 缓存、V1 手选语言、
V1 无 Dictation 后备、双语行序与样式、重叠 V1 全保留+排序合同。）

---

## 18. 完成标准

- 每个 Phase 的验证项全绿才进入下一 Phase；任一 Phase 可单独 revert 且
  其余 Phase 不受影响。
- 功能级完成标准：
  1. macOS 26+：对 en/中/至少一种其他语言的真实视频，端到端产出双语字幕
     并可编辑；macOS 15–25：对现有/导入字幕完成翻译、预览与导出；
     macOS 14：现有功能零回归、新入口置灰（15.4 分层验收全绿）。
  2. 源语言 metadata 预填 + 手动选择流程可用；手动覆盖永远可用。
  3. 导出矩阵全部组合实测通过，失败场景用户文件零损坏；
     重叠 cue 预览/烧录一致。
  4. 1 小时以上视频全程内存平稳、任意阶段可取消且清理干净、断点续跑。
  5. v3 工程打开无损且往返仍写 v3；companion 工程 v4 往返无损；
     删除 v4 数据可降回 v3；旧版 App 拒开 v4。
  6. 四层自检 + GUI 冒烟全绿；所有 Apple API 结论在文档中保持
     「已确认/待验证」标记同步更新（Phase 0 后回填 17.2）。
- 文档义务：动工后按 AGENTS.md 规则补 bugfix 案例与 architecture 长期约束。

---

## 19. 回滚方案

- **代码**：全部改动按 Phase 提交（每 Phase ≥1 个独立 commit），回滚 =
  `git revert` 对应 Phase；Phase 1 之前无用户可见功能。
- **构建**：`Package.swift` 全程未动，无构建基线回滚问题。
- **工程文件**：v4 是**按需写入**的 —— 只有真正使用了译文/生成功能的工程
  才写 v4；这类工程删除 v4 数据后可自然降回 v3（7.4，有测试）。
  整体回滚时，未用新功能的用户零影响；已写 v4 的工程按既定政策由旧版拒开
  （拒开胜过静默毁字段），回滚前提示用户。
- **模型资产**：系统域资产不属 App 管理，无需回滚；reservation 已释放。
- **缓存与临时文件**：`~/Library/Caches/SrtFlow/Transcripts/` 与
  `SrtFlow-ASR-*` 目录可随时安全删除（可重建缓存）。
