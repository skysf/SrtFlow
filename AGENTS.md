# AGENTS.md — 统一协作入口与文档索引

本文件是本仓库**唯一的代理协作规则入口**，适用于 Claude、Codex、Kimi、Gemini、
Copilot 等所有 AI 代理、它们委派的子代理，以及人类贡献者。作用域覆盖整个仓库。

这里只保留两类内容：**必须全局遵守的规则**和**按任务查文档的索引**。设计细节、
历史事故、实施过程和操作步骤分别放在 `docs/` 的对应目录，不在这里展开。

## 唯一入口约定

- 所有代理开始工作时都只读取本文件作为仓库规则；委派子代理时也必须传递本文件的
  约束，不能为不同模型维护不同版本。
- 不得新建 `CLAUDE.md`、`CODEX.md`、`KIMI.md`、`GEMINI.md`、嵌套
  `AGENTS.md`、`.cursorrules`、`copilot-instructions.md` 等第二套规则入口。
- 工具自己的本地配置只能存权限、Hook 等运行设置，不得复制或改写项目规则。
- 新的细节规则应写进 `docs/architecture/` 等对应文档，并从本文件增加链接；不要把
  本文件重新堆成实施记录。

## 开始任务前

1. 先读下方“全局规则”。
2. 在“按修改范围选必读文档”中定位任务，动代码前读完对应文档。
3. 计划文档记录目标和背景；已实施功能的真实状态优先看实施报告、现有代码和检查
   结果。若三者冲突，不要静默猜测，应在本次改动中同步过期文档或明确报告冲突。
4. 修改后先跑直接相关的单项检查；准备提交或发 PR 前跑 `scripts/check-all.sh`。

## 全局规则（必须遵守）

### Bug 修复、守卫与文档

1. 修复任何 bug 后，必须按
   [Bugfix 模板](docs/bugfixes/TEMPLATE.md) 在 `docs/bugfixes/` 新增
   `YYYY-MM-DD-<slug>.md`，完整记录“症状 → 根因 → 修复 → 验证 → 教训”，并在
   本文件的 Bug 修复案例索引补一行。
2. 自动化能覆盖的 bug，必须在对应 check 中加入一条修复前会失败的回归守卫，并做
   **反向验证**：临时撤掉修复，确认守卫确实变红，再恢复修复。没红过的守卫不能算
   验证。
3. 自动化够不着的行为（例如手势手感、TCC、系统 UI）必须写入对应架构文档的人工
   回归清单，并在发版前实机验证。
4. 案例中形成的长期约束（“这里只能这样做”）必须另写或更新
   `docs/architecture/` 文档，再由案例链接过去，不能只留在一次性事故记录里。
5. 其他新文档归入 `docs/` 对应分类，并在本文件补索引；能更新既有文档时不要另造
   一份相互竞争的说明。**补索引不是礼节，是必需**：别的代理只读本文件，索引里
   没有的文档它们永远不会打开 —— 由 `checks/docs-index-drift.sh` 钉住（漏一份
   或留一条死链就红）。

### 合并与分支（2026-09-29 用户定）

- 一个 PR 只做一件事、尽量小；CI 的汇总 job `check-all` 绿了就**马上合并**（`gh pr merge N --merge --delete-branch`，
  绝不 squash），不攒着等人看。下一件事从合并后的最新 main 开分支，别在旧分支上叠。
- 「绿」指 CI 的结论，本地跑过不算。红了先看是不是已知的偶发（性能 ratchet、`check-audio-fade` 第 7b 组，认法见对应
  文档），是就 `gh run rerun --failed`，不是就修；不许带红合。
- 合掉一个之后别的 PR 变 DIRTY（常见于本文件的索引行相邻）：把新 main 合进那条分支、两边都留、推上去等 CI 绿再合。
- 合进 main 不等于发给用户：发版（打 tag、`gh release create`、DMG）仍然另外拍板。

### 语言

- GitHub 对外可见文字一律使用英文：commit message、分支名、PR、issue、release，
  以及 Actions 的 workflow、job、step 名称与正文。
- `README.md` 保持中英双语；仓库内部 `docs/`、本文件和代码注释维持现状使用中文。

### 工程原则

1. **轻量化优先。** 优先复用 macOS 原生能力（AVFoundation、AppKit、SwiftUI），
   不随意引入第三方依赖。需要自写合成器、自建文件管理等重量级方案时，先征得用户
   同意。既有产品决策：界面上的文件管理交给 Finder（AI 只在用户开口时帮忙整理点名文件夹里的文件，删除先问、进废纸篓，
   见 [MCP 方案](docs/plans/2026-09-27-mcp.md) 第 23、24 条）；混合模式不为此自建 Metal 合成器。
2. **复用优先，抽象克制。** 同一模式出现第二次时，按仓库现有粒度抽成共享组件；
   没有真实第二用例时不提前制造泛型和框架。参考：`ResizableFrameBox`、
   `LenientCodableEnum`、`liveApply` / `perform`。
3. **代码要模块化，单文件不许太长**（2026-09-24 用户定的规范，细则见
   [写代码的规范](docs/architecture/coding-standards.md)，**写代码前必读**）：
   - 一个文件只管一件事，新类型、新功能默认开新文件；文件开头写清它管什么、不管什么。
   - **单文件目标 ≤ 400 行，超过 600 行就红**（Swift / shell / Python，测试和检查脚本
     也算）：`checks/source-file-size.sh`。超了就拆，不许靠删注释、挤行凑数。
   - 当时就超了的老文件登记在 `checks/source-file-size-baseline.txt`，**行数只许降不许涨**：
     往里加代码就在同一次改动里拆出等量的行；变短了跑 `checks/source-file-size.sh --update`
     把基线改小。可以顺手拆出职责独立的部分，但不要借题做一次性大重构。
   - 拆的时候优先抽出**有名字的顶层类型**（纯值、接口窄、自检能单独编），不要给
     `VideoEditProject`、`TimelineState` 这种大对象再开一个只有 extension 的文件。

### 验证纪律

- 不得把“命令没执行到”“依赖缺失后跳过”或“只测了纯函数、生产路径没接上”报告为
  通过；检查脚本必须以非零退出码暴露失败。
- `scripts/check-all.sh` 是本地与 CI 的统一总入口。GUI 冒烟不在其中，涉及真实窗口、
  系统权限或手势时，另按 [GUI 冒烟流程](docs/testing/gui-smoke-testing.md) 执行。
- 修改 shell 脚本前，先读
  [构建版本与 shell 陷阱](docs/bugfixes/2026-08-06-build-version-and-shell-traps.md)。

## 文档目录职责

| 目录 | 放什么 | 不放什么 |
| --- | --- | --- |
| `docs/architecture/` | 已生效的长期约束、数据合同、回归清单 | 一次性修复流水账 |
| `docs/bugfixes/` | 可复盘的 bug 案例与验证证据 | 尚未实施的设想 |
| `docs/plans/` | 功能方案、产品决策、阶段计划 | 冒充当前实施状态 |
| `docs/reports/` | 实施进度、实测结果、偏差和阻塞 | 通用架构规则 |
| `docs/build/` | 构建、打包和产物验收 | 功能设计 |
| `docs/testing/` | 测试与人工冒烟流程 | 某一次 bug 的完整经过 |

## 按修改范围选必读文档

| 修改范围 | 动手前必读 |
| --- | --- |
| 构建、打包、版本、授权、shell、CI | [构建与打包](docs/build/build-and-packaging.md)、[构建版本与 shell 陷阱](docs/bugfixes/2026-08-06-build-version-and-shell-traps.md)、[包内授权声明](docs/bugfixes/2026-08-06-stale-bundled-license-notice.md)、[CI 首跑与吞错](docs/bugfixes/2026-08-08-ci-first-run-sdk-and-swallowed-errors.md) |
| 工程存盘、格式版本、素材路径、自动保存、**重建预览时开素材（`MediaAssetCache`）**、**新建 / 打开工程（切工程时清掉上一个的运行时状态、播放头归零）** | [工程文件与素材重链接](docs/architecture/video-edit-project-file.md)（四之末：运行中素材只开一次，按路径 + 文件身份认，原地改写也算换了文件；五：卸片之后播放器的时间回调晚到一拍、没挂条目就丢掉，换完整份时间线就要 `scheduleRebuild()`）、[新工程停在上一个工程的位置](docs/bugfixes/2026-09-29-new-project-keeps-old-playhead.md)、[工程生命周期事故](docs/bugfixes/2026-08-03-project-file-lifecycle.md)、[运行期素材重链接](docs/bugfixes/2026-08-08-runtime-media-relink.md)、[重建把每个素材重新打开一遍](docs/bugfixes/2026-09-25-rebuild-reopens-every-asset.md) |
| 时间线捏合、滚动、移动、裁切（一段能裁多少、多段一起裁、链接伙伴一起裁）、吸附与对齐线（裁切也吸）、框选、点击落点（点空白 / 点块本体都移播放头，唯一入口 `VideoEditProject.seekFromTimeline`，§5f）、扫帧预览、**拖动 / 拉框进行中的视图状态（`TimelineDragBox`）**、**缩放的锚点（捏合钉指针、工具栏钉播放头）与纵向缩放（统一行高）** | [捏合缩放](docs/architecture/timeline-pinch-zoom.md)（锚点从时间线自己的滚动几何量，别按坐标 hitTest 找滚动视图；纵向缩放统一成一个高度）、[锚点从来没生效](docs/bugfixes/2026-09-26-pinch-zoom-anchor-never-applied.md)、[拖动手势](docs/architecture/timeline-drag-gestures.md)（§0b 会话不进时间线的 `@State`：盒子持有不订阅、块只收自己那份；§3.6 裁的算法只有 `TimelineTrim` 一份、整组一起停）、[拖动卡顿与落点](docs/bugfixes/2026-08-09-timeline-clip-drag-lag-and-alignment.md) 、[拖文件进轨道](docs/plans/2026-09-22-media-file-drop.md)、[裁切不跟链接](docs/bugfixes/2026-09-25-trim-ignores-linked-clips.md)、[拖动会话住在时间线的 @State 里](docs/bugfixes/2026-09-25-drag-session-in-timeline-state.md) |
| 插进两条轨之间（缝拉开）、整条轨上下换位置、轨道头的拖动（换位 / 下边缘调行高） | [插入缝与整轨换位方案](docs/plans/2026-09-24-track-insert-and-reorder.md)、[拖动手势](docs/architecture/timeline-drag-gestures.md)（§5h 插入缝、§5i 整轨换位）、[视频轨对等化](docs/architecture/video-tracks.md)（轨道头这一列）、[预览性能 ratchet](docs/architecture/preview-perf-ratchet.md)（轨道头的行每跳不重算，别往它的输入里塞闭包） |
| 编辑器分栏、预览区/时间线的行结构与最小高度 | [播放条压到工具栏上](docs/bugfixes/2026-08-12-preview-transport-row-overlap.md) |
| 预览变换、叠化、上层视频轨、导出滤镜、**预览合成往合成轨上接东西（只从末尾接、合成完裁到总长、换格子别改成四舍五入、切片表按格子去重、主轨接缝不到 0.01 秒的零头不算空隙）** | [预览自由变换](docs/architecture/preview-free-transform.md)（「一份时间账」：多一格就黑屏）、[加了音效预览整个黑屏](docs/bugfixes/2026-09-27-preview-black-after-audio-tick-pushed-past-end.md)、[叠化 + 关键帧之后预览全黑](docs/bugfixes/2026-09-29-preview-black-slice-boundaries-straddle-a-tick.md)（边界各自截断落在相邻两格；两条管线同一个 `mainGapTolerance`）、[视频轨对等化](docs/architecture/video-tracks.md)、[关键帧动画](docs/architecture/keyframe-animation.md)、[Transform 复审](docs/bugfixes/2026-08-04-transform-review.md)、[预渲染复审](docs/bugfixes/2026-08-05-export-prerender-review.md) |
| 从 Finder 拖文件 / ⌘V 粘贴文件进时间线、导入落点 | [拖文件进轨道](docs/plans/2026-09-22-media-file-drop.md)、[卡片被文件落点吞了](docs/bugfixes/2026-09-23-in-app-drops-swallowed-by-file-underlay.md)、[外部拖入被内层落点独占](docs/bugfixes/2026-09-23-timeline-file-drop-claimed-by-inner-drop-region.md)（结论已更正）、[拖动手势](docs/architecture/timeline-drag-gestures.md)（主轨保序、§5e-2 唯一落点）、[视频轨对等化](docs/architecture/video-tracks.md) |
| 时间线上的复制 / 剪切 / 粘贴（⌘C ⌘X ⌘V、编辑菜单、块和轨道空白处的右键菜单）、剪贴板类型、粘贴落点（鼠标优先、否则播放头）、从旧段构造新段（分割 / 复制，别漏字段）、**分割之后的链接组** | [复制粘贴](docs/architecture/timeline-clipboard.md)（剪贴板只有一套、不写纯文本；每一样换新身份走编码往返；撞上了往上抬、几组保住上下关系；三之二：分割都走 `LinkRegrouping.split`，一对切开是两对）、[分割后整串互为伙伴](docs/bugfixes/2026-09-28-split-links-every-piece-together.md)、[方案](docs/plans/2026-09-26-timeline-clipboard-and-zoom.md)、[分割丢了隐藏和音频库的键](docs/bugfixes/2026-09-26-split-drops-hidden-and-library-key.md)、[拖文件进轨道](docs/plans/2026-09-22-media-file-drop.md) |
| 时间线上的任何拖放落点（`.onDrop`：文件 / 滤镜 / 音频库 / 转场卡片）、新的自定义拖放 / 剪贴板类型 | [拖动手势 §5e-2](docs/architecture/timeline-drag-gestures.md)（整条时间线只许一个 `.onDrop`；自定义类型必须在 Info.plist 声明；不能放回 `.forbidden` 不回 `.cancel`）、[转场拖放被 `.cancel` 取消](docs/bugfixes/2026-09-23-transition-drop-cancel-ends-session.md)、[卡片被文件落点吞了](docs/bugfixes/2026-09-23-in-app-drops-swallowed-by-file-underlay.md)、[自定义类型没声明](docs/bugfixes/2026-09-23-custom-drag-types-not-declared.md)、[GUI 冒烟流程](docs/testing/gui-smoke-testing.md)（落点路由探针） |
| 轨道模型、时间线行结构、轨道行高、轨道配色、预览点选 | [视频轨对等化](docs/architecture/video-tracks.md)、[工程文件与素材重链接](docs/architecture/video-edit-project-file.md) |
| 段的显隐（V / 眼睛）、隐藏段进不进预览和成片，文字 / 形状 / 滤镜段的隐藏（`rendered*` 清单） | [段的显隐](docs/architecture/clip-visibility.md)、[视频轨对等化](docs/architecture/video-tracks.md)、[上层轨藏起来的段还在成片里](docs/bugfixes/2026-09-26-hidden-upper-clip-still-exported.md) |
| 画面渐入渐出、alpha 斜坡、转场仲裁 | [画面渐入渐出](docs/architecture/video-fades.md)、[声音：音量与渐入渐出](docs/architecture/audio-fades.md) |
| 主轨转场的容量、可用判定、借余料、首尾帧定格补足 | [主轨转场：借余料与定格补足](docs/architecture/transition-handles.md)、[转场预览有、成片没有](docs/bugfixes/2026-09-20-transition-preview-export-divergence.md) |
| 画面段的入场/出场动画、预设效果、预渲染路由 | [画面段的入场 / 出场动画](docs/architecture/clip-animation.md)、[画面渐入渐出](docs/architecture/video-fades.md)、[关键帧动画](docs/architecture/keyframe-animation.md) |
| 画面文字、字体、Core Text 渲染、文字动画、逐帧导出、预览上文字的选中框和可点范围、**文字行（行号进模型、行序 = 叠放序、上下换行）**、数字的等待、**老虎机位数不同的两头（`NumberOdometer`）** | [画面文字](docs/architecture/text-overlays.md)（把手的可点范围写在 `.offset` 之前；没选中的字只认看得见的部分；行号进模型，预览与导出同一份叠放序；老虎机不存在的那一位滚成空白收掉，居中和右对齐右边不动）、[老虎机停在「090」](docs/bugfixes/2026-09-25-odometer-leading-zero.md)、[主字体里没有的字画成乱码](docs/bugfixes/2026-09-29-text-fallback-glyphs-drawn-with-main-font.md)（排版给了谁的字形号就用谁画）、[拖动手势 §5j](docs/architecture/timeline-drag-gestures.md)、[拖字变成旋转](docs/bugfixes/2026-09-24-text-rotate-handle-hit-area-at-center.md) |
| 滤镜调色、LUT、预览图层滤镜、导出 `lut3d` 段、滤镜段的选中（多选） | [滤镜](docs/architecture/filters.md) |
| **盖一块（模糊 / 马赛克，`ShapeKind.blur` / `.mosaic`）**、预览的第二层播放器（`CoverPreviewLayer`）、导出里的 `gblur` / `pixelize`（`VideoEditCoverExport`）、`set_shape` 的 blur / mosaic、`look text_scan` 给的 `cover`（`AICoverBox`）、遮水印 / 遮旧字幕 | [盖一块](docs/architecture/cover-blur-mosaic.md)（形状的一种、时间线上的一段、**不跟着片段走**；落点在调色之后、形状之前；三条管线按构造一致：裁出这一块、在这块里做效果、边缘外延、贴回去；预览的蒙版和滤镜别挂同一层；`CIPixellate` 的格子要设成从左上角起算；框取偶数往外收；力度按画面高换算）、[滤镜](docs/architecture/filters.md)（预览不走自定义合成器、图层滤镜的地基）、[预览自由变换](docs/architecture/preview-free-transform.md)（源画面框换画布框的变换顺序）、[AI 接口（MCP）](docs/architecture/ai-control-mcp.md)（第 38 条）、[预览性能 ratchet](docs/architecture/preview-perf-ratchet.md)（没有盖一块时第二层不建、性能计数不变） |
| 工程帧率、关键帧容差、**AI 读写关键帧（报出来的永远在片段范围里、`edit_clip keyframes` 策略、`relative` 时间）**、**关键帧的缓动（`Keyframe.easing`、`KeyframeEasing`、预览按帧加密 `KeyframeSliceTimes`、AI 默认 easeInOut）** | [工程帧率](docs/architecture/project-frame-rate.md)、[关键帧动画](docs/architecture/keyframe-animation.md)「AI 接口」「缓动」（linear 逐位一致、只对画面的六条轨、v27）、[限幅 + 缓动方案](docs/plans/2026-09-30-export-limiter-and-easing.md) |
| 音量、dB、渐入渐出、增益表（`AudioGainTable.swift`）、**音频引擎（`Sources/SrtFlow/AudioEngine/`：配置、环、喂样、渲染块、离线渲染）**、预览合成里没有音轨（配乐比画面长要垫黑底） | [声音：音量与渐入渐出](docs/architecture/audio-fades.md)、[成片的声音](docs/architecture/export-audio-mixdown.md)、[音频引擎](docs/architecture/audio-engine.md)（合同：段落和增益的规则只有一份、渲染块实时安全、一段一条流；第三节：合成里只有画面、画面收得早要垫黑底铺到总长）、[条目比时间线短](docs/bugfixes/2026-10-01-preview-item-shorter-than-timeline-without-audio-tracks.md)、[音频引擎方案](docs/plans/2026-10-01-audio-engine.md)（分刀和数字） |
| 声音场景（喇叭 / 室内 / 室外）、引擎渲染块里的效果链（`SceneBox` / `mixScene`）、余音越过段尾、检查器的声音那一块 | [声音场景](docs/architecture/sound-scenes.md)（效果在段增益之后、推子之前；一段一条链、段尾之后喂零散余音；加 / 去掉场景重开流）、[推子与电平表](docs/architecture/audio-mixer.md)、[成片的声音](docs/architecture/export-audio-mixdown.md)、[声音场景方案](docs/plans/2026-09-24-sound-scenes.md) |
| 导出的声音、离线混音（`ExportAudioMixdown`）、导出图里接音轨的地方、**限幅器（`ExportPeakLimiter`）、整段响度（`ExportLoudnessMeter`、`AudioKWeighting`）、面板和 `get_job` 里的响度 / 峰值 / 压了多少** | [成片的声音](docs/architecture/export-audio-mixdown.md)（导出图里不许有声音滤镜；成片 = 预览那个音频引擎离线渲出来的、同一份 `AudioEngineConfig`；写 f32 之前过真峰值限幅器、上限 −1 dBFS、总长不变，响度只报不归一，预览不限幅是已知差异）、[限幅 + 缓动方案](docs/plans/2026-09-30-export-limiter-and-easing.md)、[过 0 交给 AAC](docs/bugfixes/2026-09-30-export-mix-over-0dbfs-into-aac.md)、[阻塞的媒体读取](docs/architecture/blocking-media-reads.md)、[转场那条缝上预览的声音掉下去](docs/bugfixes/2026-09-24-preview-mix-ignores-transition-expansion.md) |
| 波形显示、深度缩放（缩放上限、标尺刻度、缩略图、超宽内容的绘制） | [波形与深度缩放](docs/architecture/audio-waveform.md)、[捏合缩放](docs/architecture/timeline-pinch-zoom.md)、[拖动手势](docs/architecture/timeline-drag-gestures.md) §5、[阻塞的媒体读取](docs/architecture/blocking-media-reads.md) |
| `AVAssetReader` 读采样（`copyNextSampleBuffer`），以及在 async 函数 / `Task` 里做任何会卡住线程的事（等信号量、同步 IO、等子进程） | [阻塞的媒体读取](docs/architecture/blocking-media-reads.md)、[缩略图和波形全空](docs/bugfixes/2026-09-23-waveform-decode-deadlocks-thread-pool.md) |
| 音量曲线（段上的音量自动化）、轨道推子 / 总推子、电平表（引擎的槽 `MeterSlot`） | [音量曲线](docs/architecture/audio-volume-curve.md)、[推子与电平表](docs/architecture/audio-mixer.md)（第三节：峰值从渲染块来、总表从混音器出口来、槽按键登记、界面每拍取走）、[播放中按 Return 崩溃](docs/bugfixes/2026-09-26-meter-crash-on-go-to-start.md)、[声音：音量与渐入渐出](docs/architecture/audio-fades.md)、[声音编辑方案](docs/plans/2026-09-23-audio-mixing.md)、[一条轨上换了音频格式](docs/bugfixes/2026-09-23-meter-tap-dies-on-audio-format-change.md) |
| Inspector 数值框、拖调、Transform 写入、检查器里的滑杆行（`labelledSlider` / `InspectorSliderRow`，右边的数值框能打字）、「Shows for」、**Transform 区的关键帧 ‹ ◇ › 和「曲线」菜单** | [Inspector 数值框合同](docs/architecture/inspector-scrub-number-field.md)（滑杆行的数值框：打字提交要立刻 `endLiveEdit`）、[关键帧动画](docs/architecture/keyframe-animation.md)「交互约定」（曲线菜单按播放头所在那一段） |
| 往检查器里加任何一行（标题 + 控件、下拉、滑杆行） | [检查器的排版](docs/architecture/inspector-layout.md)（固定窄栏，一行不许比它宽；菜单 Picker 不许 `.fixedSize()`）、[声音场景那一行把检查器撑宽](docs/bugfixes/2026-09-24-sound-scene-row-widens-inspector.md) |
| 定格、静帧、图片转视频、**在最后一帧里定格（不到一帧的右半）** | [定格长期约束](docs/architecture/freeze-frame.md)（第 4 节：不到一帧的右半拿掉）、[静帧后面剩一截](docs/bugfixes/2026-09-29-freeze-leaves-sliver-after-still.md)、[定格方案](docs/plans/2026-08-08-freeze-frame.md)、[静帧逐帧解码事故](docs/bugfixes/2026-08-08-still-clip-decode-per-frame.md) |
| 原生录屏、恢复、退出、导入 | [录屏生命周期](docs/architecture/screen-recording-lifecycle.md)（含产物合同）、[实施报告](docs/reports/2026-08-06-native-screen-recording-implementation-report.md)、[Phase 2–4 复审](docs/bugfixes/2026-08-07-screen-recording-phase2-4-review.md)、[静止期尾部黑屏](docs/bugfixes/2026-08-11-screen-recording-idle-tail-black.md)；方案中的旧结论不得覆盖实施报告 |
| 字幕生成、语言检测、翻译、任务取消、**转写哪些声音（可听快照）**、**生成 / 翻译结束时回写工程** | [字幕语言流](docs/architecture/subtitle-language-flow.md)（第 7 条：可听快照与预览同一份隐藏过滤）、[回写要自己成一步撤销](docs/bugfixes/2026-09-27-ai-undo-swallowed-by-subtitle-attach.md)（包在 `AIUndoGrouping.step` 里）、[原生字幕生成方案](docs/plans/2026-08-06-native-subtitle-generation.md)、[字幕生成复审](docs/bugfixes/2026-08-06-subtitle-generation-review.md)、[PR #22 后续复审](docs/bugfixes/2026-08-09-pr22-review-followups.md)、[藏起来的片段照样被转写](docs/bugfixes/2026-09-26-subtitle-generation-transcribes-hidden-clips.md)、[自动检测拿音效当探针](docs/bugfixes/2026-09-26-auto-detect-probes-sound-effects.md)（探针长的先、先听有没有人声） |
| 生成出来的字幕长什么样：**去标点**、**断句**（逗号拆小句、太短的并、并不进去整句一起挑、放不下的怎么切、中文按词边界）、**一行多长**（字数 + 画面宽度）、**显示时间**（最短、2 帧间隔、接上、说完多停）、**几段素材同时有字只留一条**、面板上「只用选中的片段」、机器翻译落字去标点 | [生成的字幕长什么样](docs/architecture/subtitle-generation-style.md)（先断句后去标点、时间在整条轨上排；**停顿被识别器并进相邻的词，先估开口**；切法是动态规划不是贪心；中文按整句判语言；去重叠只比不同素材）、[停顿被算进相邻的词](docs/bugfixes/2026-09-26-pause-stretches-next-word.md)、[切出 0.1 秒的一条](docs/bugfixes/2026-09-30-subtitle-piece-on-screen-0.1s.md)（太短按能留多久罚、并不进去整句一起挑）、[方案与调研](docs/plans/2026-09-26-subtitle-generation-style.md)（别的剪辑软件怎么做、Netflix / BBC 的数字、用户逐条拍的板） |
| 字幕轨、眼睛、预览叠层、烧录、布局、**预览上字幕画多大（按 libass 的字号口径）**、选择（点选互斥 / 框选混选 / ⌘A 全选 / ⌘⇧A 取消 / 滤镜多选）、字幕的三个编辑入口、**工程自己的字幕样式（`subtitleStyle(appWide:)`）与逐词高亮（词的时间、预览和烧录同一份）**、**原文 / 译文两条独立轨**（挪裁删拆互不影响、译文的来源表、两个翻译按钮、画面上叠在一起 / 分开摆、按时间切块）、预览上字幕块量高度 | [字幕轨可见性与布局](docs/architecture/subtitle-track-visibility-and-layout.md)（第 3 条：两条轨独立、来源表现算过期；布局 2：译文布局为 nil = 叠在原文下面、量块高不许被默认值盖掉；「工程自己的样式与逐词高亮」：用样式只问 `subtitleStyle(appWide:)`、只有带词时间的句子亮、词的时间跟着编辑走）、[成片比预览小](docs/bugfixes/2026-09-29-subtitle-preview-bigger-than-burn.md)（预览只用 `BurnInSubtitleOverlay` 画，按实际画字的那一款字体乘 `SubtitleFontScale`）、[预览的位置和行距和成片对不上](docs/bugfixes/2026-09-29-subtitle-preview-line-box-differs-from-libass.md)（行框也按 libass 的摆：`SubtitleLineMetrics`，一行一个 Text 放 VStack、负行距要靠它、整块按对齐挪一点只动画面）、[没下载苹方时中文烧成方框](docs/bugfixes/2026-09-29-chinese-burns-as-boxes-without-pingfang.md)（回退到系统私有字体时预览和烧录一起换内置字体，烧录用 `\fn` 点名）、[圆体烧录英文变「f=」](docs/bugfixes/2026-09-29-yuanti-cmap-breaks-libass-latin.md)（字幕字体清单扫描要过 cmap 体检，坏的不进清单）、[叠在一起时点英文落到中文](docs/bugfixes/2026-09-26-stacked-subtitle-frame-lands-on-translation.md)、[拖动手势 §3.5b](docs/architecture/timeline-drag-gestures.md)、[两条独立轨的方案](docs/plans/2026-09-26-hide-guides-independent-subtitles.md) |
| 标记（所有块 + 标尺：锚在宿主自己的时间轴上、裁头不挪、M 的落点只有一份、点标尺 = 选中标尺）、时间线块 overlay、扫帧 peek | [标记](docs/architecture/clip-markers.md)（单击只选中、双击才弹面板：点一下就弹带输入框的面板 = 交出键盘；第十一节：标尺选中着 M 才打标尺、不算有东西可删）、[悬停影子播放头](docs/bugfixes/2026-08-08-hover-ghost-playhead-and-delete-key.md)、[标记 ⌫ 删不掉](docs/bugfixes/2026-09-24-marker-delete-key-eaten-by-note-field.md) |
| 音频库（音乐 / 音效两个 store、面板的分段、`AudioLibraryLookup` 两个库一起找）、manifest（`hit` / `title_zh` / `owned`）、试听、素材缓存、署名（只问 `needsCredit`）、**音效（合成器 + 录音素材库）** | [音频库](docs/plans/2026-09-22-audio-library.md)、[音效方案](docs/plans/2026-09-30-sound-effects.md)、[音频库素材管线](docs/build/audio-library-pipeline.md)、[素材管线](docs/build/audio-library-pipeline.md)、[声音：音量与渐入渐出](docs/architecture/audio-fades.md)（ducking 的夹紧点）、[AI 接口](docs/architecture/ai-control-mcp.md) §4 第 23 条（AI 搜音乐、放上时间线、署名句，和界面同一个搜索函数、同一个署名口径） |
| 导出面板、编码设置、分辨率档位（压缩 / 烧录 / 剪辑导出）、导出文件名与撞名（面板上先问再替换；批量转换、压缩 / 烧录、AI 的输出加编号，`ExportFileName.unoccupied`）、**压缩 / 烧录记住的设置和全 App 的字幕样式** | [导出设置](docs/architecture/export-settings.md)（面板上只放管线真消费的设置；记住的设置在队列创建时读回来，不挂在页面的 `onAppear` 上）、[字幕样式要先去烧录页转一圈](docs/bugfixes/2026-09-27-remembered-subtitle-style-waits-for-burn-in-page.md)、[导出面板改版方案](docs/plans/2026-09-24-export-panel.md)、[竖屏被缩小](docs/bugfixes/2026-09-24-resolution-cap-shrinks-portrait-video.md)、[音频原样复制是假话](docs/bugfixes/2026-09-24-export-panel-promised-audio-copy.md) |
| 读用户给的文本文件（字幕文件、讲稿、笔记）的编码 | [用户文本文件的编码](docs/architecture/text-file-encoding.md)（只走 SrtFlowCore 的 `TextDecoding`；UTF-16 不许无条件排在 GBK 前面）、[GBK 字幕读成乱码](docs/bugfixes/2026-09-27-gbk-subtitles-read-as-utf16.md) |
| 任何按钮的提示文案、快捷键、hover | [即时提示](docs/architecture/instant-tooltips.md) |
| 预览性能、性能计数与基线；**新写或改写任何 SwiftUI 视图 / 修饰器 / `NSViewRepresentable` / Canvas**（body 第一行要计数，写完跑 `checks/preview-perf-wiring.sh --fix` 自动补）；性能那一步红了但没动编辑器界面；**往时间线上加一种块 / 行里的列表项**；**任何要跟着播放头变的界面**（订阅播放器时钟、在 body 里读 `clock.time`、按钮能不能点看播放头）；**在视图 body 里读工程的属性、给 `VideoEditProject` 加属性**（工程是 `@Observable`） | [预览性能 ratchet](docs/architecture/preview-perf-ratchet.md)（计数必须接满、只许降、**已知的偶发误报怎么认、怎么重跑**、什么时候能重定基线、**时间线上的块不读工程、按值比较 + `.equatable()`**、**第十二节：订阅时钟的只许是名单里的小视图，停着才有意义的读 `PacedPlayhead`**、**第十三节：body 读了什么就只被什么叫醒，大视图少读、不驱动界面的存储 `@ObservationIgnored`、读不可观察的东西要自己找叫醒的来源**）、[预览性能 ratchet 方案](docs/plans/2026-09-24-preview-perf-ratchet.md)、[每个块都订阅着整个工程](docs/bugfixes/2026-09-24-timeline-blocks-observe-whole-project.md)、[播放时每一跳叫醒整个编辑器](docs/bugfixes/2026-09-25-playback-wakes-whole-editor.md)、[播放丝滑方案](docs/plans/2026-09-25-smooth-playback.md)、[点一下选中一段整个编辑器跟着重算](docs/bugfixes/2026-09-26-selection-wakes-whole-editor.md) |
| 主线程卡顿（播放中按键慢半拍）、心跳看门狗 `MainThreadWatchdog`、卡顿日志、冒烟结果里的 `stalls` | [主线程卡顿日志](docs/testing/main-thread-stalls.md)（默认开着、栈是超过阈值那一刻抓的一次快照、卡顿次数不进性能 ratchet 的账）、[预览性能 ratchet](docs/architecture/preview-perf-ratchet.md) |
| 任何界面文案、翻译、字符串表、应用内语言切换、**加一种界面语言（`<code>.lproj` + `AppLanguage` 一个 case，别处不改）**，新加 sheet / popover / 自建宿主视图 | [本地化](docs/architecture/localization.md)（第三节第 3 条：sheet / popover 不继承应用内语言；第五节：加一种语言）、[界面语言方案](docs/plans/2026-09-30-ui-languages.md)（先西班牙语、译文不审直接算正式、不标 Beta）、[sheet 全是英文](docs/bugfixes/2026-09-24-sheets-ignore-in-app-language.md)、[守卫不扫 LabeledContent](docs/bugfixes/2026-09-24-labeledcontent-missing-from-localization-guard.md) |
| AI 接口（MCP）：给 AI 的工具清单与说明、**剪辑风格（预设风格与用户存的，工具 recipes / save_recipe）**、**配旁白（add_voiceover：SrtFlow 自己的声音 Kokoro、没下载时 macOS 的声音）、`Sources/SrtFlowKokoro/` 这个模块、模型的下载与 R2 上的那一份**、`srtflow-mcp` 小程序、小程序与 App 的通道、AI 改时间线的规则、「看得见」（一轮开始时摆出剪辑页、每步定位）、这一轮 / 停止 / 撤销这一轮、需要用户点头的事、设置里的「连接 AI」、**AI 的手和眼**（`edit_clip` 的铺满 / 完整显示 / 裁切 / 位置大小、去黑边、对准主体、`look` 看、`listen` 听）、**AI 的眼睛（第 4 块：分镜头 `look shots`、一次看几个文件 `look files`、铺满跟拍 `follow`；第 5 块：扫画面里的字 `look text_scan`、按字取景 `focus=text`）**、**AI 够得着的现有功能**（后台模式、读文稿、整理文件、访达选中、推子关键帧、形状、复制、定格、音乐库、压缩 / 烧录 / 转字幕） | [AI 接口（MCP）](docs/architecture/ai-control-mcp.md)（**第一节第 6 条：总说明是一份目录，Claude Code 只读总说明和每个工具说明的前 2,048 字、Codex 要前 512 字自成一体，只用英文；往总说明里加东西先问是不是要 AI 主动做**；第四节 14–24 条逐个工具写着复用了哪条手动的路；读点名文件夹以外的文件都走 `AIWorkspace.confirmReading`；压缩 / 烧录排进现成的队列、条目自带设置、不替用户开跑；清单只有一份、两代协议都接、一个工具 = 一步撤销且每个改动工具包一层 `AIUndoGrouping.step`（别去关按事件自动开的组；要 await 的先 plan 再同步 apply）、不许弹模态框、只有删文件才问（别处的文件问一次、记住文件夹；撞名加编号；「连接」顺带放行客户端那层；工具不按个数卡、说明总长度有上限）、阻塞收发只在自己开的线程上；第四节 11–13 条：铺满是一扇窗映满画布、先裁切再摆放；29–31 条：镜头切点学 PySceneDetect、长视频走任务、跟拍只跟人且换镜头跳过去、裁切不能做关键帧所以只动摆放框中心，look 按预览的层序合成、每层调现成的那份，listen 读波形那一份、窗和均方桶对齐）、[预览自由变换](docs/architecture/preview-free-transform.md)（裁切和摆放的模型）、[阻塞的媒体读取](docs/architecture/blocking-media-reads.md)（Vision 的 perform 在 `MediaReadQueue.analysis` 上跑）、[波形与深度缩放](docs/architecture/audio-waveform.md)（均方和峰值同一遍读）、[AI 的改动撤一步全空了](docs/bugfixes/2026-09-27-ai-edits-share-one-undo-group.md)、[挂字幕落在 step 外面，之后撤一步全空](docs/bugfixes/2026-09-27-ai-undo-swallowed-by-subtitle-attach.md)（一次调用里所有登记都在同一个 step 里；异步落账各包一层）、[AI 翻译按旧的原文语言去翻](docs/bugfixes/2026-09-27-ai-translation-stale-source-language.md)（要人动手就走 `waiting_for_user` + 提示条）、[叫 AI 去面板里选语言](docs/bugfixes/2026-09-29-ai-told-to-pick-language-in-panel.md)（界面的报错叫人去点哪儿的，AI 那一路换成它能照做的话）、[婚礼工程之后的五处工具小毛病](docs/bugfixes/2026-09-29-mcp-tool-followups-from-wedding-session.md)（字面 `\n`、切工程只取消绑工程的转写、look 无效合成要报错、整批拒绝要说清、结果带工程名listen 和 cut_to_beat 的拍子不一致](docs/bugfixes/2026-09-29-beat-analysis-window-differs-between-listen-and-cut-to-beat.md)（鼓点按整首歌分析一次、各自取用）、[字幕带把幻灯片标签也框进去](docs/bugfixes/2026-09-29-text-scan-band-swallows-slide-labels.md)（字幕带只量底边同一条线的那一堆；选哪一堆见下下条）、[裁切量被幻灯片标题拉大](docs/bugfixes/2026-09-29-text-scan-crop-hint-stretched-by-slide-title.md)（字幕的上一行要每句都换才认；提示写明裁的是整条带、裁完抽帧看）、[贴底被切掉的字混进字幕行、字幕稀疏时选成幻灯片](docs/bugfixes/2026-09-29-text-scan-cutoff-text-and-sparse-subtitles.md)（贴着画面底边的薄片不算字幕行；字幕是够多的几堆里**最下面**的一堆，不是「不同的字最多」的那堆 —— 数量在字幕稀疏时不可靠）、[总说明和 edit_clip 的说明被截在 2,048 字](docs/bugfixes/2026-09-30-mcp-text-truncated-at-2048.md)（量模型真正读到的那一份；规矩按「主动 / 某个工具 / 某个结果」分三层放）、[MCP 方案](docs/plans/2026-09-27-mcp.md)、[配方卡中文稿](docs/plans/2026-09-28-mcp-recipes.md)（改套路先改它、再同步 App 资源里的英文卡）、[风格卡给竖屏的字号大了](docs/bugfixes/2026-09-29-recipe-sizes-too-big-on-vertical.md)（字号按画面高度算，卡里写明画幅） |
| **合成音效**（`Sources/SrtFlow/SoundEffects/`、`add_clips` 的 `sound_effect` / `hit_at`、`AISoundEffectRequest` / `AISoundEffectTool`）、改任何预设的声音、合成器的响度或落点 | [合成音效](docs/architecture/sound-effect-synth.md)（落点是合同、混响按峰值比例、两道电平、同参数同文件且改声音要 +1 version 并再给用户听、默认都短、写文件只经一处）、[音效方案](docs/plans/2026-09-30-sound-effects.md)（三轮试听怎么定的）、[AI 接口（MCP）](docs/architecture/ai-control-mcp.md) 第四节第 43 条、[阻塞的媒体读取](docs/architecture/blocking-media-reads.md) |
| fal.ai 生成（`Sources/SrtFlow/Fal/`、`generate_media`、设置里的 fal 一节、每日上限与花钱先问、Key 与钥匙串、模型表与价格、请求体对着接口定义快照验、`tools/list` 按 Key 列不列（`MCPProviders`）、配旁白的 fal 档与克隆（`AIFalVoice`）） | [fal.ai 生成](docs/architecture/fal-generation.md)（**只有 `FalClient` 碰 fal 地址；Key 只经 `FalKeyCache` 读；先 `decide` 后 `run`、决定和记账同一步；提示条上的问题不弹模态框、不管这一轮什么状态都摆出来；取消要在不继承取消的 Task 里发；配旁白同步、不许停下来问、额度不够退档；换预设先跑 `scripts/fal-models/refresh.sh`**）、[AI 接口（MCP）](docs/architecture/ai-control-mcp.md) 第四节 39、40 条、[第六块实施报告](docs/reports/2026-09-29-mcp-slice6-report.md)、[GUI 冒烟流程](docs/testing/gui-smoke-testing.md) 四之八（端到端冒烟：不要用 `security -T` 预置 Key、先 `open_folder`） |
| 真实窗口、系统权限、手势实测 | [GUI 冒烟流程](docs/testing/gui-smoke-testing.md) |

## 构建与检查入口

- 构建与打包的 Rosetta / arm64 要求、常用命令、打包和验收：
  [docs/build/build-and-packaging.md](docs/build/build-and-packaging.md)。
- 音频库素材的制备与上传（音乐：选曲 → 规格化 → manifest → R2；音效：手写目录 → 峰值归一 + 落点 → manifest → R2）：
  [docs/build/audio-library-pipeline.md](docs/build/audio-library-pipeline.md)。
- 本机配音模型（Kokoro）的整理与上传（钉版本的来源 → 整理 + 清单 → R2，密钥放仓库外）：
  [docs/build/voice-model-pipeline.md](docs/build/voice-model-pipeline.md)。脚本在 `scripts/voice-models/`，R2 签名只有 `scripts/r2.py` 一份，
  **不在 `check-all.sh` 里**。
  脚本在 `scripts/audio-library/`，**不在 `check-all.sh` 里**（它制备素材，不是检查）。
- 全部自动检查：`scripts/check-all.sh`。CI 在每个 PR 上运行同一入口：
  `.github/workflows/checks.yml`，按 `--shard N --of 5` 分到 5 台免费的 macOS runner 上并行跑，
  由一个叫 `check-all` 的汇总 job 给结论（分组、组数校验、汇总 job 为什么不能被跳过，见
  [构建与打包「CI」一节](docs/build/build-and-packaging.md)）。新加检查要放进某个 `shard`。
- 核心库：`swift run --arch arm64 SrtFlowCoreChecks`（含逐词高亮：词对到去完标点的字上、此刻亮哪个、跟着编辑走、按词切段、ASS 标签，`SubtitleWordChecks`）。
- 生成的字幕长什么样（去标点、断句、一行多长、显示时间、几段素材同时有字只留一条，用例是用户工程里真实转写出来的句子）：
  `SrtFlowCoreChecks` 的 `SubtitlePunctuationChecks` / `SubtitleSegmentationChecks` / `SubtitleSourceOverlapChecks`；
  藏起来的段不转写、「只用选中的片段」在 `scripts/check-project-file.sh`（`HiddenItems.swift`、`SubtitleSources.swift`）+ 接线扫描 `checks/project-file-wiring.sh`。
- 工程存盘与素材重链接、选择模型（点选互斥 / 框选混选）、轨道块标记：
  `scripts/check-project-file.sh`；这批合同**有没有被生产代码调用**的接线扫描（隐藏清单、调色 / 盖一块 / 形状 / 文字读 `rendered*`、
  字幕生成的可听快照等）单独成 `checks/project-file-wiring.sh`：秒级、不编译、进第 1 组，**搬代码 / 改名之后先在本地跑它**
  （原来接在上一个脚本末尾的编译后面，本地跑不到，[PR #84 首跑 CI](docs/bugfixes/2026-09-29-pr84-first-ci-run-wiring-guard-in-moved-code.md) 才红）。
- 播放头与悬停 peek 状态机，以及播放头的慢读法 `PacedPlayhead`（只跟「放置」、播放中不跟、停下追上一次、
  不认悬停），还有「回到开头」（Return / Home）只由 `goToStart` 请时间线滚回最左、普通 seek 不许，
  以及卸片之后晚到的时间回调不许把播放头写回旧位置（真播放器、ffmpeg 现做的带声音素材）：
  `scripts/check-player-clock.sh`。
- 不许同步问播放器要时间（`currentTime()`，会被播放器的锁堵住主线程）、AVKit 的 Now Playing 必须关着、电平条读时钟外推的
  `estimatedTime`：`checks/player-time-no-sync-read.sh`；外推的算术在 `scripts/check-player-clock.sh` 第 12 组。
- 音频引擎的等价自检（同一条时间线：引擎离线渲染 vs 纯 Swift 的 oracle 混音器（`checks/AudioEngine/Oracle.swift`：ffmpeg 解码 + 逐采样乘增益表），逐 10 ms 窗口比 RMS ≤ 0.15 dB、帧数正好、零欠载；电平表的槽、场景、变速）：
  `scripts/check-audio-engine.sh`（第 4 组，要 ffmpeg 造素材）。
- 主线程心跳看门狗（主线程没卡不误报、卡过阈值记时长 / context / 栈、日志文件、stop 之后不记）：
  `scripts/check-main-thread-watchdog.sh`；日志在哪、怎么读见 [主线程卡顿日志](docs/testing/main-thread-stalls.md)。
- 预览合成真取帧，以及素材缓存命中时合成逐帧一样、同一路径换了文件或原地改写过必须重开，
  还有往合成轨上接素材只从末尾接、合成完正好和时间线一样长（多一格视频合成就无效 → 黑屏），
  以及切片表按格子铺、首尾相接（接缝差 0.2 毫秒、画面比配乐早收 0.3 毫秒都不许空出一格），主轨接缝的零头那一格不黑：
  `scripts/check-preview-composition.sh`。
- 录屏产物画面轨盖到 T1（尾部不黑）：`scripts/check-screen-recording-writer.sh`。
- 上层视频轨动画段 fill + matte：`scripts/check-export-alpha-compositing.sh`。
- 入场/出场动画的两条管线对账（预览取帧 vs 真导出抽帧）：`scripts/check-clip-animation.sh`。
- 上层视频轨铺满 + 画面渐变的真产物（真跑导出再抽帧），以及上层轨藏起来的段不进成片：
  `scripts/check-video-fade.sh`。
- 检查器的 live 绑定只准接滑块和 scrub（离散控件没有结束信号，快照会挂着把
  下一次改动抹掉）：`checks/inspector-live-binding-wiring.sh`。
- 画面文字：渲染图与成片**逐点重合**（同一个渲染函数是这套东西的全部前提），
  以及动画的「模型给多少、成片就是多少」、预览上的可点范围、老虎机首帧 / 末帧就是起止值，
  还有主字体里没有的字（✨、汉字）用回退字体画（和直接用那款字体画的墨迹重合）：
  `scripts/check-text-render.sh`。
- 预览上的字幕和烧出来的一样大（预览那个视图离屏渲一张、照导出那条路真烧一帧比字的外框：几种字体、字体里没有的字按回退的那一款（Helvetica 里的中文本机走苹方、CI 没下载苹方就两边换冬青黑体；韩文）、默认样式的粗体、逐词高亮放大），以及回退到系统私有字体时换内置字体的规矩，还有字幕在预览和成片里摆的**位置**（底部 / 居中 / 顶部 × 一两行 × 英文 / 混排 × 五种字体，上下沿差 ≤ 3 px：libass 的行框用 win 量度、预览用 hhea）、字幕**阴影**真画出来的像素（中灰底上白字，预览和成片各量右下多出来的暗处：偏多少、最黑的一点有多黑，透明度写反、哪一边没画都会红），以及字幕字体清单的 cmap 体检（手造的坏 format 12 子表判不安全、装了圆体的机器上它不进清单）：`scripts/check-subtitle-burn-size.sh`；ASS 里点名字体和逐词高亮一起写在 `SrtFlowCoreChecks` 的 `SubtitleWordChecks`。
- `.contentShape` 不许写在 `.offset` / `.rotationEffect` / `.scaleEffect` 之后（几何效果只挪画面、
  不挪布局框，可点范围会留在原位）：`checks/hit-shape-before-offset.sh`。
- `PreferenceKey.reduce` 不许写成 `value = nextValue()`（兄弟节点的默认值会把量出来的尺寸盖成零）：
  `checks/preference-reduce-keeps-value.sh`。
- 滤镜调色：LUT 数学（强度那条等式）、层号规则，以及**预览与成片逐像素比对**
  （配方 ↔ CoreImage ↔ 真跑 ffmpeg）：`scripts/check-filters.sh`。
- 滤镜挂到播放器上这段接线（拍窗口数像素）：`scripts/check-filter-preview-attach.sh`。
- 盖一块（模糊 / 马赛克）在成片里真的盖了（真跑生产导出再抽帧：只改那一块、块外和基线一致、外接框就是那块、高斯剖面贴着理想的阶跃响应、马赛克格子边长对且从左上角起算、只在那一段时间里盖、形状压在它上面不被糊、调色在它前面、藏起来的不导出、不算总长）：`scripts/check-cover-export.sh`（`check-all.sh` 第 5 组）。
- 预览上的盖一块真的盖上了（生产的 `CoverHostView` 放进真窗口、拍屏数像素：块里糊成混色块外还是硬的、改动的行正好是块的上下沿、调色带上了、马赛克格线从块的左上角起算、两块同时盖、撤掉之后回到参照）：`scripts/check-cover-preview-attach.sh`。**要图形会话，故意不在 `check-all.sh` 里**，改 `VideoEditCoverPreview.swift` / `VideoEditCoverFilters.swift` 时按 [GUI 冒烟流程](docs/testing/gui-smoke-testing.md) 跑。
  **要图形会话，故意不在 `check-all.sh` 里**，改 `VideoEditFilterPreview.swift`
  时按 [GUI 冒烟流程](docs/testing/gui-smoke-testing.md) 跑。
- 声音渐入渐出、音量曲线与推子的真实包络（预览 = 引擎离线渲、导出 = 真跑 ffmpeg 两条管线），电平表（挂着表离线渲，
  对账轨道表 / 总表 / 红灯），以及过 0 dBFS 的混音过真峰值限幅器（没过顶逐采样原样、过顶一个采样不超上限、稳态正弦不削成方波、
  尖峰时刻不变、总长不变）、整段响度按 BS.1770 且和 ffmpeg 的 `ebur128` 一致、成片响度和混音一致（第 10 组）：`scripts/check-audio-fade.sh`（带看门狗：渲混音卡住
  4 分钟就判红，并说出卡在哪一组；CI 上第 7b 组「2 倍速曲线 · 导出」差 1–2 dB 偶发，认法见
  [推子与电平表](docs/architecture/audio-mixer.md)「已知的偶发」）。
- 波形数据（多级峰值、原始采样块）逐采样对账，以及**很多文件同时读**必须全部读完、
  不许把线程池堵死（看门狗判红）：`scripts/check-waveform.sh`。
- 成片的声音只有一条管线（导出图里不许出现声音滤镜，混音是预览那个音频引擎按同一份 `AudioEngineConfig`
  离线渲出来的）：`checks/export-audio-single-pipeline.sh`。
- 读采样的阻塞循环（`copyNextSampleBuffer`）不许写在 async 函数里（会占住 Swift 并发
  线程池的线程，文件一多整档 QoS 死锁）：`checks/blocking-media-reads.sh`。
- 生产导出帧率与分辨率（真跑导出：数帧、读成片尺寸 —— 只降不升、按短边、像素是方的）：
  `scripts/check-export-frame-rate.sh`；禁止写死帧率扫描：
  `checks/no-hardcoded-fps.sh`。
- 关键帧的缓动（每种曲线的值、linear 逐位一致、set / clipped / stretched 保曲线、存盘按需写键 + 老文件 + v27、切片按帧 / 线性一片不多 / 400 片上限）：
  `scripts/check-project-file.sh` 第 39 组；AI 的 `set_keyframes easing`（默认 easeInOut、词表对账、读回来带曲线）在 `scripts/check-mcp.sh`；缓动的缩放真合成
  （片数 = 帧数、四分之一处的面积按曲线）在 `scripts/check-preview-composition.sh`。
- 定格时间线变换（含在最后一帧里定格时不到一帧的右半不留）：`scripts/check-freeze-frame.sh`。
- 按钮提示与快捷键单一来源：`checks/instant-tooltip-wiring.sh`。
- 检查器里的菜单 Picker 不许锁死宽度（锁了会把整列撑宽、右边被裁）：`checks/inspector-fits-width.sh`。
- 字幕编辑期间全局快捷键让路（⌫ 不删正在编辑的 cue）：
  `checks/subtitle-editing-wiring.sh`。
- 界面文案在 en 原文表和每一张译文表都配齐（表按 `Resources/*.lproj/` 现场找，`InfoPlist.strings` 一并对账）、无重复键、占位符一致：
  `scripts/check-localization-coverage.sh`。
- 提示面板的真实落点（摆好之后不许自己变）：`scripts/check-instant-tooltip-panel.sh`。
  **要图形会话，故意不在 `check-all.sh` 里**（无图形会话会假红），改
  `InstantTooltip.swift` 时按 [GUI 冒烟流程](docs/testing/gui-smoke-testing.md) 跑。
- 时间线缩放的锚点（横向钉指针那一刻、工具栏钉播放头 / 视口正中、纵向按行认的那一处）：
  `scripts/check-timeline-zoom.sh`；接线（不许 hitTest 找滚动视图、唯一缩放入口、⌥ / ⌘↓⌘↑ 纵向）在
  `checks/timeline-drag-wiring.sh` 的缩放一节（`checks/timeline-drag-wiring/zoom.sh`）。
- 时间线吸附、框选命中与生产落点，以及点一下播放头落到哪（全局夹紧、点块不出这一块：`TimelineSeek`）：`scripts/check-timeline-snap.sh`；拖动/框选
  接线扫描：`checks/timeline-drag-wiring.sh`（拆在 `checks/timeline-drag-wiring/` 下的几节一起
  `source` 进来，含「拖动会话不进时间线的 @State」`drag-box.sh`）。
- **进程内 GUI 冒烟**（人在用这台机器时也能跑：不动鼠标、不抢前台，按步骤表点 / 拖 / 滚 / 按键，
  结果里带选择、各段位置和每个视图重算了几次）：`scripts/gui-smoke/in-process/run.sh <步骤.json> [工程拷贝]`。
  **要图形会话，不在 `check-all.sh` 里**；格式与坑见 [GUI 冒烟流程](docs/testing/gui-smoke-testing.md)「四之六」。
- **扮成 AI 客户端驱动测试版**（MCP 冒烟：起 App 包里的 `srtflow-mcp`，照 JSON 调用表发工具调用，`look` 的图存成 jpg）：
  `scripts/gui-smoke/mcp-client/client.py`。要装好的测试版、素材复制到 scratchpad，见 [GUI 冒烟流程](docs/testing/gui-smoke-testing.md)「四之七」。
- 跨 App 的文件拖放重放（自带拖源，Finder 不吃合成事件）：
  `scripts/gui-smoke/external-file-drag/replay.sh`。**要图形会话，故意不在
  `check-all.sh` 里**，按 [GUI 冒烟流程](docs/testing/gui-smoke-testing.md) 跑。
- SwiftUI 落点路由探针（每格一种 `.onDrop` 组合，回调全记日志；改时间线的落点结构
  之前先在这儿测）：`scripts/gui-smoke/drop-routing-probe/probe.sh`。同样要图形会话、
  不在 `check-all.sh` 里。
- 从 Finder 拖文件进轨道的落点（撞上就抬一轨、多文件接龙、隐藏轨跳过、落地后
  主轨仍按时间排序）：`scripts/check-media-import.sh`；接线扫描（含「整条时间线
  只许一个 `.onDrop`」）在 `checks/timeline-drag-wiring.sh` 里。
- AI 接口（MCP）：给 AI 的文字按客户端怎么读（总说明和每个工具说明 ≤ 2,048 字、前 512 字自成一体、目录里有每个工具名、只用英文，`CatalogTextChecks`）、小程序说的协议（老一代握手 / 新一代每个请求自带版本，真起小程序、假 App 接调用，几百 KB 的图原样穿过通道）、AI 改时间线的规则、客户端配置的增删、词表和 App 类型对账、打包把小程序装进 Helpers 且先签它，
  新东西默认放哪（点名的文件夹 → 工程的家 → 下载，没有「影片」；AI 改了没存过的工程马上存）、窗口只在一轮开始时摆到前面，
  以及 AI 的手和眼：铺满时窗的四角正好落在画布四角（各种比例 × 焦点）、去黑边、对准主体（真让 Vision 认一张图、框不许上下反）、
  look 的拼图和文字描述、listen 的电平 / 静音段 / 曲线，总说明里「不用外部工具改素材」那一句；现有功能铺满的纯值规则
  （剪辑的其余设置、轨道推子、关键帧、形状、复制一份、音乐库的署名句、压缩 / 烧录的参数与起名），以及压缩 / 烧录的条目
  自带设置、不替用户开跑（扫描）；配音的音量（峰值超过满幅的一句真写成 .m4a 读回来不削波、两种声音只经一处写文件）；什么时候问（只有删文件和读别处的文件会问、读过的文件夹记住、撞名加编号，扫描）、记住哪里、
  「连接」时写进 Claude Code / Codex 的放行配置、工具清单总长度的上限；第 4 块的镜头切点与翻页、跟拍（窗的两边落在画布两边、
  只跟人、换镜头跳过去）；第 5 块的剪辑风格（配方卡的格式、合并与查找、存一套 / 删一套，**卡里提到的工具名、参数名、选项值都存在**，卡里的字号写明画幅、9:16 的上限用生产的排版真排得下）、
  set_text 补的零件（字距、动画时长、强调、数字滚动）和实心形状、add_voiceover（挑声音、语速表、标记 → 词、配音的字幕不覆盖已有的）、
  字幕的 style（只改工程自己的样式、给了位置收掉拖框的布局、逐词高亮的开关和倍数、烧录用不了的字体报错、烧录一批自带的样式）、
  扫画面里的字（字幕带、固定的字、满屏的字互不混，字幕带的框不被贴在字幕上面的幻灯片标题拉大、被画面底边切掉的字不算字幕行、字幕稀疏而幻灯片字多时仍选字幕，没人字多按字对准）；**合成音效**（16 个预设的结构自检：峰值 / 响度 / 落点 / 末尾 / 确定性 / 同参数同文件名 / 频谱走向、`sound_effect` 条目怎么读、落点怎么算开头、词表对账；扫描：写文件只经 `AIAudioFileWriter`、渲染在 `MediaReadQueue.analysis` 上）：
  `scripts/check-mcp.sh`。
- fal.ai 生成（第 6 块）：`scripts/check-fal.sh`（`check-all` 第 2 组，不碰网络、不碰钥匙串）：模型表与估价、花钱把关、按天记账、**每个登记端点的请求体对着 fal 公开的接口定义快照验**
  （`checks/Fal/schemas/`）、样例输出与词时间、`FalClient` 用假 URLSession 走全流程（照 fal 给的地址、每种失败换的话、Task 取消 / 超时都替 fal 取消、下载收尾、没 Key 不发请求）、Key 的整理；
  `checks/fal-wiring.sh`（扫描守卫，第 1 组）：先问后花、不弹模态框、HTTP 只经 `FalClient`、Key 只经一处读、清单跟着 Key 走、路由不进撤销分组；
  `scripts/check-mcp.sh` 的 `ProviderChecks` / `FalVoiceChecks`：清单按 Key 列不列（真起小程序、老一代收 `list_changed` 新一代不收）、小文件、挑音色、词时间、WAV；
  **本机手动、不在 `check-all` 里**：`scripts/check-fal-keychain.sh`（真钥匙串）、`scripts/fal-models/refresh.sh`（联网：重下接口定义快照、按上架日期列各类最新的、核对价格）、
  `scripts/gui-smoke/fal/`（真 App + 本机假 fal 的端到端冒烟，见 [GUI 冒烟流程](docs/testing/gui-smoke-testing.md) 四之八）。
- 时间线复制 / 剪切 / 粘贴：拿什么、换新身份（除了 id 每个字段照抄）、粘到哪（撞上往上抬、几组保住上下关系、
  声音各找一条、链接组换新号、文字 / 滤镜 / 字幕句各自的行规矩），外加分割不丢字段、分割后链接组一对还是一对：
  `scripts/check-timeline-clipboard.sh`；接线（编辑菜单三项、右键菜单、落点鼠标优先含 Finder 文件、标尺不算轨道、
  剪贴板只有一套且不写纯文本）：`checks/timeline-clipboard-wiring.sh`。
- 静帧真实编码与边际性能：`scripts/check-still-clip-encode.sh`。
- 翻译配对预检与接线：`scripts/check-translation-preflight.sh`。
- 音频库清单：解析的宽容边界（不认识的字段忍、单条坏数据跳过、**版本号更高整份
  拒绝**）与双语搜索（中英都能命中同一个 tag、多词是「与」），以及音效清单的 `title_zh` / `hit` / `owned` 不署名 / 按中文标题搜：
  `scripts/check-audio-library.sh`。
- 音效目录（`scripts/audio-library/sfx-catalog.tsv`：id 连号永不改、来源唯一、中英标题、tag 都在词表里、来源方）：
  `checks/sfx-catalog.sh`。
- 压缩 / 烧录记住的设置和字幕样式在队列创建时读回来（不挂在页面的 `onAppear` 上），剪辑页和 AI 的字幕样式都经
  `subtitleStyle(appWide:)`（工程自己的样式优先）：`checks/encode-settings-memory.sh`。
- 构建日志不得被吞：`checks/no-swallowed-build-output.sh`。
- 代码文件的行数上限（超过 600 行就红，老文件只许降不许涨，变短了用 `--update` 改小基线）：
  `checks/source-file-size.sh`。
- shell 脚本里裸 `$VAR` 不许紧跟中文 / 全角标点（bash 会把首字节吃进变量名，
  `set -u` 下当场退出）：`checks/shell-var-boundary.sh`。
- 开着 pipefail 的 shell 脚本里，管道末端不许用 `grep -q`（命中就退出，上游吃 SIGPIPE，
  整条管道判失败 → 时灵时不灵的假红；查变量用 `<<<`，查管道用 `grep -c … >/dev/null`）：
  `checks/shell-pipe-grep-q.sh`。
- 每个 sheet / popover 的内容、每个自建的 `NSHostingView` 都必须套 `.appLanguage()`（SwiftUI
  不把应用内语言带进 sheet / popover）：`checks/presented-views-app-language.sh`。
- 代码里每个 `UTType(exportedAs:)` 都必须在 `packaging/Info.plist` 里声明（没声明的
  类型系统认不出，拖放会被静默拒绝）：`checks/exported-types-declared.sh`。
- 预览性能 ratchet（起真 App 按固定场景数「做了多少件活」，只许降不许涨）：
  `scripts/check-preview-perf.sh`。**CI 独有**：第 1 组里单独一步，要图形会话，**不在
  `check-all.sh` 里**；check-all 只跑它的比对规则自检（`--self-test`）。偶尔会误报退步
  （CI 虚拟机上的已知干扰），认法和处理见架构文档「已知的偶发误报」。每个视图、
  `updateNSView`、Canvas 都接了计数：`checks/preview-perf-wiring.sh`；新写视图漏了计数，
  跑 `checks/preview-perf-wiring.sh --fix` 自动补上。同一个守卫还钉着**时间线上的块不许
  读工程的属性、必须 `Equatable` 且构造处套 `.equatable()`**，以及**订阅播放器时钟的只许是名单里跟着播放头动的
  小视图**（根视图、时间线本体、检查器、素材库、字幕列表都持有不订阅）。
- 本文件的索引必须是全的：`docs/` 下每一份文档都要能从这里找到，且没有死链 ——
  `checks/docs-index-drift.sh`。只读 AGENTS.md 的代理打不开索引外的文档，
  所以漏一行等于那份文档不存在。

## 规划与实施报告索引

- [原生录屏方案](docs/plans/2026-08-06-native-screen-recording.md) — 产品目标与阶段方案；
  当前状态以实施报告为准。
- [原生字幕生成方案](docs/plans/2026-08-06-native-subtitle-generation.md) — SpeechAnalyzer、
  Translation、缓存与 macOS 15/26 分层。
- [定格方案](docs/plans/2026-08-08-freeze-frame.md) — 产品参数、提交模型、分辨率政策与
  已知代价。
- [转场库扩充](docs/plans/2026-08-23-transition-library.md) — 推移/擦除 8 种新转场的
  选型约束（预览斜坡能精确表达才收）与悬停预览选择器。
- [画面段的入场/出场动画](docs/plans/2026-09-18-clip-animation.md) — 产品决策（效果清单、
  吞掉画面渐变、不露边口径）、选型约束与分刀。
- [音频库（音乐 / 音效）](docs/plans/2026-09-22-audio-library.md) — 两个来源（R2 按需下载
  + 本地导入）、**只收 CC-BY / CC0 的授权政策**（SA 会传染给用户成片）、manifest 数据
  契约、试听流播与 ducking、素材筛选管线与分刀。
- [从 Finder 拖文件进轨道](docs/plans/2026-09-22-media-file-drop.md) — 拖到哪就落到哪、那儿占着就**往上抬一轨**、多文件首尾相接、类型不匹配横向照用纵向退默认轨，以及 ⌘V 粘贴文件；
  与 `addMedia`（没有落点的那条老路）的分工。
- [声音编辑：Logic 式波形、深度缩放、音量曲线、推子与电平表](docs/plans/2026-09-23-audio-mixing.md) —
  用户授权「按体验最丝滑的方式定」之后拍的全部板（曲线属于段、推子属于轨、常显贴线操作、
  总表放标尺行、M/S 这轮不做）及理由，外加三个探针的实测地基（`aeval` 必须在 `adelay`
  之前、Canvas 只画 `clipBoundingRect`、音频 tap 看不到音量且不能每次换 mix 都新建）。
- [导出面板改版：三行 + 高级](docs/plans/2026-09-24-export-panel.md) — 标题 / 导出至 / 分辨率摆在外面、其余收进「高级」，分辨率只降不升按短边、不再弹保存面板、撞名先提示再确认、记住设置加「恢复默认」；逐条拍过的板和理由。
- [插进两条轨之间 + 整条轨换位置](docs/plans/2026-09-24-track-insert-and-reorder.md) — 拖素材块 / Finder 文件 /
  音频库素材在缝上停 0.2 秒、缝拉开成 28pt 的窄缝再落进新轨（主轨下面不开缝、原轨只剩这一段时紧挨的两条缝不开）；
  按住轨道头拖整条轨换位置（学 Logic，调行高挪到下边缘，其余轨实时滑开）；逐条拍过的板和理由。
- [声音场景 + 成片声音改从预览混音读](docs/plans/2026-09-24-sound-scenes.md) — 选中有声音的段时给它套
  「喇叭 / 室内 / 室外」九个场景（海边不做：没有海浪声就和室外一样）、2–3 个通俗滑杆、余音越过段尾、效果排在段增益之后；
  先把成片的声音改成离线读预览那份混音（用户：「两遍效率很低」），之后声音功能都只做一遍。
- [预览性能 ratchet 方案](docs/plans/2026-09-24-preview-perf-ratchet.md) — 为什么数「活」不数 CPU
  指令（托管 runner 读不到计数器、CPU 时间差两倍的探针实测）、不挂自托管 runner、不许拿画质换数字、
  只许降不许涨（要加开销先在别处省回来）等拍过的板。
- [播放丝滑：播放头的每一跳只叫醒跟着它动的东西](docs/plans/2026-09-25-smooth-playback.md) — 用户说播放卡、
  授权「按体验丝滑的方式来优化」之后拍的板：左栏播放中冻住、停稳刷一次、不认悬停、点卡片作用在显示的那条缝；
  检查器播放中不跟、停下追上；工具栏按钮照样实时；字幕列表只在换句时重算；不拿 CPU 数字验收。
- [隐藏扩到所有块、回到开头、对齐线整套、字幕拆成两条独立轨](docs/plans/2026-09-26-hide-guides-independent-subtitles.md) —
  2026-09-26 一个 PR 里的五件事拍过的板；字幕独立轨那部分最细：译文有自己的 ID 和来源表、「过期」现算、
  两条轨画面上默认叠成一块（`translationLayout` 为 nil）、拖一条就分开、预览和烧录读同一份按时间切好的块、
  两个重译按钮各自动哪些句子。
- [时间线上的复制 / 剪切 / 粘贴 + 缩放以鼠标为中心 + 纵向缩放](docs/plans/2026-09-26-timeline-clipboard-and-zoom.md) —
  2026-09-26 用户逐条拍的板（撞上了照拖文件往上抬一轨、单独的纵向缩放用 ⌥ 捏合、只动视频 / 音频轨、
  纵向缩放时全部统一成一样高、工具栏缩放钉播放头）、讨论时列的默认做法，以及我定的实现细节（Z1–Z7、C1–C9）。
- [生成的字幕：去标点、按主流规范断句、同时有字只留一条、藏起来的不转写](docs/plans/2026-09-26-subtitle-generation-style.md) —
  用户看着南极工程提的四件事（重叠、藏起来的还在生成、字幕不该有标点、长句拆开）、先查清的事实（重叠两个来源、翻译是一条一条送的）、
  调研（Premiere / Resolve / FCP / 剪映 / Descript 怎么选声音和处理同时说话；Netflix 英文与简体中文、BBC 的数字）、
  逐条拍的板（跟随素材「先不用」、双语顺序「不改」）和我定的实现细节。
- [让 AI 调用 SrtFlow 剪视频：MCP 方案](docs/plans/2026-09-27-mcp.md) — PR #81 已合并（2026-09-29，main 40a16a5）：第一到第四块、第五块的 ①–④ 和扫画面里的字做完，随后模糊 / 马赛克块（PR #84）和第 6 块 fal.ai 生成（PR #85）也合进了 main（真实状态看实施报告）。2026-09-27 访谈拍的 28 条板 + 实测后补的 4 条（AI 改了没存过的工程自动存、默认位置不要「影片」没给文件夹放「下载」、第 31 条 AI 不靠外部工具——裁切 / 看 / 听做成 SrtFlow 自己的工具、第 32 条窗口一轮只摆一次），以及 2026-09-28 讨论工具上限时补的 4 条（第 33 条不按个数卡、守三条；第 34 条只有删文件才问、别处的文件问一次记住文件夹；第 35 条「连接」顺带放行客户端的权限；第 36 条 SkyStudio 的 MCP 以后另做、生成类工具提供方可换），和同一天讨论第 5 块拍的板（第 37–56 条：HyperFrames 不装、学它的长处自己做；逐词高亮字幕；剪辑风格 AI 自己挑、不做斜杠命令、中文叫「剪辑风格」不叫「套路」；配方卡中文稿；自存套路；配音三档 fal > 本机开源模型 > macOS；本机模型用 CoreML 不用 MLX、听完样音选 Kokoro、八个角色的音色、模型放我们的 R2；克隆放第 6 块走 fal；五刀的顺序；AI 改字幕样式只改当前工程、第 ④ 刀之后插「扫画面里的字」和模糊 / 马赛克块），以及 2026-09-29 第 6 块动工时追加的两条（第 57 条：视频只用 `minimax/h3-max/`、加音乐音效、预设只用最新的模型；第 58 条：花钱超了额度在提示条上问、配旁白同步不问、额度不够退档）：
  第一期 Claude + Codex（ChatGPT 聊天框要隧道、用 Codex 代替）、除录屏外全部功能、默认看得见（每步定位高亮）、
  ⌘Z + 撤销这一轮、只有动硬盘才问（后来收成只有删文件才问）、本机 Vision 识别画面、按文字剪 / 删静音 / 踩点、剪辑套路（MCP Prompts）、
  fal.ai 生成（每日上限）；架构（`srtflow-mcp` 只传话、干活的只有 App 本体、协议自己写不引 SDK）、六块分块与两个真实验收任务。
- [剪辑风格：五种预设风格（中文稿）](docs/plans/2026-09-28-mcp-recipes.md) — MCP 第 5 块的剪辑风格内容：怎么用（AI 自己挑、一句话告诉用户、用户的话优先）、
  所有剪辑风格共用的规矩（先摸清素材、先问平台、9:16 安全区、字和声音的口径、不编造、导出前自检）、带货 / 课程推广、电影开头、科幻、纪录片、
  日常 vlog 五张卡（画幅、时长、按秒的结构、镜头、转场、动画、滤镜、字体、字幕、配乐、配音、自检）、配音音色的角色表、要补的零件、给 App 用的 .md 格式。
- [导出真峰值限幅 + 响度报告，关键帧缓动](docs/plans/2026-09-30-export-limiter-and-easing.md) — 2026-09-30 用户拍板「先做 1 和 2」：
  写 f32 之前把硬削换成流式真峰值限幅器（−1 dBFS、前瞻 5 ms、释放 80 ms、总长不变）+ BS.1770 整段响度只报不归一（面板一行、`get_job` 四个字段）；
  关键帧加 `easing`（linear / easeIn / easeOut / easeInOut，AI 默认 ease_in_out、手打默认线性）、预览按帧加密切片；检查器曲线选择器单独一个小 PR；
  然后出 Beta 0.18.5 让用户真剪。
- [音效：合成器（给 AI）+ 录音素材库（给用户）](docs/plans/2026-09-30-sound-effects.md) — 2026-09-30 用户拍的板：合成器先在 scratchpad 渲样音试听、点头才写产品代码；
  AI 先搜素材库、没有再合成、真实声音才走 fal；63 个 SouthPole 录音全收进 R2 素材库（默认不随 App 带）、授权加「自有 / 已授权」一类；
  三个 PR 的分刀、`hit_at` 落点、原型里学到的（Freeverb 湿声按干声峰值比例混）、决策门。
- [预览和成片的声音：自己的音频引擎（播放 / seek 无感）](docs/plans/2026-10-01-audio-engine.md) — 2026-10-01 用户拍板：大工程播放中点时间线等 1–1.5 秒、
  按空格播放头 0.5 秒才动，压力测试量到 AVPlayer 的合成「每条音轨 40 ms、串行、参数无效」是固有开销；自己做音频引擎
  （AVAudioEngine 做图 / 设备 / 求和，自己写按游标取样 + 增益 / 渐变 / 曲线 / 推子 / 场景 / 电平的渲染核心，每轨后台解码预读、
  **不缓存**，22 轨 seek 9 ms）、成片同步切到引擎离线渲染、视频留在 AVPlayer 只做优化媒体；全部数字、架构、时钟对齐怎么验、
  每个功能怎么搬、三刀、风险；用户看过再动代码。
- [界面语言：加西班牙语、法语、土耳其语，按系统自动选](docs/plans/2026-09-30-ui-languages.md) — 2026-09-30 用户定：「按系统自动选」本来就有（`.system` + 包里的 `.lproj`）；
  先一个 PR 把枚举和守卫改成任意多种语言，再先做西班牙语一种在真窗口看排版、之后定法语 / 土耳其语；泛化的 `es` / `fr` / `tr`；
  译文由 AI 出、**用户不做审核、直接算正式、不标 Beta**；复数和小数点先照英文。风险：法 / 西比英文长两到三成而检查器是窄栏、每个 PR 从此要给每种语言译文。
- [AI 接口（MCP）第一块实施报告](docs/reports/2026-09-27-mcp-slice1-report.md) — 23 个工具做到了哪、CI 与端到端实测的证据、测试版怎么出（`scripts/build-beta-app.sh`）、过程中修掉的事（撤销分组、提示条位置、文字折断、翻译语言与下载引导、自动存盘与默认位置）、还差什么（第二块起的功能、Claude 桌面版 / Codex 要用户点「连接」）。
- [AI 接口（MCP）第二块实施报告](docs/reports/2026-09-27-mcp-slice2-report.md) — 第二块起手「AI 的手和眼」（方案第 31 条）：`edit_clip` 的画面放法、去黑边、对准主体、`look`、`listen`、总说明里不用外部工具那一句，窗口一轮只摆一次（第 32 条）；然后现有功能铺满（后台模式、读文稿、整理文件、访达选中、剪辑的其余设置、推子关键帧、形状、复制、定格、音乐库、压缩烧录转换，工具 23 → 37 个）；每一刀的 CI、本机自检、测试版冒烟的证据，过程中撞上的事（三个老 bug），还差什么。
- [AI 接口（MCP）第三块实施报告](docs/reports/2026-09-28-mcp-slice3-report.md) — 分析数据 + 智能剪：`transcribe`（词级时间，和生成字幕同一套 `TranscriptHarvester`）、`listen beats=true`（鼓点）、`cut_speech`（按文字剪、删停顿、口头禅、说重了）、`cut_to_beat`（音乐踩点），工具 37 → 40 个（到预算）；CI 与测试版冒烟的证据、撞上的事（切开之后链接成对、new_audio 接在 A1 后面两个老 bug），还差什么（音频库没有鼓点清楚的音乐、转写要 macOS 26）。
- [AI 接口（MCP）第四块实施报告](docs/reports/2026-09-28-mcp-slice4-report.md) — 本机识别画面：`look shots=true` 分镜头（切点学 PySceneDetect、整个文件扫一遍缓存、长视频走任务）、`look files` 一次看 24 个文件、`edit_clip fit=fill` 跟着人走（位置关键帧、换镜头跳过去）；解码速度和切点的探针实测、测试版冒烟（素材A 47 个镜头、14.6 分钟的课 130 个镜头）、跟拍第一版乱晃怎么改的、还差什么。
- [AI 接口（MCP）第五块实施报告（进行中）](docs/reports/2026-09-28-mcp-slice5-report.md) — 剪辑风格 + 配音 + 逐词高亮字幕：第 ① 刀剪辑风格与零件（recipes / save_recipe、实心形状 v24、set_text 补参数）、第 ② 刀 macOS 配音（add_voiceover，词的标记只从代理方法来、语速按实测表换）、第 ③ 刀 Kokoro 与 Qwen3-TTS 的 CoreML 探针（M1 上 Kokoro 实时 10 倍、Qwen3 实时 0.2 倍、段尾逗号让 Kokoro 冒杂音）、用户选 Kokoro 之后接进 App（模块、R2、八个角色、按字 / 词的时间）、用户试用撞上的爆音、**⑤ 验收实剪第一轮**（AI 剪了两条，撞出的十几件事逐条怎么处理的、哪些等用户听、哪些功能等拍板），还差什么（第 ④ 刀起的顺序见方案第 54–56 条）。
- [AI 接口（MCP）第六块实施报告](docs/reports/2026-09-29-mcp-slice6-report.md) — fal.ai 生成：用户定「视频只用 minimax/h3-max/、加音乐音效、只用最新的模型」之后的模型表、Key（钥匙串）、每日上限与提示条上先问、`generate_media`、清单按 Key 列不列、配旁白的 fal 档与克隆；证据（373 + 1132 项、反向验证、端到端冒烟）、撞上的事（取消发不出去、钥匙串授权框、冒烟把文件放进了下载文件夹）、没对真 fal 验过的、等用户拍板的（钥匙串授权框取舍、默认模型）。
- [原生录屏实施报告](docs/reports/2026-08-06-native-screen-recording-implementation-report.md) —
  Phase 0–5 的真实进度、实测证据、偏差和未完成项。

## 架构与长期约束索引

- [写代码的规范](docs/architecture/coding-standards.md) — 模块化的六条（一个文件一件事、抽有名字的顶层类型、
  别开只有 extension 的文件、纯计算和副作用分开、同一规则只有一处实现、函数别太长），单文件目标 400 / 上限 600
  行与老文件只许降的基线、审查清单。
- [AI 接口（MCP）](docs/architecture/ai-control-mcp.md) — 三段结构（客户端 → `srtflow-mcp` → App，活只在 App 里做）、工具清单只有一份且小程序给、不按个数卡守三条（不许两个长得像、只读和写文件不混、说明总长度有上限）、选项词表抄一份就要对账、两代协议（老的 initialize / 新的 `_meta` + `server/discover`）、通道（按 bundle id 分 socket、一次调用一条连接、不抢别人的 socket、阻塞收发只在自己的线程上）、工具在 App 里的十三条规矩（一个工具 = 一步撤销、复用手动操作的规则、排队、看得见但不抢键盘且一轮只摆一次窗口、不许弹模态框、只有删文件才问（读别处的文件问一次、记住文件夹；撞名加编号）、长任务回任务号、AI 看不见就替它量、短 id 与 V1/A1 轨道名、做出来的文件放哪、画面怎么放（铺满 = 窗映满画布）、look 看、listen 听，第 4 块的分镜头、一次看几个文件、铺满跟拍，第 5 块的剪辑风格（AI 自己挑、内置卡在资源里不用 Bundle.module、用户的存 Application Support、卡里的名字必须存在）与配方卡要用的零件、配旁白（按角色挑声音、词的标记只从代理方法来、语速按实测表换、字幕走生成字幕那一套），SrtFlow 自己的声音（本机的 Kokoro：模块从 speech-swift 搬来改过、模型从我们的 R2 下载并核校验值、按字切 token 拿到每个字的时刻、在第一段安静处切掉尾巴杂音））、总说明里「只用 SrtFlow 的工具」、这一轮 / 停止 / 撤销这一轮、「连接 AI」三个客户端各用什么办法（连上顺带放行工具）、人工回归清单。
- [音频引擎](docs/architecture/audio-engine.md) — 时间线的声音只有这一份：预览实时播、成片离线渲（`Sources/SrtFlow/AudioEngine/`；2026-10-01 PR3b 起 AVPlayer 那条声音路删了，播放器的合成里只有画面）：配置是从时间线算出来的纯值（自己排序、展开转场；增益表 `AudioGainTable.swift`）、播放头只是几个数（锚点）、渲染块实时安全、喂样在普通线程、一段一条流、不缓存、离线和实时同一张图；声音是主时钟、视频 `setRate` 钉到引擎；配乐比画面长时 builder 垫黑底铺到总长；电平表是无锁槽；引擎的时钟只从渲染块的时间戳来（声卡 44.1 kHz 的采样时间不能拿来算 48 kHz 的位置）；自检对着纯 Swift 的 oracle 混音器比。
- [fal.ai 生成](docs/architecture/fal-generation.md) — Key（钥匙串：只读属性不弹框、读密钥每个新签名弹一次、`.silent` / `.interactive` 两档、`FalKeyCache` 一次运行最多弹一次、别改成 `LAContext`）、每日上限（只设每天的、额度内不问、超了 / 价格不明先在提示条上问、决定和记账同一步、没做出来的退回）、模型表（2026-09-29 用户定：视频只用 `minimax/h3-max/`、其余各类当前最新的；挑法、价格、更新办法）、请求体对着接口定义快照验、队列接口（照 fal 给的地址、取消要在 detached Task 里发）、`generate_media`（任务、成品放哪、不改工程）、清单跟着 Key 走（`mcp-providers.json`、`list_changed`、缓存一分钟）、配旁白三档与克隆、已知不足（真 Key 第一次要对的六条）、回归与人工清单。
- [合成音效](docs/architecture/sound-effect-synth.md) — SrtFlow 自己合成的 16 个剪辑动效音（AI 用 `add_clips` 的 `sound_effect`）：落点 `hit_at` 是合同（自检钉 ±25 ms）、混响按干声峰值比例混、峰值 −1 dBFS + K 加权 ≤ −9 LUFS、同参数同种子同文件（改声音要 +1 version 并再给用户听）、默认都短、写文件只经 `AIAudioFileWriter`、渲染在 `MediaReadQueue.analysis`；riser / downlifter 照 ElevenLabs 参照量出来的形状做。
- [时间线缩放](docs/architecture/timeline-pinch-zoom.md) — local NSEvent monitor 与失败方案、**锚点**（捏合钉指针底下那一刻、工具栏钉播放头，滚动视图只从 `TimelineScrollGeometry` 拿、`keepAnchored` 同一拍挪 + 下一轮补挪）、**纵向缩放**（⌥ 捏合 / ⌥ + Ctrl + 滚轮 / ⌘↓ ⌘↑，视频和音频轨统一成一个高度、细行不变、按行认锚点）、人工回归清单。
- [时间线上的复制 / 剪切 / 粘贴](docs/architecture/timeline-clipboard.md) — 能拷什么（标记、转场跟着段走）、入口（编辑菜单在响应链末端、右键菜单是函数不是视图）、系统剪贴板一套自己的类型且不写纯文本（滤镜那套并进来了）、落点鼠标优先否则播放头（右键菜单用右键按下的那一处）、换新身份走编码往返、各类落到哪（剪辑整组同轨、撞上往上抬、画面组上下关系不变；文字 / 滤镜往上找空的；字幕句按指着的轨）、粘完选中且一步撤销、剪切 = 拷贝 + ⌫、人工回归清单。
- [工程文件与素材重链接](docs/architecture/video-edit-project-file.md) — 格式（版本表到 v28）、定位、脏标记与自动保存。
- [时间线拖动手势](docs/architecture/timeline-drag-gestures.md) — 坐标系、刷新、吸附、唯一落点算法，
  **对齐线**（§4：对齐点含字幕 cue / 标记 / 藏起来的段、多选只看整组外沿、磁吸也亮线、裁切也吸按 FCP、吸附关了线也不亮），
  **拖动 / 拉框的会话不进时间线的 `@State`**（§0b：`TimelineDragBox` 持有不订阅、块只 `onReceive`
  自己那份、覆盖层唯一订阅者），
  框选（相交即选中、混选与「预览最多一套框」、整组一起移动），以及命中区必须盖在填满视口
  之后、点非素材处移播放头、扫帧 peek 的唯一所有者、**整条时间线只许一个拖放落点**（§5e-2），
  插入缝（停 0.2 秒拉开、行的位置一份纯值、纵向按指针判，§5h）、整条轨换位（§5i）、文字块上下换行（§5j）、
  框选框滤镜 / ⌘A 全选 / ⌘⇧A 取消（§3.5b）与多段一起裁（§3.6）。
- [预览自由变换](docs/architecture/preview-free-transform.md) — `ClipPlacement` 与预览/导出同账。
- [关键帧动画](docs/architecture/keyframe-animation.md) — 源时间锚定、切片与 fill + matte。
- [工程帧率](docs/architecture/project-frame-rate.md) — 唯一事实来源、容差空间与回归矩阵。
- [声音：音量与渐入渐出](docs/architecture/audio-fades.md) — 唯一夹紧点、转场仲裁、dB 换算、只换增益的快路径（引擎 `updateGains`）、每段增益表从段起点起就有确定的值。
- [声音场景](docs/architecture/sound-scenes.md) — 九个场景的模型与 v20、效果跑在引擎的渲染块里（预览和成片同一份；效果在段增益之后、推子之前）、每段一条效果链各自散余音（段尾之后喂零，不用载体）、加 / 去掉场景重开流、seek 复位、不载入出厂预设、喇叭类先削波后限带、响度补偿用同一串处理量（渲染前记输入）、回归与人工清单。
- [成片的声音](docs/architecture/export-audio-mixdown.md) — 成片的声音就是预览那份混音，2026-10-01 起由同一个音频引擎离线渲出来（之前是 AVFoundation 读合成；导出图里不许有声音滤镜）、读用户那一份状态（展开只许一次）、正好画面那么长、f32 中间文件、`MediaReadQueue.export`、和以前的成片比变了什么（单声道响 3 dB、变速换成预览的算法）。
- [音量曲线](docs/architecture/audio-volume-curve.md) — 曲线属于段（dB、锚源时间、有点时取代 `volume`）、编辑动作本身不改声音、两条管线同一张折线表、导出 `aeval` 平衡树的六条实测约束（放在 `adelay` 之前并减掉首帧定格、最右叶子必须是常数、全精度数字、超大图走文件）。
- [波形与深度缩放](docs/architecture/audio-waveform.md) — 一个文件读一次的三层精度（多级峰值 / 按需原始采样块 / 顶替）、粗级是 min/max 不是平均、画「听到的声音」且爆音涂红、**Canvas 只画 `clipBoundingRect`**（超宽内容的实测地基）。
- [推子与电平表](docs/architecture/audio-mixer.md) — 三级增益一条账（段 × 渐变 × 轨道推子 × 总推子，配置里分开记、渲染块按同一个顺序乘）、只动推子走快路径；电平表：峰值从渲染块来（无锁槽）、总表从混音器出口来、槽按键登记、界面每拍取走、读播放头不问播放器；tap 那条路的七条约束 2026-10-01 PR3b 起退役（案例还在）。
- [画面渐入渐出](docs/architecture/video-fades.md) — 渐变露出的是下一层、alpha 斜坡两条管线同账、与声音共用的夹紧规则。
- [主轨转场：借余料与定格补足](docs/architecture/transition-handles.md) — 不挪用户片段、三种几何与容量、余料不够用首尾帧定格补足（2026-09-23 拍板）、定格字段只在渲染副本里且只许展开函数写、两条管线怎么做定格。
- [画面段的入场 / 出场动画](docs/architecture/clip-animation.md) — 五种效果都落在三种斜坡上、效果与画面渐变共用一个槽（老工程零迁移）、铺满画布不露边的补偿、逐帧效果走预渲染的代价。
- [视频轨对等化](docs/architecture/video-tracks.md) — 取消画中画、一轨一色、⌥ 点击穿透、轨道头这一列的动作（按住拖 = 整条轨换位置、拖下边缘 = 调行高），以及尚未对齐的两项。
- [用户文本文件的编码](docs/architecture/text-file-encoding.md) — 字幕、讲稿这类用户给的文本文件，编码识别只有 SrtFlowCore 的 `TextDecoding` 一处：BOM → 严格 UTF-8 → 像 UTF-16 才 UTF-16 → GBK；为什么 UTF-16 不能无条件排在 GBK 前面。
- [画面文字](docs/architecture/text-overlays.md) — 唯一的绘制入口、1080p 基准、版面框即定位框、包络位图、把手的三种数学、九种动画与「只逐帧渲动画段」、数字元件（等宽自己排，苹方没实现字体特性）、数字的等待、**老虎机位数不同的两头**（不存在的那一位滚成空白收掉、居中和右对齐右边不动、正在收的那一位原地滚走）、**时间线上的行**（行号进模型、行序 = 叠放序、新字开新行、换行往上找空行、老工程迁移）。
- [滤镜](docs/architecture/filters.md) — 时间轴上的调色段、层号进模型（LUT 不可交换）、强度=表的线性插值、预览挂图层滤镜的实测地基（backgroundFilters 会污染整个窗口）、两条管线的四条对齐约束。
- [盖一块：模糊 / 马赛克](docs/architecture/cover-blur-mosaic.md) — 形状的一种、时间线上的一段（`ShapeKind.blur` / `.mosaic`，不画东西、不算总长、不进 `renderedShapes`、格式 v26）、**不跟着片段走**（为什么：预览没有片段级的钩子、「从旧段构造新段」漏字段的教训）；盖谁：合成 + 调色之后、形状之前；三条管线按构造一致（预览第二层播放器 + 区域容器 + 边缘外延、导出 `split → crop → gblur / pixelize → overlay`、AI 的「看」CoreImage）；八条硬约束（层序、蒙版与滤镜别同层、边缘外延、格子从左上角起算、框取偶数、高斯半径是标准差、力度按画面高、没有盖一块时不建第二层）；AI（`set_shape` 的 blur / mosaic + `strength`、`text_scan` 给的 `cover`）；实测地基、已知不足、回归与人工清单。
- [录屏生命周期](docs/architecture/screen-recording-lifecycle.md) — 状态机、journal、恢复、退出与快照。
- [Inspector 数值框](docs/architecture/inspector-scrub-number-field.md) — 写入、取消、焦点与光标合同。
- [检查器的排版](docs/architecture/inspector-layout.md) — 固定的窄栏（约 220pt）：一行的最小宽度不许超过它，否则整列被撑宽、右边被裁；菜单 Picker 不许锁宽度；长名字的下拉标题单独一行。
- [定格](docs/architecture/freeze-frame.md) — 一次性提交、PNG 归属、波纹范围与静帧管线。
- [字幕语言流](docs/architecture/subtitle-language-flow.md) — 目标语言可见性、预检与自动检测。
- [字幕轨可见性与布局](docs/architecture/subtitle-track-visibility-and-layout.md) — 一语言一轨、**两条轨独立**（2026-09-26 起：各自的 ID 和时间、来源表现算过期 / 缺译文、两个翻译按钮各动哪些句子）、画面上的布局（译文叠在原文下面或各摆各的、预览和烧录读同一份按时间切好的块）、**工程自己的样式与逐词高亮**（2026-09-28：样式两层只问 `subtitleStyle(appWide:)`、词的时间记在句子上并跟着编辑走、按词切段、ASS 标签与预览同一份位置）、选择模型（点选互斥 / 框选混选），以及三个编辑入口共用的合同。
- [轨道块标记](docs/architecture/clip-markers.md) — 源时间锚定、标记对所有选择互斥、命中区分层。
- [即时提示](docs/architecture/instant-tooltips.md) — 不许用系统 `.help`、快捷键单一来源、面板四条硬约束。
- [本地化](docs/architecture/localization.md) — 写死的文案必须每张表都有（一张原文表 + 每种语言一张译文表，有几张不写死）、L10n 与 Text 的分工、lproj 小写坑、**sheet / popover 不继承应用内语言**与已知盲区、**加一种界面语言只做两件事**。
- [阻塞的媒体读取](docs/architecture/blocking-media-reads.md) — `copyNextSampleBuffer` 这类会卡住线程的读取不许进 Swift 并发的线程池（同一档 QoS 上卡满核数就整档死锁）、`MediaReadQueue` 的两种用法与宽度、唯一的例外（字幕生成逐窗口读）、什么样的阻塞会死锁。
- [预览性能 ratchet](docs/architecture/preview-perf-ratchet.md) — 量的是活不是 CPU、**每个视图 body
  第一行计数**（守卫钉着，`--fix` 自动补）、时钟连跳走真播放的入口、合成负载当 GPU 代理数字、要有两遍
  一模一样、计数逐项相等（进步必须登记）、基线只许降（抬基线的 PR 不许动产品代码）、**已知的偶发误报**
  （检查器数值框和时间线缩放桥接多一轮 → 重跑）、盲区、**时间线上的块不读工程、按值比较**（守卫钉着）、**只有一个小视图关心的状态不放在工程上发**（第十节，「正在重建」的转圈）、**点一下选中一段的时间花在哪**（第十一节：release 和 debug 一样慢、活在框架里；换 Observation 之前块的选中高亮只在根视图那一遍更新）、**播放头的每一跳只叫醒跟着它动的东西**（第十二节：订阅时钟按类型名单、大视图持有不订阅、只关心变没变的 `onReceive` 自己那份、停着才有意义的读 `PacedPlayhead`，守卫钉着）、**工程是 `@Observable`**（第十三节：body 读了什么就只被什么叫醒、按属性不按值、不驱动界面的存储 `@ObservationIgnored`、读撤销栈 / 最近列表这类不可观察的东西要自己找叫醒的来源、冒烟看 `event:project.changed.<属性>`、剩下的一半是命中测试）。
- [导出设置](docs/architecture/export-settings.md) — 分辨率档位封的是**短边**（竖屏 1080×1920 的 1080p 就是它本身）、只降不升、各管线在哪一步缩；**面板上只放这条管线真消费的设置**（按管线声明，不按控件加开关）；标题→文件名只有一个函数、导出位置的记忆链、视频和字幕文件同一条撞名规则、记住与恢复默认，以及人工回归清单。
- [生成的字幕长什么样](docs/architecture/subtitle-generation-style.md) — 先断句、后去标点、最后在整条轨上排时间；去标点的规则（句中换一个半角空格、行尾删，问号叹号引号书名号省略号列举顿号留着，数字缩写撇号不动，只在生成和机器翻译落字时去）；断句（逗号拆小句、太短的并、放不下的用动态规划挑切法、每一刀的代价表、中文按系统分词且按整句判语言）；一行多长（全角 1 半角 0.5 的字数 + 按字号和画面宽度的「放得下」，竖屏更短）；显示时间（5/6 秒、7 秒、2 帧、不到半秒接上、说完多停半秒、不越过素材结尾）；几段素材同时有字只留一条（零碎杂音、谁清楚留谁、同一段素材不算撞）；转写哪些声音（藏起来的不转、只用选中的片段）；已知不足、回归与人工清单。

## Bug 修复案例索引

- [2026-08-03 时间线捏合缩放](docs/bugfixes/2026-08-03-trackpad-pinch-zoom.md) — 事件序列与 Rosetta 旧产物。
- [2026-08-03 工程文件生命周期](docs/bugfixes/2026-08-03-project-file-lifecycle.md) — 数据丢失路径与失败分支。
- [2026-08-03 逐帧预览](docs/bugfixes/2026-08-03-scrub-preview-keyframe-snap.md) — 零容差与链式 seek。
- [2026-08-03 裁切闪烁与半速](docs/bugfixes/2026-08-03-trim-flicker-halved.md) — 坐标反馈、动画与去抖。
- [2026-08-04 编辑器工具复审](docs/bugfixes/2026-08-04-editor-tools-review.md) — 工具模式、升轨和旋转包络。
- [2026-08-04 半透明绿底](docs/bugfixes/2026-08-04-opacity-green-background.md) — 默认合成器背景陷阱。
- [2026-08-04 Transform 复审](docs/bugfixes/2026-08-04-transform-review.md) — 格式版本、叠化与缓存原子性。
- [2026-08-04 AVFoundation 预渲染](docs/bugfixes/2026-08-04-prerender-avfoundation-pitfalls.md) — 空轨与透明背景。
- [2026-08-05 Inspector 拖调](docs/bugfixes/2026-08-05-inspector-scrub-field-gestures.md) — 编辑态、焦点与亚像素容差。
- [2026-08-05 导出预渲染复审](docs/bugfixes/2026-08-05-export-prerender-review.md) — 覆盖、alpha、取消与临时文件。
- [2026-08-06 字幕生成复审](docs/bugfixes/2026-08-06-subtitle-generation-review.md) — 切窗、身份、取消、账本与缓存。
- [2026-08-06 构建版本与 shell](docs/bugfixes/2026-08-06-build-version-and-shell-traps.md) — 版本兜底、变量边界与 pipefail。
- [2026-08-06 字幕面板语言默认值](docs/bugfixes/2026-08-06-subtitle-panel-language-defaults.md) — 占位值与隐藏选择。
- [2026-08-06 包内授权声明](docs/bugfixes/2026-08-06-stale-bundled-license-notice.md) — 生成器与忽略产物。
- [2026-08-07 录屏地基复审](docs/bugfixes/2026-08-07-screen-recording-foundation-review.md) — 假绿、外部真值与状态机。
- [2026-08-07 录屏 Phase 2–4 复审](docs/bugfixes/2026-08-07-screen-recording-phase2-4-review.md) — 接线、恢复、退出与真实首测。
- [2026-08-08 运行期素材重链接](docs/bugfixes/2026-08-08-runtime-media-relink.md) — 素材移动后的重核对。
- [2026-08-08 悬停影子播放头与删除键](docs/bugfixes/2026-08-08-hover-ghost-playhead-and-delete-key.md) — peek 语义与统一删除入口。
- [2026-08-08 静帧循环解码过慢](docs/bugfixes/2026-08-08-still-clip-loop-decode-slow.md) — image2 输入帧率。
- [2026-08-08 CI 首跑与吞错](docs/bugfixes/2026-08-08-ci-first-run-sdk-and-swallowed-errors.md) — SDK 与构建日志。
- [2026-08-08 主轨乱序黑帧](docs/bugfixes/2026-08-08-main-track-array-order-black-frame.md) — 时间顺序与竖版布局。
- [2026-08-08 静帧逐帧解码](docs/bugfixes/2026-08-08-still-clip-decode-per-frame.md) — 单帧解码、loop 滤镜与性能守卫。
- [2026-08-09 同语种翻译](docs/bugfixes/2026-08-09-subtitle-translate-after-same-language.md) — 可见选择与提交前预检。
- [2026-08-09 PR #22 后续复审](docs/bugfixes/2026-08-09-pr22-review-followups.md) — 格式版本、语言检测、可听性与取消。
- [2026-08-09 翻译第二次卡在 0/N](docs/bugfixes/2026-08-09-translate-stuck-at-zero.md) — configuration 换代与看门狗。
- [2026-08-09 时间线拖动与对齐](docs/bugfixes/2026-08-09-timeline-clip-drag-lag-and-alignment.md) — 渲染偏移、吸附与唯一落点。
- [2026-08-11 录屏静止期尾部黑屏](docs/bugfixes/2026-08-11-screen-recording-idle-tail-black.md) — 画面轨短于容器、fragment 与守卫的触发条件。
- [2026-08-12 渐入开头爆音](docs/bugfixes/2026-08-12-audio-fade-in-pop.md) — 混音器的增益 de-zipper、峰值 vs RMS、场景全落在默认值上的守卫盲区；**第二轮**：常量提前量是在赌平台的平滑窗口（离线 ~17ms / 实时 ~90ms），自检够不着 AVPlayer，断言要上移到结构不变量。
- [2026-08-12 提示弹在很远的地方、还没翻译](docs/bugfixes/2026-08-12-instant-tooltip-first-show-far-off.md) — NSHostingView 把尺寸约束灌给面板窗口、摆好≠摆定、本地化查不到是静默降级。
- [2026-08-12 压缩预览区时播放条压到工具栏上](docs/bugfixes/2026-08-12-preview-transport-row-overlap.md) — VStack 里拒绝再矮的那个把兄弟挤出边界；谁让步必须显式声明。
- [2026-08-12 转场前面有硬切就导不出](docs/bugfixes/2026-08-12-xfade-timebase-mismatch.md) — xfade 硬检查 timebase、concat 输出固定 AVTB、只在接缝顺序上翻车。
- [2026-08-12 框选复审的五条后续](docs/bugfixes/2026-08-12-marquee-review-followups.md) — 「整组同一位移」四处没收口、自检入口比生产浅一层的假绿、数个数的守卫也会假绿。
- [2026-08-12 双击字幕的浮层弹在很偏左](docs/bugfixes/2026-08-12-cue-popover-anchored-at-row-origin.md) — `.offset` 只改渲染不改布局框，popover 锚在行首；验位置的样本不能挑在原点附近。
- [2026-08-12 字幕三入口首测](docs/bugfixes/2026-08-12-subtitle-editing-surfaces-smoke-fixes.md) — HSplitView 不保护最后一栏；临时行不能给自己上焦点，聚焦失败会让按键变成快捷键。
- [2026-08-12 字幕编辑复审的六条后续](docs/bugfixes/2026-08-12-subtitle-editing-review-followups.md) — 视图里的草稿会被「先写盘再销毁视图」漏掉；CAS 基线必须是会话快照；绑定拒绝写入时 UI 要回读。
- [2026-08-16 竖图缩略图隐形命中区盖死标尺](docs/bugfixes/2026-08-16-clipped-thumbnail-hit-area-covers-ruler.md) — `.clipped()` 只裁绘制不裁命中；块内装饰必须不吃事件；右键是命中区探针。
- [2026-08-16 形状叠层不跟播放头](docs/bugfixes/2026-08-16-shape-overlay-ignores-playhead.md) — 按 displayTime 取内容的叠层必须直接订阅 PlayerClock；形状块裁切把手照抄剪辑块合同。
- [2026-08-22 带空 cue 的工程字幕文件导不出](docs/bugfixes/2026-08-22-subtitle-export-empty-cue-verification.md) — 「哪些 cue 会被写出去」只能是序列化器一份账，校验在调用方另算一份就会把好文件报成坏的；块格式里空行是结构字符，cue 文本要先消毒。
- [2026-08-22 编辑译文退格删字整条 cue 消失](docs/bugfixes/2026-08-22-subtitle-editing-backspace-deletes-cue.md) — 「第一响应者是文本视图」判不住所有正在打字的时刻，全局快捷键要给字幕草稿让路；⌫ 的每条到达路径（monitor / onDeleteCommand）都得堵。
- [2026-08-23 提示悬浮在打开文件对话框上](docs/bugfixes/2026-08-23-tooltip-survives-open-panel.md) — 靠 hover 退出维护的状态必须假设退出事件永远不来（模态/键盘触发）；打断信号（mouseDown / keyDown / resignKey）才是兜底。
- [2026-09-18 轨道一多就没法上下滚](docs/bugfixes/2026-09-18-timeline-cannot-scroll-vertically.md) — 时间线改双向滚动；轨道头列/标尺各自钉住且只有它们订阅滚动量；裸 VStack 会替整条界面要高度，把工具栏挤出窗口。
- [2026-09-18 框选的框不跟鼠标](docs/bugfixes/2026-09-18-marquee-anchored-at-stale-scroll-offset.md) — 手势要用的量必须现读 NSScrollView，preference/@State 这类异步观察值在起手那一拍还是旧的；全时间线只有框选用绝对坐标，所以只有它会露馅。
- [2026-09-18 预渲染烤进了该让位的渐变](docs/bugfixes/2026-09-18-prerender-fade-ignores-transition.md) — 临时时间线没有邻居，任何依赖邻居的仲裁都必须由调用方算好传进去；仲裁只能有一处。
- [2026-09-18 自检脚本的源文件清单漏掉新依赖](docs/bugfixes/2026-09-18-check-script-source-list-drift.md) — 手抄的清单会漂，八项检查齐红在同一条编译错误上。
- [2026-09-20 磁吸关着时转场预览有、成片没有](docs/bugfixes/2026-09-20-transition-preview-export-divergence.md) — 「两段是否真相叠」导出和预览各用一套判据；回归断言只造了相叠的几何，所以一直假绿。
- [2026-09-20 拖短转场时遮罩整块往右挪](docs/bugfixes/2026-09-20-transition-mask-drifts-when-shortened.md) — 宽度有下限、位置没跟着补偿，撑出来的几个 pt 全长在右边。
- [2026-09-20 悬停光标卡住](docs/bugfixes/2026-09-20-hover-cursor-stack.md) — 全 App 共用一个 `NSCursor` 栈，漏押/错弹一次就全局卡住；第一版「自己记账」没修对，靠探针 + 两进程对读 `NSCursor.current` 才定的性。
- [2026-09-20 播放头断线、点标尺没反应](docs/bugfixes/2026-09-20-playhead-line-broken-and-ruler-dead.md) — 内容比视口矮时被 SwiftUI 纵向居中：线只画中间一段、标尺的命中区没跟着 `.offset` 走。
- [2026-09-21 源文件清单守卫只盯着枢纽文件](docs/bugfixes/2026-09-21-source-list-guard-only-watched-the-hub.md) — 上面那条守卫只算一个文件的同伴，另外两类漏项看不见；本地全绿、CI 六项编不过。守卫已扩到清单里的每一个文件，并写明「别开只有 extension 的文件」这条盲区。
- [2026-09-21 刚加进轨道的素材没贴左边](docs/bugfixes/2026-09-21-timeline-content-centered-horizontally.md) — 上一条的**横向孪生**：只修了纵向、守卫也只钉了纵向，于是「工程短 + 窗口宽」下整条时间线飘到视口中间，还把框选的 `内容 x = 视口 x + offsetX` 打破了。两轴一起钉。
- [2026-09-21 时间线右边小半个视口是死区](docs/bugfixes/2026-09-21-timeline-right-padding-dead-zone.md) — `minWidth` 撑出来的空白不自带命中区；顺序决定命中区盖多大，而界面上看不出来；另一根轴没事纯属被播放头顺手撑住。
- [2026-09-23 从 Finder 拖文件进时间线标尺以下没反应](docs/bugfixes/2026-09-23-timeline-file-drop-claimed-by-inner-drop-region.md) — **外部拖入和 App 内拖动是两套路由**：外部拖入只有闭包式 `.onDrop` 收得到，且由**最里面**那个落点区独占认领、类型对不上也不往外找。滤镜/音频库那两个代理式落点因此把文件拖入接住又扔掉，整块滚动内容变死区。三次修错的过程（套用同形旧教训、因果倒置、只修一半）比结论更值得读；守卫曾被写成**方向相反**的一条。**（「两套路由」「代理式收不到外部拖入」两条结论已更正，见下一条。）**
- [2026-09-23 滤镜 / 音频库 / 转场卡片拖不进时间线](docs/bugfixes/2026-09-23-in-app-drops-swallowed-by-file-underlay.md) — 上一条的修复把文件落点垫在三套卡片落点**里面**，卡片全被吞了：App 内拖动同样是「最里面那个独占、类型不对也不往外找」，空类型 `.onDrop(of: [])` 也独占。探针实测后改成整条时间线只挂一个 `TimelineDropRouter`；**两边都落不下去的合成拖动 A/B 不是证据**；松手后 SwiftUI 还会补发一拍 `dropUpdated`。
- [2026-09-23 磁吸开着时拖文件的落点框画错位置](docs/bugfixes/2026-09-23-file-drop-frame-ignores-magnet.md) — 「画框和落地共用一个函数」只共用了落点函数，没复现 `perform` 收尾的 `packMain`；框要在副本上把落地原样走一遍（`landingsAfterMagnet`）。
- [2026-09-23 滤镜卡片、音频库素材拖不进时间线](docs/bugfixes/2026-09-23-custom-drag-types-not-declared.md) — 两个自定义载荷类型没在 Info.plist 声明，系统认不出，拖放被静默拒绝（从上线起就不工作）；Info.plist 里「不声明也能跑」那句推断性注释误导了后来的两个功能；探针上「外部来的自定义类型不认」其实也是这个原因。
- [2026-09-23 转场卡片拖到接缝上没反应](docs/bugfixes/2026-09-23-transition-drop-cancel-ends-session.md) — 落点在「这里不能放」时回了 `.cancel`：那是「取消整轮拖放」，SwiftUI 之后不再调 `dropUpdated`；改回 `.forbidden`。只有一个落点之后拖动总先经过不能放的地方，这个错从偶发变成必现；同一个「拖过去没反应」这一天里先后是四个不同的原因。
- [2026-09-23 音量线上的点按不住、偏着抓会跳](docs/bugfixes/2026-09-23-volume-curve-points-unclickable.md) — 窄带和小圆 append 进同一条路径，非零环绕数在重叠处抵消，圆心（压在线上）成了洞；自检测的是「离哪个点最近」的平行几何，没测命中测试真正用的形状。拖小把手要用相对位移。
- [2026-09-23 CI 说清单缺文件，其实不缺](docs/bugfixes/2026-09-23-grep-q-sigpipe-false-red.md) — pipefail 下 `printf | grep -q`：grep 命中就退出，printf 吃 SIGPIPE，整条管道判失败，命中反而报「缺」。内容过 64KB 必红、小内容看调度；一个脚本里早学到的「用 grep -c」没升格成检查，别处攒到 111 处。
- [2026-09-23 打开工程后缩略图和波形全空](docs/bugfixes/2026-09-23-waveform-decode-deadlocks-thread-pool.md) — 读 PCM 的阻塞循环跑在 Swift 并发的协作线程池里，43 个文件一起读把 utility 整档堵到死锁（8 核上 7 个没事、8 个就死），取缩略图的 task 在同一档陪着死；原来的自检一次只读一个文件，所以一直绿。可能死锁的自检要带普通线程上的看门狗；Rosetta 终端里 `sample` 要加 `arch -arm64`。
- [2026-09-23 一条轨上换了音频格式，从那儿起没声音、预览卡住](docs/bugfixes/2026-09-23-meter-tap-dies-on-audio-format-change.md) — 电平表的 tap 挂在合成音轨上，同一条合成音轨中途换源格式（采样率 / 声道 / 编码），tap 被重新 prepare 后再也不被调用：那条轨从此静音，从换格式之后起播播放器不走。修法是一条合成音轨只装一种格式。先离线读（不挂 tap）排除数据问题，再用静音的 AVPlayer 在命令行里跑实时管线定性；自检素材只有一种格式是这次的盲区。
- [2026-09-24 压缩 / 烧录选 1080p，竖屏视频被缩成 608×1080](docs/bugfixes/2026-09-24-resolution-cap-shrinks-portrait-video.md) — 档位名说的是短边，代码封的是高度；接口只收高度、表达不了横竖，自检素材又全是横屏。**缺的输入比写错的逻辑更难发现。**
- [2026-09-24 应用里选了简体中文，所有 sheet 和 popover 却还是英文](docs/bugfixes/2026-09-24-sheets-ignore-in-app-language.md) — SwiftUI 不把 `\.locale` 带进 sheet / popover（探针实测），只有 `L10n` 那几句是中文、于是半中半英；系统本身是中文时整个被盖住。每个新宿主都要自己套 `.appLanguage()`，守卫钉着。
- [2026-09-24 剪辑导出面板说「音频原样复制」，其实每次都重新编码](docs/bugfixes/2026-09-24-export-panel-promised-audio-copy.md) — 共用的设置界面按控件加开关，只修到被点名的分辨率 / 帧率，音频那一栏没人对照过管线。改成按管线声明自己消费什么。
- [2026-09-24 本地化守卫不扫 `LabeledContent`，「File」一直没翻译](docs/bugfixes/2026-09-24-labeledcontent-missing-from-localization-guard.md) — 按调用名清单扫的守卫，清单外整类调用是**静默**的盲区；用到仓库里第一次出现的控件，先去守卫清单里查一眼。
- [2026-09-24 主轨转场的地方，预览的声音掉下去一截](docs/bugfixes/2026-09-24-preview-mix-ignores-transition-expansion.md) — 预览换 mix 的三个入口拿没展开的用户状态铺斜坡，接缝上最深掉 25 dB，成片是好的；自检只读 build 顺手产出的那份 mix，走不到生产入口。**两份结果互相比，比不出它们一起错**：第一版守卫撤掉修复照样绿，加上绝对期望才红。
- [2026-09-24 选了声音场景却看不见选的是哪个](docs/bugfixes/2026-09-24-sound-scene-row-widens-inspector.md) — 标题和锁死宽度的下拉挤一行，超过检查器窄栏，整列被撑宽、右边被裁（「Mute」只剩「Mu」）；先用独立探针排除了「带 Section 的菜单 Picker 不显示选中项」的猜测。自检全绿、实机一眼就看见 —— 界面改动交之前要在真窗口里看一眼。
- [2026-09-24 来回换声音场景，换下来的效果链一直攒着不放](docs/bugfixes/2026-09-24-sound-scene-chains-pile-up.md) — 「等宿主释放再放」而宿主（tap）跟着整条合成活，等于不放；一条失真链 ~8MB。改成多挂一拍、下次换配置时放。
- [2026-09-24 点一下选段卡半秒、拖块和滚动跟不上手](docs/bugfixes/2026-09-24-timeline-blocks-observe-whole-project.md) — 时间线上每个块和每条音量线都 `@ObservedObject` 着整个工程，点选一段 73 个块全重算、61 条线全重画；块的输入带闭包、没 `Equatable`，拖动每一拍全部块跟着时间线重算。块只收值、自己比较、调用处套 `.equatable()`（守卫钉着）；body 次数降十倍、CPU 只降三分之一 —— 「一拍多少次」和「一次多贵」是两笔账。
- [2026-09-24 点了标记按 ⌫ 删不掉](docs/bugfixes/2026-09-24-marker-delete-key-eaten-by-note-field.md) — 单击就弹出带备注框的面板，备注框成了第一响应者把 ⌫ 吃掉；点别处关面板又把选择清了。改成单击只选中、双击弹面板、右键菜单（守卫钉着）。**点一下就弹带输入框的面板 = 交出键盘**；冒烟驱动的工程拷贝要放在 Downloads / Desktop / Documents 之外（TCC 每次重编都重新弹，App 卡在 `getxattr` 里像是工程没打开）。
- [2026-09-24 改得勤就隔一会儿卡一下：自动保存每次重建书签](docs/bugfixes/2026-09-24-autosave-rebuilds-bookmarks-every-save.md) — 存盘给每个素材现建系统书签，57 个约 55ms、每 2 秒一次；缓存按「路径 + inode + 卷」认，同名换文件必须重建。
- [2026-09-25 裁切不跟链接：视频裁短了，链接的音频留在原长](docs/bugfixes/2026-09-25-trim-ignores-linked-clips.md) — 挪、切、删都走 `linkedClipIDs`，唯独把手的裁切没走；裁的算法现在只有 `TimelineTrim` 一份，链接伙伴 / 选中的一组同一个量、谁先到头整组一起停。
- [2026-09-25 ⌘ 拖框加选把原来选中的滤镜段丢了](docs/bugfixes/2026-09-25-marquee-additive-drops-filters.md) — 框选结果 `TimelineMarquee.Hit` 的五类都带 `= []`，滤镜段进框选时加选的 `union` 和起手的 `base` 都漏了 `filters`、照样编过。去掉默认值（漏写一类就编不过）+ 夹具每一类都不空的往返自检。**带默认值的字段 + 成员初始化器，加字段时编译器一声不吭**；⌘ 拖框在进程内冒烟里驱不动（读的是真键盘）。
- [2026-09-25 拖块 / 拉框每一拍整条时间线重算一次](docs/bugfixes/2026-09-25-drag-session-in-timeline-state.md) — 拖动会话是时间线的 `@State`，每一拍写一次时间线 body 就整个重算：ForEach 的 diff、AttributeGraph 的更新和布局挡不住，块的 `.equatable()` 救不了这一层。会话搬进 `TimelineDragBox`（时间线持有不订阅），块只 `onReceive` 自己那份位移 / 框选命中（**和模型一样就记 nil**，不然框一起手全部块各重算一遍），覆盖层是唯一订阅者。守卫要扫全仓不能只扫一族 —— 反向验证抓到的。
- [2026-09-25 松手重建预览把每个素材重新打开一遍、还白叫醒整个编辑器](docs/bugfixes/2026-09-25-rebuild-reopens-every-asset.md) — 每次重建 `AVURLAsset` 都是新开的（一次 63 个），「正在重建」和 `renderSize` 每次都在工程上发、每发一次整个编辑器重算一轮。素材按文件身份（路径 + inode + 卷 + 大小 + 修改时间）进程级缓存（`MediaAssetCache`），换了文件、原地改写过才重开；「正在重建」挪进只有工具栏转圈订阅的小对象，`renderSize` 没变不写。第一版说「没有视图读它」就摘了 `@Published` —— 其实转圈在读，没卡住全靠时钟碰巧一起发。
- [2026-09-25 PR #71 首跑 CI 红了两项](docs/bugfixes/2026-09-25-pr71-first-ci-run.md) — 数字可点范围的自检拿普通文字当参照（数字是 App 自己等宽排的，本机碰巧对上、CI 差 1.8pt）；滤镜块的接线守卫在另一组里还钉着旧名字。**期望值要和被测值走同一条路径；改接线后按旧名字把 scripts/、checks/ 全 grep 一遍**。
- [2026-09-25 老虎机数字 365 → 90 停在「090」上](docs/bugfixes/2026-09-25-odometer-leading-zero.md) — 位数少的那一头，多出来的高位被 `?? 0` 编成了 0（逗号、负号也照样留着）；改成那一格滚成空白、宽度收掉。**缺省值替缺失的数据说了话**；自检只测了位数最多的那一头。第一版照居中重排，自检全绿、一渲用户的真工程「90」和「° SOUTH」之间空出半格 —— 居中和右对齐改成右边不动；第二版正在滚走的「1」蹭到「3」跟前像个逗号 —— 改成原地滚走。
- [2026-09-25 播放的时候卡：时钟每跳一下，整个编辑器都重算一遍](docs/bugfixes/2026-09-25-playback-wakes-whole-editor.md) — 根视图、时间线本体、检查器、素材库、字幕列表都订阅着一秒二十跳的播放器时钟，一跳约 172 次 body；用户点名的左栏只占约 3%。跟着播放头动的拆成小视图各自订阅，停着才有意义的读播放头的慢读法（`PacedPlayhead`：只跟「放置」、播放中不跟、停下追上一次），按钮能不能点走 `.disabled(followingPlayhead:)`；真播放一跳降到约 25 次，一半是电平表。订阅时钟按类型名单钉着；**用户点名的地方不一定是大头，先看明细**。
- [2026-09-24 预览里想拖文字，一按下去变成旋转](docs/bugfixes/2026-09-24-text-rotate-handle-hit-area-at-center.md) — 旋转把手的 `contentShape` 写在 `.offset` 之后，可点的圆留在字的正中心（看不见的 22pt 旋转区），黄点本身反倒点不动；顺带把没选中的字的可点范围从 80% 宽的整框收到看得见的部分。单行样本放过了写反的 y 轴翻转 —— 反向验证时才发现，补了不对称的样本。
- [2026-09-26 点一下选中一段，整个编辑器跟着重算](docs/bugfixes/2026-09-26-selection-wakes-whole-editor.md) — 工程是一个大 `ObservableObject`，33 处订阅，只改 `selection` 也全体重算；换成 `@Observable`（用户拍板「A」）、根视图不读选择、转场卡片两张帧一起换，每点一下 body 334 → 120、进程 CPU 和主线程各省约四分之一（剩下的一半是 SwiftUI 的命中测试，和重算几个视图无关）。**换机制后要把「以前被顺带刷新」的地方一个个找出来**：文件菜单的最近打开（反向验证：不显式读 `documentURL` 就一直停在启动时的「没有」）、撤销按钮（听撤销栈的通知，别听 Checkpoint）。冒烟驱动加了 `open` / `menu` 两步，并记下三个限制（点 AppKit 控件会卡死、合成事件关不上撤销组、菜单快捷键没用）。
- [2026-09-26 上层轨上按 V 藏起来的段，成片里画面还在](docs/bugfixes/2026-09-26-hidden-upper-clip-still-exported.md) — 导出图算好了 `overlayVisible` 却只拿去判断「有没有画面」，叠上层轨和预渲染那两圈仍按轨去 `lane.clips` 里取段，只滤了藏起来的轨；声音走预览混音早就滤掉了，所以只漏画面。扫描守卫只查「出现过 `ClipVisibility.visible(`」、取帧自检只测预览 —— 补了真导出抽帧（带一份没藏的对照）。**过滤清单算出来了，就让每个消费者都走它。**
- [2026-09-26 播放中按 Return 回到开头，App 在音频线程上崩溃](docs/bugfixes/2026-09-26-meter-crash-on-go-to-start.md) — 电平表的环形缓冲拿 tap 给的时间当下标，tap 在播放中精确跳回 0 之后报了比 0 早的时间，负数取余还是负数、越界 trap，整个 App 退出。环里丢掉 0 之前的位置（负时间从哪来都不许越界）；最小探针没复现出负时间，触发条件没追到。**从平台回调拿来的时间，当下标之前先问一句会不会是负的。**
- [2026-09-26 原文、译文叠在一起时，点英文、改英文都落到中文上](docs/bugfixes/2026-09-26-stacked-subtitle-frame-lands-on-translation.md) — 预览上字幕块的高度一直量成 0：量尺寸的偏好值合并写成 `value = nextValue()`，被兄弟节点的默认值 `.zero` 盖掉；单行时 24 点保底恰好像一行，一个多月没人发现，叠成两行才露馅（框只框住译文、点原文落到译文上）。第一次按「闭包旧、字典被冲掉」修错了方向，跑一遍加日志才看到根本没量到。扫描守卫钉着所有 `PreferenceKey.reduce`。
- [2026-09-26 捏合放大时鼠标底下的内容跑掉](docs/bugfixes/2026-09-26-pinch-zoom-anchor-never-applied.md) — 「指针下缩放」2026-08-03 就写了，锚点那一步却从来没生效：找滚动视图时把根视图自己的坐标喂给了 `hitTest`（它要父视图坐标），SwiftUI 的根视图是翻转的，于是找的是上下镜像的那一处（预览区），找不到就静默跳过。改成从时间线自己的滚动几何量锚点，删掉 §5b 给捏合的「暂时豁免」。**`hitTest` 吃父视图坐标；已经有唯一真相时别用坐标找第二份；锚点对不对要看数字**（冒烟加了 `zoom` 步骤）。
- [2026-09-26 纵向滚下去之后，轨道上的块画到钉住的标尺上面](docs/bugfixes/2026-09-26-tracks-cover-pinned-ruler.md) — 做纵向缩放时冒烟发现：2026-09-24 整轨换位给每一行都挂了带 `.zIndex` 的位移包装，**叠放次序只认最外面那一层**，标尺自己写的 `.zIndex(50)` 被盖成 0；左边的总推子则从加进标尺那一行起就跟着滚走。层级改在包装那一层给（`pinnedOnTop`），总推子同样钉住。**给每一行都挂带层级的包装，等于作废每一行自己的层级；钉住的东西要在真滚过的状态下看一眼。**
- [2026-09-26 分割一段藏起来的素材，右半段冒回成片；音频库素材分割后右半段丢了身份](docs/bugfixes/2026-09-26-split-drops-hidden-and-library-key.md) — 写复制粘贴时读分割发现：`split` 手写逐字段构造右半段，后加进 `EditClip` 的 `isHidden`、`remoteKey` 都有默认值、没人补，编译器一声不吭。补上两处；复制粘贴那一路改走编码往返、不手写。**从旧段构造新段的地方加字段时都要过一遍，能不手写就不手写。**
- [2026-09-26 按 V 藏起来的片段照样被转写成字幕](docs/bugfixes/2026-09-26-subtitle-generation-transcribes-hidden-clips.md) — 字幕生成的可听快照（`SubtitleAudibleClips.soundClips`）是照着预览合成**抄**的一份合同，2026-09-18 加单段的 V 时预览、导出都接上了，它没人记得，藏起来的段照样被转写。改成调同一个 `ClipVisibility.visible`；落点表补上字幕生成这一行。**「复刻某某合同」的副本，合同一改就漏；能调同一个函数就调同一个。**
- [2026-09-26 停顿被算进相邻的词：字幕比声音早 0.9 秒、片段开头的词丢了](docs/bugfixes/2026-09-26-pause-stretches-next-word.md) — 识别器把句号后的停顿并进**下一个词的开头**、句末的停顿并进**它自己的结尾**（拿 ffmpeg silencedetect 量出来的）；拿开头当字幕起点就早出来，拿整段中点判归属就把片段边上的「That's」判丢。改成先估开口、按标点判停顿在哪边、宁早勿晚；太短的小句按能在屏上留多久算。**识别器给的词时间不是开口时间，用它之前先对一遍真音频；一个大毛病（整体晚 2.5 秒）会盖住另一个。**
- [2026-09-26 自动检测语言拿音效当探针，明明是英语却检测不出来](docs/bugfixes/2026-09-26-auto-detect-probes-sound-effects.md) — 探针只取可听快照里第一段读得出来的，主轨在前，AI 视频的镜头只有音效，每个候选语言都 0 分。改成长的先、每段先用已装语言短转写听一听有没有人声（最多 6 段）。**「读得出来」不等于「有人说话」：挑样本要先确认它带着要判的东西。**
- [2026-09-27 AI 的改动撤一步，整条时间线空了](docs/bugfixes/2026-09-27-ai-edits-share-one-undo-group.md) — 撤销管理器按**用户事件**分组，AI 从 socket 来的改动不是事件、后台的 App 又一个事件都没有，所有步堆进同一组；第一版手动关掉自动开的组，下一次登记就抛异常、App 闪退（自检在命令行里当场崩出来）。改成每个改动工具自己显式开一组、暂时绕开按事件分组，包的那一段必须同步。**「按事件分组」只对用户事件成立；别去关别人自动开的组。**
- [2026-09-27 AI 翻译按旧的原文语言去翻，等下载时又一声不吭](docs/bugfixes/2026-09-27-ai-translation-stale-source-language.md) — AI 把原文改写成中文，工程里记的还是英文，系统按「英文→韩文」去翻；缺语言时 macOS 的下载框只能由用户点，框在后面、任务停在 0%、谁都在等，系统框的进度条还会停。改成按字判断原文语言、翻之前先查装没装、要下载就把 SrtFlow 摆到前面并在结果 / 进度 / 提示条里写明「去点下载」、自己每两秒问一次真实状态。**给 AI 用的入口按内容现判、别信旧标签；要人动手的地方必须说出来。**
- [2026-09-27 加了几段音效，预览整个黑屏（标题照样在）](docs/bugfixes/2026-09-27-preview-black-after-audio-tick-pushed-past-end.md) — 合成器用 `CMTime(seconds:)` 换格子会**截断**：5.3 + 1.4 = 6.699999999999999 落在前一格，补空白时从那儿插进去，切下前一段音效的最后一格、一路挤到全片最后，合成比画面长 1/600 秒，视频合成判无效 → 预览只剩黑底，正式版一样。改成只往合成轨真正的末尾后面接、合成完裁到总长（`CompositionTime`）；第一版顺手把换算改成四舍五入，CI（macOS 15）的声音渐变自检卡死 30 分钟，退回截断，并给那项自检加了看门狗。二分到「中间空一截 + 最后一段收在结尾」这个组合才找到。**CMTime 截断、AVFoundation 的 insert 会挤走已有内容而不报错、合成总长多一格就黑屏；修 bug 别顺手改到处在用的换算。**
- [2026-09-27 拼图函数叫 `sheet(`，被 sheet 语言守卫当成了 SwiftUI 的 `.sheet`](docs/bugfixes/2026-09-27-contact-sheet-name-trips-sheet-guard.md) — AI「看」把几帧拼成一张的函数叫 `AIContactSheet.sheet(`，按调用名扫的守卫把它当成弹出的 sheet，CI 第 1 组红；改名 `draw`。**按名字扫的守卫，名字就是接口：别给自己的函数取 SwiftUI 修饰器的名字；推之前把 `checks/*.sh` 的扫描守卫也跑一遍（秒级）。**
- [2026-09-27 GBK 编码的字幕文件读出来是乱码](docs/bugfixes/2026-09-27-gbk-subtitles-read-as-utf16.md) — 读字幕（剪辑页挂字幕、字幕编辑、烧录）和批量转换都是「UTF-8 → UTF-16 → GBK」，而 `.utf16` 几乎什么都解得出来，GBK 永远轮不到，整份读成乱码；两份抄来的规则还不一样。给 AI 写读文稿的自检时造了一份 GBK 才撞出来。改成只有 `TextDecoding` 一处、先看 BOM、像 UTF-16 才按 UTF-16。**「解得出来」不等于「解对了」：宽容的解码器只能放最后，或者先用特征确认。**
- [2026-09-27 段上画了音量曲线时，AI 调 volume_db 听不出变化](docs/bugfixes/2026-09-27-ai-volume-ignored-on-curved-clips.md) — 有曲线时曲线取代 `volume`，AI 却一律写 `volume`；检查器早就改成整条曲线平移。改成同检查器、回给 AI 的状态带上曲线。**给 AI 开参数之前先看检查器改同一个值时做了什么。**
- [2026-09-27 烧录页存好的字幕样式，要先去烧录页转一圈，剪辑页才用得上](docs/bugfixes/2026-09-27-remembered-subtitle-style-waits-for-burn-in-page.md) — 全 App 共用的字幕样式放在烧录队列上，读回来却写在烧录页的 `onAppear` 里；App 直接进剪辑页时那一页从没出现过，预览、导出、AI 用的都是默认样式。改成队列创建时读回来（`EncodeQueueMemory`，同 `VideoEditExporter` 的 init），守卫钉着。顺带查过：`burnInFontURL` 从没赋值，但这版 libass 用 CoreText 按名字找到同一个文件，成片一样。**一份设置有了第二个读者，读回来就不能挂在某一页的 `onAppear` 上。**
- [2026-09-27 AI 放素材时顺带挂了字幕，之后撤一步整条时间线空了](docs/bugfixes/2026-09-27-ai-undo-swallowed-by-subtitle-attach.md) — `add_clips` 先挂字幕（登记在 `AIUndoGrouping.step` 外面）再进 step 放素材；后台的 App 里按事件自动开的那一组关不上，之后每个 step 都嵌进去。冒烟 A / B 两组只差一个 .srt 才定的性。挂字幕挪进同一个 step，生成字幕、翻译写回、删占位块这些异步落账也各包一层，守卫钉着。**「每个工具包一层 step」只在一次调用里所有登记都在 step 里时成立；异步落账要自己成一步。**
- [2026-09-27 批量转换字幕，旁边的同名文件被悄悄盖掉](docs/bugfixes/2026-09-27-batch-convert-overwrites-existing-files.md) — `convertFile` 算出名字就覆盖写，同格式转回源文件夹连源文件都盖（开源第一版起就这样）；用户拍板改成加编号。「撞名加编号」挪进 SrtFlowCore 的 `ExportFileName.unoccupied` 只留一份（App 里原有两份），写时再带 `.withoutOverwriting`。**写用户文件夹的地方默认不覆盖：要覆盖就先问，不问就加编号。**
- [2026-09-28 链接开着时删掉分割出来的一块，整条素材连声音全没了](docs/bugfixes/2026-09-28-split-links-every-piece-together.md) — 链接关系就是「同一个组号」，分割却原样抄了组号：一对切开四段同号、互为伙伴，越切整串越大，删 / 拖 / 裁一块整串都跟着走（「链接」默认关，所以一直没人撞上）。切都改走 `LinkRegrouping.split`：按时间上重叠重分组，一对切开是两对。写 AI 的 cut_speech 时拿纯函数试出来的。**从旧段构造新段时，身份类的字段（id、组号）不能照抄。**
- [2026-09-28 一次放两首配乐，第二首点名要新开一条轨，却接在了 A1 后面](docs/bugfixes/2026-09-28-new-audio-lands-on-a1.md) — `add_clips` 用「这一批开过的新轨」把同批的 new_audio 并进同一条，可只要落地新开了轨就记下，前一首只是因为没有音频轨才开的 A1 也算了进去。改成只认点名要新开的那段。**要记的是意图，不是副作用。**
- [2026-09-28 英文男声的配音开头「啪」地爆音](docs/bugfixes/2026-09-28-kokoro-voiceover-clipping.md) — Kokoro 的 am_fenrir 原始峰值超过满幅（1.05–1.15），写 .m4a 那一步原样照抄，AAC 存得下大于 1 的值、一播放就被砍平；之前给用户听的样音和端到端都没跑过这个音色，自检也没有一条量电平。两种声音改成只经 `AIAudioFileWriter.writeVoiceover` 写文件、先过 `AIVoiceLevel`（说话部分 −18 dBFS、峰值封顶 −1 dBFS、只乘一个增益），真写真读的自检 + 扫描钉着。**合成器给的采样不保证在 ±1 以内；角色换了音色要用生产那条路真跑、量一下。**
- [2026-09-29 修完爆音，en_male 那几句反倒几乎听不见了](docs/bugfixes/2026-09-29-kokoro-short-pieces-explode.md) — 生产里一句旁白按句切开读，「Two.」被单独送进 Kokoro，这个转换版读太短的输入会炸（满幅的 90 倍，「好。」+43 dB，换计算单元一样）；09-28 那版「整句一个增益、按峰值封顶」被这一下带偏，后面的话掉到 −55 dB。09-28 验证时量峰值是整句喂模型、没走按句切开那一步，所以结论反了。改成放得下整句读、太短的垫一句再读只留自己的、响度按说话部分算再局部限幅。**验证修复要走生产那条路；一个尖峰不许决定整句的音量。**
- [2026-09-29 成片里的字幕比预览小一截](docs/bugfixes/2026-09-29-subtitle-preview-bigger-than-burn.md) — libass 把字号当行高（OS/2 的 usWinAscent + usWinDescent 撑满字号），预览的 CoreText 当 em，同一个字号成片只有预览的 71%（中文回退到苹方）–85%（Helvetica）；从 2026-07-30 有这个叠层起就这样，AI 按 `look` 挑的字号、生成字幕一行放几个字也跟着偏。改预览不改成片：每一截按实际画它的字体（中文回退、粗体选真粗体）乘比例（`SubtitleFontScale`），真烧一帧对比的自检钉着。第一版只量常规体、样本全绿，默认样式是粗体（Hiragino W6 比 W3 小 7%）。**同一个数字在两个渲染器里可以是两种量；「自动化够不着」要先试一下再写；样本要带上默认值。**
- [2026-09-29 预览上字幕的位置和行距和成片对不上](docs/bugfixes/2026-09-29-subtitle-preview-line-box-differs-from-libass.md) — 上一条只对了大小，位置差被写成「已知差异」放着；核对发现不止：libass 排一行用 OS/2 的 win 量度、CoreText 用 hhea（不含 leading），两套不一样的字体 —— Helvetica（默认字体）居中成片低 8 px、顶部低 16 px、两行的行距差 14%，Hiragino 底部预览低 8 px，宋体两行差 40 px。`SubtitleLineMetrics` 算出差多少、`BurnInSubtitleOverlay` 补：一行一个 Text 放 VStack（SwiftUI 的 `.lineSpacing` 不认负数）、整块按对齐挪一点（只动画面、不动拖框用的布局框）；换行不是字（第一版把它算进行框，纯中文两行多 5 px）。探针 195 组（13 字体 × 5 文字 × 3 对齐）修完全在 ±2 px，`PositionChecks.swift` 24 组 48 条，四处各拆一次分别红 23 / 18 / 4 / 4 条。**「一份数值、两个渲染面」要比位置、不能只比大小；「只差几个像素」要在几种字体和对齐上量过才敢写。**
- [2026-09-29 新建工程之后播放头停在上一个工程的 36.3 秒](docs/bugfixes/2026-09-29-new-project-keeps-old-playhead.md) — 切工程先卸片、播放头归零，可播放器换掉条目之后时间回调还会晚到一拍、报旧条目的时间，`PlayerClock` 照收，AI 不给时间的配音 / 文字就放到了 36.3 秒；打开工程时重建读到这个晚到的值，新工程从上一个的位置（或片尾）开始。没挂条目就丢掉回调；顺带让新建工程也重排预览（和打开一样，作废上一个工程还在路上的重建）。老自检不挂真条目、卸片后马上断言，异步的那一拍到不了；新的一项第一版素材没音轨，停着那种照样绿。**平台回调是异步的，同步设好的状态会被「关于上一个条目」的回调盖掉；测异步要让主循环转起来、素材要像真的。**
- [2026-09-29 风格卡给竖屏写的字号大了 1.78 倍](docs/bugfixes/2026-09-29-recipe-sizes-too-big-on-vertical.md) — `font_size` 和字幕 `size` 都是「1080 高的画面上多少像素」，9:16 的画面 1920 高，卡里照别的软件的习惯给竖屏写了大字 110–140、字幕 64–72，AI 照做的大字折成三行顶出画面、字幕一行一两个词；工具说明的「64-80 for short-video captions」同样。按生产的排版量出来改成大字 44–52、字幕 42–48，共用规矩写明换算，卡里每个字号写明画幅，自检用 `set_text` 的排版和 `SubtitleLineFit` 真排一遍上限。**写给 AI 的数字也是代码：写之前在 SrtFlow 里真排一下；单位跟着画面的哪条边走要写明。**
- [2026-09-29 转写认不出语言时，AI 被叫去「面板里选」](docs/bugfixes/2026-09-29-ai-told-to-pick-language-in-panel.md) — 自动检测没认出语言抛的是一个只带文字的错，文字是给面板写的，transcribe / generate_subtitles 原样交给 get_job。改成单独的 `LanguageUndetectedError`（面板文字不变），两个 AI 任务的失败都经 `AIHarvestFailure` 换成「带上 language 再调」，扫描钉着。**给界面写的报错不能原样交给 AI；要按种类换说法，错误就得有类型。**
- [2026-09-29 在最后一帧上定格，静帧后面还剩一截原片](docs/bugfixes/2026-09-29-freeze-leaves-sliver-after-still.md) — 定格 = 切开、插静帧、右边后挪；想停在最后一帧上，切点只能落在最后一帧里，右半不到一帧、没有自己的画面，只在静帧后面闪一下、咔一声（手动定格一样）。`FreezeSliver` 判断、`insertFreeze` 拿掉它且后面少挪这一截；够一帧的照旧留，AI 的结果里带 `tail_id`。**切出来不到一帧的那一截不是内容，切的操作要自己收拾；够一帧的要指出来，别让人去找。**
- [2026-09-29 扫画面里的字：字幕带把幻灯片底部居中的标签也框了进去](docs/bugfixes/2026-09-29-text-scan-band-swallows-slide-labels.md) — 字幕带的框按所有「下面、正中、会变」的行取，课程录屏里随页换的幻灯片标签也算进去，框从 0.77 起、叫人裁 0.24。拿六节课真跑、逐帧打出来：字幕底边都在同一条线上、每帧都不同，标签位置各异、一页停几帧同一句。改成按底边分堆、不同的字最多那一堆才是字幕（`subtitleLines`），六节课裁 0.11–0.14，和 AI 一段段看完定的对得上。**统计量要挑能把两种东西分开的特征；用真素材打出逐帧数据再定规则。**
- [2026-09-29 没下载苹方的 Mac 上，拉丁字体的样式烧中文字幕是方框](docs/bugfixes/2026-09-29-chinese-burns-as-boxes-without-pingfang.md) — 字幕大小的新自检第一次上 CI 就红：苹方完整版是按需下载的，CI 的机器没下载，CoreText 回退到系统私有的那份（预览照样是中文），libass 用不了、画成方框。回退到的字体文件在私有框架里时，预览和烧录一起换成每台 Mac 都有的冬青黑体（`SubtitleFallbackFont`），烧录在那几个字前面写 `\fn` 点名、和逐词高亮一起写（`SubtitleASSText`，`\r` 之后照样点名）；下载了苹方的 Mac 上什么都不变。**CoreText 找得到不等于 libass 找得到；认「私有」看文件在哪，不看族名。**
- [2026-09-29 text_scan 的裁切量被幻灯片标题拉大，裁线切进 PDF 页里的一行字](docs/bugfixes/2026-09-29-text-scan-crop-hint-stretched-by-slide-title.md) — 第二轮复查（0.17.5）里测试员照提示裁完，L27 底边留着半行字、L16 幻灯片自己的小字少了半行。L27：某一帧幻灯片的标题恰好贴在字幕上面，被当成两行字幕的上一行，框的上沿被拉到 0.768，这节课字幕框只有十个、10% 分位几乎就是最小值，提示从 0.13 变成 0.14，裁线切进 PDF 页里的一行字；L16 是字幕压在幻灯片自己的字上，裁一条带必然一起裁，改数字没用。上一行改成要每句都换（至少两帧、两句不同）才认，提示补一句「裁的是整条带、裁完抽几帧看」；真素材六节课只有 L27 变（0.14 → 0.13），测试员那一帧半行字变成整行。**分开字幕行和幻灯片字的特征，同样分得开字幕的第二行；样本只有十来个时分位数就是最小值；会破坏内容的补救办法要在提示里说出来。**
- [2026-09-29 text_scan 的字幕行：被切掉的字混进来、字幕稀疏时选成了幻灯片](docs/bugfixes/2026-09-29-text-scan-cutoff-text-and-sparse-subtitles.md) — PR #81 合并后核对交接里的三个「潜在弱点」：(b) 是真的 —— L27 里 PDF 页滚出画面只露一道的那一行（底边 0.997、高 0.011–0.028、字一直在变）被「不同的字最多」偏袒，字幕行 9 个框里 5 个是它们、框底边被抬到 0.997；光滤掉它们 L27 反而更糟（字幕稀疏，幻灯片 0.81–0.84 一段有 7 句不同的字，选了幻灯片、叫人裁 0.25）—— 原来是截断字碰巧凑数才对。改成截断的薄片不算字幕行、字幕是够多（≥ 3 句且 ≥ 最多那堆的三分之一）的几堆里最下面的一堆，六节调参的 + 七节留出的课共 26 组抽样裁切量一个没变、L27 底边 0.997 → 0.978。(a)「两行字幕合成一个框」抽两帧出来看是猜错了（一行字幕的框被花背景量大），`captionLike` 的上限不动；(c) 没有真实样本，不改。**「谁最多」在样本稀疏时不可靠，要用位置先验 + 最低支撑；修掉一个脏数据源前先看它是不是在替别的毛病挡枪；交接里的猜测先核对再动手。**
- [2026-09-29 搬走调色代码之后，一条接线守卫还在旧文件里找](docs/bugfixes/2026-09-29-pr84-first-ci-run-wiring-guard-in-moved-code.md) — PR #84 首跑 CI 第 4 组红：给盖一块腾地方把导出的调色搬进 `VideoEditGradeExport.swift`，`check-project-file.sh` 尾部那条「导出的调色读 renderedFilters」还指着旧文件；本机全绿，因为接线守卫接在 25 秒编译的后面、本地只跑秒级扫描守卫时跑不到 —— **和 09-25 的 PR #71 是同一个坑，写进案例的教训没被照做**。把接线守卫拆成秒级的 `checks/project-file-wiring.sh`（进第 1 组）、补了盖一块的三条。**同一个教训撞第二次，就把它变成机制；搬代码也算改接线。**
- [2026-09-29 叠化 + 关键帧之后预览全黑，去掉转场、关键帧照样黑](docs/bugfixes/2026-09-29-preview-black-slice-boundaries-straddle-a-tick.md) — 用户婚礼工程：视频合成的切片边界按秒去重、各自截断落在相邻两格，指令表空出一格就整个判无效；触发的不是转场或关键帧，是 AI 按报出来的三位小数放段（19.96 对 19.9598）和变速的零头，关键帧、转场只是多添几个挨得近的边界。改成先落格子再去重（`CompositionSlices`）；顺带发现接上之后接缝那一格 A/B 两轨都空、一帧黑而成片没有 —— 主轨不到 0.01 秒的缝两条管线同一个常量当作相接。**两个本该相等的时间各自换算就会落在相邻两格；用 App 自己的合成代码离线合成用户的工程、打印指令表，比猜「转场 + 关键帧」快得多。**
- [2026-09-29 婚礼工程那一轮之后的五处工具小毛病](docs/bugfixes/2026-09-29-mcp-tool-followups-from-wedding-session.md) — `set_text` 把字面的 `\n` 显示成两个字符；`new_project` 顺手取消了文件级的 transcribe（生成字幕和 transcribe 共用一个串行槽，cancel 不分绑不绑工程）；`look` 把无效合成的黑底描述成「夜空」；`delete_items` 一个 id 认不出整批不执行却只提那一个；几个 AI 会话连一个 App 时 `get_timeline` 看不出工程是谁；改入点后关键帧跑到负时间不吭声。**说明里的记号客户端会照字面传；共用串行槽的任务取消要分清谁的；整批拒绝要说「一个都没做」。**
- [2026-09-29 主字体里没有的字画成乱码](docs/bugfixes/2026-09-29-text-fallback-glyphs-drawn-with-main-font.md) — Core Text 排版时把 ✨、汉字回退到别的字体，字形号是那个字体的，绘制却拿主字体一把画完；默认字体苹方太全，换成花体才露馅。排版表记每个字形的字体（`TextLayoutFonts`），画的时候按字体分批；emoji 没有轮廓，描边跳过、裁剪改实画。**排版给了谁的字形号就用谁画；自检要拿故意缺字的字体。**
- [2026-09-29 圆体烧录字幕英文变成「f=」](docs/bugfixes/2026-09-29-yuanti-cmap-breaks-libass-latin.md) — Yuanti.ttc 的 (3,10) format 12 cmap 子表长度和分组数对不上、映射错位；Core Text 不用它（预览对）、FreeType 优先用它（成片错）；字幕字体清单只查过「文件可读 + CoreText 能解析」。扫描时加 cmap 体检（`FontCmapSanity`），坏的不进清单。**「CoreText 能解析」不等于「FreeType 能用」；中文对英文错先怀疑映射表；用一个 ASS 文件 + 仓库的 ffmpeg 最小复现。**
- [2026-09-29 listen 说 63.5 BPM，cut_to_beat 按 95.3 切](docs/bugfixes/2026-09-29-beat-analysis-window-differs-between-listen-and-cut-to-beat.md) — 两个工具各分析自己问的那一段（0–90 秒 / 0–32 秒），6/8 拍的歌两段各选了一种数法（2 : 3），切点比重拍晚 0.3 秒。改成请求落在文件开头 15 分钟里就分析整首歌、各自取用。**同一个量两个工具各算一份迟早两个答案；缓存按分析的对象记，不按谁来问。**
- [2026-09-29 两句字幕改成一句，挪进来的词不再逐词高亮](docs/bugfixes/2026-09-29-subtitle-merge-loses-word-times.md) — AI 只有「改字」和「删句」，拼出来的那句里新词没有时间；界面的「合并」会拼词时间但 AI 调不到。`edit_subtitles` 加 `merge`、每行报 `timed_words`；顺带加 `style.max_width`（按画幅换成左右边距，9:16 的画布只有 608 宽）。**界面有的动作 AI 也要有；「几句有」和「每句里几个有」是两个数。**
- [2026-09-29 AI 改了入点、分割之后关键帧跑到片段外面](docs/bugfixes/2026-09-29-keyframes-outside-clip-after-ai-edits.md) — 关键帧锚在素材帧上是对的（主流剪辑软件都这样），错的是把「关键帧留在看不见的地方」这种给真人的惯例原样交给 AI。不换模型，接口按机器设计：报出来的永远在片段范围里、分割两半各留自己的、`edit_clip keyframes` 用参数说意图（keep_frames / stretch / clear）、`set_keyframes relative=true` 用片段比例。**给 AI 的接口不能照搬给真人的惯例；模型和接口分开判断；机器面前不留隐藏状态。**
- [2026-09-30 Claude Code 只读到总说明的前一半，edit_clip 的说明也被截了一截](docs/bugfixes/2026-09-30-mcp-text-truncated-at-2048.md) — Claude Code 对 MCP 的总说明和每个工具说明都只留前 2,048 个字符、静默截掉（官方文档没写）：总说明 4,433 字，后半截的约定和全部规矩（要用户点头怎么问、等用户操作要转告、只用 SrtFlow 的工具……）它从来没读到过；edit_clip 2,074 字，声音场景和标记那几句也没读到。我们只有「整份清单 ≤ 72,000 字」一条预算，没有一条量的是模型真正拿到的那一份。总说明改成目录（是什么、平常的顺序、五条要 AI 主动做的规矩、按需求分组的工具名），某个工具的事进它的说明、出结果才用得上的进结果；清单里 12 个汉字换成英文。**客户端怎么读是接口的一部分；一条总预算照不到单个的上限，每种上限各要一条守卫。**
- [2026-09-30 生成字幕切出 0.1 秒的「just」](docs/bugfixes/2026-09-30-subtitle-piece-on-screen-0.1s.md) — 窄画面下一行两个词，「Darling,」并不进后面的小句就自己成条，剩下的切法里太短只罚固定 0.5、按说了多久算，「just / dive right in」和「just dive / right in」只差 0.002。改成按能在屏上留多久罚、随短的程度加重，小句并不进去时整句一起挑切法（逗号处算好断点）。**罚分要按用户感受到的量算；规则保不住时退到整体最优。**
- [2026-09-30 成片的声音过了 0 dBFS 交给 AAC](docs/bugfixes/2026-09-30-export-mix-over-0dbfs-into-aac.md) — 婚礼工程 17 个音效叠在音乐上，成片峰值 +2.15 dBFS、主推子降 3 dB 成片只降 2 dB；探针把混音和成片各量一级：AVFoundation 的 float 混音完全线性、不削，是 AAC 编码器收了过 0 的信号后RMS 掉 4.5 dB、峰值冒到 +12。写 f32 时在 −1 dBFS 封顶、封顶前的峰值报到导出面板和 AI 的结果里。**两份结果互相比之前先把每一级单独量一遍；有损编码器不是透明的管子。**
- [2026-09-30 动画行的「In」「Out」、字体目录的「Chinese」「Other」从没进过表](docs/bugfixes/2026-09-30-animation-in-out-labels-never-localized.md) — 经参数转交的文案靠手抄清单守，`help:`、`label:` 各漏过一轮之后 `title:` 和位置参数又漏了一个多月；改成从声明里找 `LocalizedStringKey` 参数、调用点自动纳入。**同一个教训撞第三次就别再补清单，改成机制。**
- [2026-10-01 录屏设置页的「follows the project」、烧录列表的「· N lines」从没进过表](docs/bugfixes/2026-10-01-interpolated-keys-never-localized.md) — 带插值的键是守卫「写明的盲区」，写进文档不等于有人守；改成对每个 `\(…)` 把 `%lld` / `%@` 都试一遍、只看直接调用点。**判不出类型就把几种可能都试一遍，比跳过强。**
- [2026-10-01 引擎接管声音之后，配乐比画面长的工程播到画面结尾停在最后一帧上](docs/bugfixes/2026-10-01-preview-item-shorter-than-timeline-without-audio-tracks.md) — 合成音轨除了出声还替合成撑着长度：拆掉它之后播放器的条目只有画面那么长，画面层停在最后一帧、引擎的播放头照走、时钟每拍去对表。builder 从画面结尾到总长垫一截黑底（只垫那一截，画面铺满的工程一层都不多）。**拆掉一样东西之前先问它顺手撑着什么；合成有效不等于播放对。**
- [2026-10-01 烧录页默认窗口宽度下字幕列被裁掉右边、文件行的提示截成省略号](docs/bugfixes/2026-10-01-burn-in-subtitle-column-clipped-at-default-width.md) — 内层 `HSplitView` 最后一栏的 ideal 和前面各栏的 min 一起放不进可用宽度就被裁；ideal 收到和 min 一样，提示用 `ViewThatFits` 少显示一句。**截图要按用户默认的窗口大小拍，1400 宽看不出。**
- [2026-10-01 播放中按空格图标慢半拍：电平条每秒 300 次问播放器要时间，被播放器的锁堵住主线程](docs/bugfixes/2026-10-01-meter-current-time-blocks-main-thread.md) — 心跳看门狗第一次跑就抓到 2.4 秒的栈：`player.currentTime()` 要同步拿播放器内部的锁，多轨合成播放中它一忙主线程就排在后面；AVKit 的 Now Playing 走同一把锁。改成读时钟外推的 `estimatedTime`，守卫钉着 App 代码里不许出现 `currentTime()`；第二轮：`AVPlayerView` 自带的控制器也在暂停那一拍问时间（578 ms）且关不掉，预览画面换成裸 `AVPlayerLayer`（`PlayerLayerView`），App 不再 import AVKit。**播放器的 getter 不是免费的；平均值看不见的卡顿要逐次抓；带控制器的便利视图会替你在主线程上做事。**
- [Bugfix 模板](docs/bugfixes/TEMPLATE.md) — 新案例必须使用的结构。

## 根目录文档

- [README.md](README.md) — 面向使用者的中英双语项目介绍。
- [SrtFlow-Requirements.md](SrtFlow-Requirements.md) — 产品需求与技术结论总表。
