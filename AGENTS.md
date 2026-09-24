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

### 语言

- GitHub 对外可见文字一律使用英文：commit message、分支名、PR、issue、release，
  以及 Actions 的 workflow、job、step 名称与正文。
- `README.md` 保持中英双语；仓库内部 `docs/`、本文件和代码注释维持现状使用中文。

### 工程原则

1. **轻量化优先。** 优先复用 macOS 原生能力（AVFoundation、AppKit、SwiftUI），
   不随意引入第三方依赖。需要自写合成器、自建文件管理等重量级方案时，先征得用户
   同意。既有产品决策：文件管理交给 Finder；混合模式不为此自建 Metal 合成器。
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
| 工程存盘、格式版本、素材路径、自动保存 | [工程文件与素材重链接](docs/architecture/video-edit-project-file.md)、[工程生命周期事故](docs/bugfixes/2026-08-03-project-file-lifecycle.md)、[运行期素材重链接](docs/bugfixes/2026-08-08-runtime-media-relink.md) |
| 时间线捏合、滚动、移动、裁切、吸附、框选、点击落点、扫帧预览 | [捏合缩放](docs/architecture/timeline-pinch-zoom.md)、[拖动手势](docs/architecture/timeline-drag-gestures.md)、[拖动卡顿与落点](docs/bugfixes/2026-08-09-timeline-clip-drag-lag-and-alignment.md) 、[拖文件进轨道](docs/plans/2026-09-22-media-file-drop.md) |
| 插进两条轨之间（缝拉开）、整条轨上下换位置、轨道头的拖动（换位 / 下边缘调行高） | [插入缝与整轨换位方案](docs/plans/2026-09-24-track-insert-and-reorder.md)、[拖动手势](docs/architecture/timeline-drag-gestures.md)（§5h 插入缝、§5i 整轨换位）、[视频轨对等化](docs/architecture/video-tracks.md)（轨道头这一列）、[预览性能 ratchet](docs/architecture/preview-perf-ratchet.md)（轨道头的行每跳不重算，别往它的输入里塞闭包） |
| 编辑器分栏、预览区/时间线的行结构与最小高度 | [播放条压到工具栏上](docs/bugfixes/2026-08-12-preview-transport-row-overlap.md) |
| 预览变换、叠化、上层视频轨、导出滤镜 | [预览自由变换](docs/architecture/preview-free-transform.md)、[视频轨对等化](docs/architecture/video-tracks.md)、[关键帧动画](docs/architecture/keyframe-animation.md)、[Transform 复审](docs/bugfixes/2026-08-04-transform-review.md)、[预渲染复审](docs/bugfixes/2026-08-05-export-prerender-review.md) |
| 从 Finder 拖文件 / ⌘V 粘贴文件进时间线、导入落点 | [拖文件进轨道](docs/plans/2026-09-22-media-file-drop.md)、[卡片被文件落点吞了](docs/bugfixes/2026-09-23-in-app-drops-swallowed-by-file-underlay.md)、[外部拖入被内层落点独占](docs/bugfixes/2026-09-23-timeline-file-drop-claimed-by-inner-drop-region.md)（结论已更正）、[拖动手势](docs/architecture/timeline-drag-gestures.md)（主轨保序、§5e-2 唯一落点）、[视频轨对等化](docs/architecture/video-tracks.md) |
| 时间线上的任何拖放落点（`.onDrop`：文件 / 滤镜 / 音频库 / 转场卡片）、新的自定义拖放 / 剪贴板类型 | [拖动手势 §5e-2](docs/architecture/timeline-drag-gestures.md)（整条时间线只许一个 `.onDrop`；自定义类型必须在 Info.plist 声明；不能放回 `.forbidden` 不回 `.cancel`）、[转场拖放被 `.cancel` 取消](docs/bugfixes/2026-09-23-transition-drop-cancel-ends-session.md)、[卡片被文件落点吞了](docs/bugfixes/2026-09-23-in-app-drops-swallowed-by-file-underlay.md)、[自定义类型没声明](docs/bugfixes/2026-09-23-custom-drag-types-not-declared.md)、[GUI 冒烟流程](docs/testing/gui-smoke-testing.md)（落点路由探针） |
| 轨道模型、时间线行结构、轨道行高、轨道配色、预览点选 | [视频轨对等化](docs/architecture/video-tracks.md)、[工程文件与素材重链接](docs/architecture/video-edit-project-file.md) |
| 段的显隐（V / 眼睛）、隐藏段进不进预览和成片 | [段的显隐](docs/architecture/clip-visibility.md)、[视频轨对等化](docs/architecture/video-tracks.md) |
| 画面渐入渐出、alpha 斜坡、转场仲裁 | [画面渐入渐出](docs/architecture/video-fades.md)、[声音：音量与渐入渐出](docs/architecture/audio-fades.md) |
| 主轨转场的容量、可用判定、借余料、首尾帧定格补足 | [主轨转场：借余料与定格补足](docs/architecture/transition-handles.md)、[转场预览有、成片没有](docs/bugfixes/2026-09-20-transition-preview-export-divergence.md) |
| 画面段的入场/出场动画、预设效果、预渲染路由 | [画面段的入场 / 出场动画](docs/architecture/clip-animation.md)、[画面渐入渐出](docs/architecture/video-fades.md)、[关键帧动画](docs/architecture/keyframe-animation.md) |
| 画面文字、字体、Core Text 渲染、文字动画、逐帧导出、预览上文字的选中框和可点范围 | [画面文字](docs/architecture/text-overlays.md)（把手的可点范围写在 `.offset` 之前；没选中的字只认看得见的部分）、[拖字变成旋转](docs/bugfixes/2026-09-24-text-rotate-handle-hit-area-at-center.md) |
| 滤镜调色、LUT、预览图层滤镜、导出 `lut3d` 段 | [滤镜](docs/architecture/filters.md) |
| 工程帧率、关键帧容差 | [工程帧率](docs/architecture/project-frame-rate.md) |
| 音量、dB、渐入渐出、audioMix | [声音：音量与渐入渐出](docs/architecture/audio-fades.md)、[成片的声音](docs/architecture/export-audio-mixdown.md) |
| 声音场景（喇叭 / 室内 / 室外）、tap 里的效果单元、余音越过段尾、检查器的声音那一块 | [声音场景](docs/architecture/sound-scenes.md)（挂了场景的轨段增益在 tap 里乘；最后一段后面垫载体；有没有场景是合成结构）、[推子与电平表](docs/architecture/audio-mixer.md)、[成片的声音](docs/architecture/export-audio-mixdown.md)、[声音场景方案](docs/plans/2026-09-24-sound-scenes.md) |
| 导出的声音、离线混音（`ExportAudioMixdown`）、导出图里接音轨的地方 | [成片的声音](docs/architecture/export-audio-mixdown.md)（导出图里不许有声音滤镜；成片 = 预览那份混音）、[阻塞的媒体读取](docs/architecture/blocking-media-reads.md)、[转场那条缝上预览的声音掉下去](docs/bugfixes/2026-09-24-preview-mix-ignores-transition-expansion.md) |
| 波形显示、深度缩放（缩放上限、标尺刻度、缩略图、超宽内容的绘制） | [波形与深度缩放](docs/architecture/audio-waveform.md)、[捏合缩放](docs/architecture/timeline-pinch-zoom.md)、[拖动手势](docs/architecture/timeline-drag-gestures.md) §5、[阻塞的媒体读取](docs/architecture/blocking-media-reads.md) |
| `AVAssetReader` 读采样（`copyNextSampleBuffer`），以及在 async 函数 / `Task` 里做任何会卡住线程的事（等信号量、同步 IO、等子进程） | [阻塞的媒体读取](docs/architecture/blocking-media-reads.md)、[缩略图和波形全空](docs/bugfixes/2026-09-23-waveform-decode-deadlocks-thread-pool.md) |
| 音量曲线（段上的音量自动化）、轨道推子 / 总推子、电平表、预览合成里声音怎么排到合成音轨上 | [音量曲线](docs/architecture/audio-volume-curve.md)、[推子与电平表](docs/architecture/audio-mixer.md)（第三节第 7 条：一条合成音轨只装一种源格式）、[声音：音量与渐入渐出](docs/architecture/audio-fades.md)、[声音编辑方案](docs/plans/2026-09-23-audio-mixing.md)、[一条轨上换了音频格式](docs/bugfixes/2026-09-23-meter-tap-dies-on-audio-format-change.md) |
| Inspector 数值框、拖调、Transform 写入、检查器里的滑杆行（`labelledSlider` / `InspectorSliderRow`，右边的数值框能打字）、「Shows for」 | [Inspector 数值框合同](docs/architecture/inspector-scrub-number-field.md)（滑杆行的数值框：打字提交要立刻 `endLiveEdit`） |
| 往检查器里加任何一行（标题 + 控件、下拉、滑杆行） | [检查器的排版](docs/architecture/inspector-layout.md)（固定窄栏，一行不许比它宽；菜单 Picker 不许 `.fixedSize()`）、[声音场景那一行把检查器撑宽](docs/bugfixes/2026-09-24-sound-scene-row-widens-inspector.md) |
| 定格、静帧、图片转视频 | [定格长期约束](docs/architecture/freeze-frame.md)、[定格方案](docs/plans/2026-08-08-freeze-frame.md)、[静帧逐帧解码事故](docs/bugfixes/2026-08-08-still-clip-decode-per-frame.md) |
| 原生录屏、恢复、退出、导入 | [录屏生命周期](docs/architecture/screen-recording-lifecycle.md)（含产物合同）、[实施报告](docs/reports/2026-08-06-native-screen-recording-implementation-report.md)、[Phase 2–4 复审](docs/bugfixes/2026-08-07-screen-recording-phase2-4-review.md)、[静止期尾部黑屏](docs/bugfixes/2026-08-11-screen-recording-idle-tail-black.md)；方案中的旧结论不得覆盖实施报告 |
| 字幕生成、语言检测、翻译、任务取消 | [字幕语言流](docs/architecture/subtitle-language-flow.md)、[原生字幕生成方案](docs/plans/2026-08-06-native-subtitle-generation.md)、[字幕生成复审](docs/bugfixes/2026-08-06-subtitle-generation-review.md)、[PR #22 后续复审](docs/bugfixes/2026-08-09-pr22-review-followups.md) |
| 字幕轨、眼睛、预览叠层、烧录、布局、选择、字幕的三个编辑入口 | [字幕轨可见性与布局](docs/architecture/subtitle-track-visibility-and-layout.md) |
| 轨道块标记、时间线块 overlay、扫帧 peek | [轨道块标记](docs/architecture/clip-markers.md)（单击只选中、双击才弹面板：点一下就弹带输入框的面板 = 交出键盘）、[悬停影子播放头](docs/bugfixes/2026-08-08-hover-ghost-playhead-and-delete-key.md)、[标记 ⌫ 删不掉](docs/bugfixes/2026-09-24-marker-delete-key-eaten-by-note-field.md) |
| 音频库（音乐 / 音效）、manifest、试听、素材缓存、署名 | [音频库](docs/plans/2026-09-22-audio-library.md)、[素材管线](docs/build/audio-library-pipeline.md)、[声音：音量与渐入渐出](docs/architecture/audio-fades.md)（ducking 的夹紧点） |
| 导出面板、编码设置、分辨率档位（压缩 / 烧录 / 剪辑导出）、导出文件名与撞名 | [导出设置](docs/architecture/export-settings.md)（面板上只放管线真消费的设置）、[导出面板改版方案](docs/plans/2026-09-24-export-panel.md)、[竖屏被缩小](docs/bugfixes/2026-09-24-resolution-cap-shrinks-portrait-video.md)、[音频原样复制是假话](docs/bugfixes/2026-09-24-export-panel-promised-audio-copy.md) |
| 任何按钮的提示文案、快捷键、hover | [即时提示](docs/architecture/instant-tooltips.md) |
| 预览性能、性能计数与基线；**新写或改写任何 SwiftUI 视图 / 修饰器 / `NSViewRepresentable` / Canvas**（body 第一行要计数，写完跑 `checks/preview-perf-wiring.sh --fix` 自动补）；性能那一步红了但没动编辑器界面；**往时间线上加一种块 / 行里的列表项** | [预览性能 ratchet](docs/architecture/preview-perf-ratchet.md)（计数必须接满、只许降、**已知的偶发误报怎么认、怎么重跑**、什么时候能重定基线、**时间线上的块不订阅工程、按值比较 + `.equatable()`**）、[预览性能 ratchet 方案](docs/plans/2026-09-24-preview-perf-ratchet.md)、[每个块都订阅着整个工程](docs/bugfixes/2026-09-24-timeline-blocks-observe-whole-project.md) |
| 任何界面文案、翻译、字符串表、应用内语言切换，新加 sheet / popover / 自建宿主视图 | [本地化](docs/architecture/localization.md)（第三节第 3 条：sheet / popover 不继承应用内语言）、[sheet 全是英文](docs/bugfixes/2026-09-24-sheets-ignore-in-app-language.md)、[守卫不扫 LabeledContent](docs/bugfixes/2026-09-24-labeledcontent-missing-from-localization-guard.md) |
| 真实窗口、系统权限、手势实测 | [GUI 冒烟流程](docs/testing/gui-smoke-testing.md) |

## 构建与检查入口

- 构建与打包的 Rosetta / arm64 要求、常用命令、打包和验收：
  [docs/build/build-and-packaging.md](docs/build/build-and-packaging.md)。
- 音频库素材的制备与上传（选曲 → 规格化 → manifest → R2）：
  [docs/build/audio-library-pipeline.md](docs/build/audio-library-pipeline.md)。
  脚本在 `scripts/audio-library/`，**不在 `check-all.sh` 里**（它制备素材，不是检查）。
- 全部自动检查：`scripts/check-all.sh`。CI 在每个 PR 上运行同一入口：
  `.github/workflows/checks.yml`，按 `--shard N --of 5` 分到 5 台免费的 macOS runner 上并行跑，
  由一个叫 `check-all` 的汇总 job 给结论（分组、组数校验、汇总 job 为什么不能被跳过，见
  [构建与打包「CI」一节](docs/build/build-and-packaging.md)）。新加检查要放进某个 `shard`。
- 核心库：`swift run --arch arm64 SrtFlowCoreChecks`。
- 工程存盘与素材重链接、选择模型（点选互斥 / 框选混选）、轨道块标记：
  `scripts/check-project-file.sh`。
- 播放头与悬停 peek 状态机：`scripts/check-player-clock.sh`。
- 预览合成真取帧：`scripts/check-preview-composition.sh`。
- 录屏产物画面轨盖到 T1（尾部不黑）：`scripts/check-screen-recording-writer.sh`。
- 上层视频轨动画段 fill + matte：`scripts/check-export-alpha-compositing.sh`。
- 入场/出场动画的两条管线对账（预览取帧 vs 真导出抽帧）：`scripts/check-clip-animation.sh`。
- 上层视频轨铺满 + 画面渐变的真产物（真跑导出再抽帧）：
  `scripts/check-video-fade.sh`。
- 检查器的 live 绑定只准接滑块和 scrub（离散控件没有结束信号，快照会挂着把
  下一次改动抹掉）：`checks/inspector-live-binding-wiring.sh`。
- 画面文字：渲染图与成片**逐点重合**（同一个渲染函数是这套东西的全部前提），
  以及动画的「模型给多少、成片就是多少」、预览上的可点范围：`scripts/check-text-render.sh`。
- `.contentShape` 不许写在 `.offset` / `.rotationEffect` / `.scaleEffect` 之后（几何效果只挪画面、
  不挪布局框，可点范围会留在原位）：`checks/hit-shape-before-offset.sh`。
- 滤镜调色：LUT 数学（强度那条等式）、层号规则，以及**预览与成片逐像素比对**
  （配方 ↔ CoreImage ↔ 真跑 ffmpeg）：`scripts/check-filters.sh`。
- 滤镜挂到播放器上这段接线（拍窗口数像素）：`scripts/check-filter-preview-attach.sh`。
  **要图形会话，故意不在 `check-all.sh` 里**，改 `VideoEditFilterPreview.swift`
  时按 [GUI 冒烟流程](docs/testing/gui-smoke-testing.md) 跑。
- 声音渐入渐出、音量曲线与推子的真实包络（预览 + 导出两条管线），以及电平表（离线读挂了
  tap 的真实混音，对账轨道表 / 总表 / 红灯）：`scripts/check-audio-fade.sh`。
- 波形数据（多级峰值、原始采样块）逐采样对账，以及**很多文件同时读**必须全部读完、
  不许把线程池堵死（看门狗判红）：`scripts/check-waveform.sh`。
- 成片的声音只有一条管线（导出图里不许出现声音滤镜，混音读的是预览那份合成 + audioMix，
  变速的保音调算法是同一个常量）：`checks/export-audio-single-pipeline.sh`。
- 读采样的阻塞循环（`copyNextSampleBuffer`）不许写在 async 函数里（会占住 Swift 并发
  线程池的线程，文件一多整档 QoS 死锁）：`checks/blocking-media-reads.sh`。
- 生产导出帧率与分辨率（真跑导出：数帧、读成片尺寸 —— 只降不升、按短边、像素是方的）：
  `scripts/check-export-frame-rate.sh`；禁止写死帧率扫描：
  `checks/no-hardcoded-fps.sh`。
- 定格时间线变换：`scripts/check-freeze-frame.sh`。
- 按钮提示与快捷键单一来源：`checks/instant-tooltip-wiring.sh`。
- 检查器里的菜单 Picker 不许锁死宽度（锁了会把整列撑宽、右边被裁）：`checks/inspector-fits-width.sh`。
- 字幕编辑期间全局快捷键让路（⌫ 不删正在编辑的 cue）：
  `checks/subtitle-editing-wiring.sh`。
- 界面文案在 en / zh-Hans 两张表都配齐、无重复键、占位符一致：
  `scripts/check-localization-coverage.sh`。
- 提示面板的真实落点（摆好之后不许自己变）：`scripts/check-instant-tooltip-panel.sh`。
  **要图形会话，故意不在 `check-all.sh` 里**（无图形会话会假红），改
  `InstantTooltip.swift` 时按 [GUI 冒烟流程](docs/testing/gui-smoke-testing.md) 跑。
- 时间线吸附、框选命中与生产落点：`scripts/check-timeline-snap.sh`；拖动/框选
  接线扫描：`checks/timeline-drag-wiring.sh`。
- **进程内 GUI 冒烟**（人在用这台机器时也能跑：不动鼠标、不抢前台，按步骤表点 / 拖 / 滚 / 按键，
  结果里带选择、各段位置和每个视图重算了几次）：`scripts/gui-smoke/in-process/run.sh <步骤.json> [工程拷贝]`。
  **要图形会话，不在 `check-all.sh` 里**；格式与坑见 [GUI 冒烟流程](docs/testing/gui-smoke-testing.md)「四之六」。
- 跨 App 的文件拖放重放（自带拖源，Finder 不吃合成事件）：
  `scripts/gui-smoke/external-file-drag/replay.sh`。**要图形会话，故意不在
  `check-all.sh` 里**，按 [GUI 冒烟流程](docs/testing/gui-smoke-testing.md) 跑。
- SwiftUI 落点路由探针（每格一种 `.onDrop` 组合，回调全记日志；改时间线的落点结构
  之前先在这儿测）：`scripts/gui-smoke/drop-routing-probe/probe.sh`。同样要图形会话、
  不在 `check-all.sh` 里。
- 从 Finder 拖文件进轨道的落点（撞上就抬一轨、多文件接龙、隐藏轨跳过、落地后
  主轨仍按时间排序）：`scripts/check-media-import.sh`；接线扫描（含「整条时间线
  只许一个 `.onDrop`」）在 `checks/timeline-drag-wiring.sh` 里。
- 静帧真实编码与边际性能：`scripts/check-still-clip-encode.sh`。
- 翻译配对预检与接线：`scripts/check-translation-preflight.sh`。
- 音频库清单：解析的宽容边界（不认识的字段忍、单条坏数据跳过、**版本号更高整份
  拒绝**）与双语搜索（中英都能命中同一个 tag、多词是「与」）：
  `scripts/check-audio-library.sh`。
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
  跑 `checks/preview-perf-wiring.sh --fix` 自动补上。同一个守卫最后一节钉着**时间线上的块不许
  订阅工程、必须 `Equatable` 且构造处套 `.equatable()`**。
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
- [原生录屏实施报告](docs/reports/2026-08-06-native-screen-recording-implementation-report.md) —
  Phase 0–5 的真实进度、实测证据、偏差和未完成项。

## 架构与长期约束索引

- [写代码的规范](docs/architecture/coding-standards.md) — 模块化的六条（一个文件一件事、抽有名字的顶层类型、
  别开只有 extension 的文件、纯计算和副作用分开、同一规则只有一处实现、函数别太长），单文件目标 400 / 上限 600
  行与老文件只许降的基线、审查清单。
- [时间线捏合缩放](docs/architecture/timeline-pinch-zoom.md) — local NSEvent monitor 与失败方案。
- [工程文件与素材重链接](docs/architecture/video-edit-project-file.md) — 格式、定位、脏标记与自动保存。
- [时间线拖动手势](docs/architecture/timeline-drag-gestures.md) — 坐标系、刷新、吸附、唯一落点算法，
  框选（相交即选中、混选与「预览最多一套框」、整组一起移动），以及命中区必须盖在填满视口
  之后、点非素材处移播放头、扫帧 peek 的唯一所有者、**整条时间线只许一个拖放落点**（§5e-2），
  插入缝（停 0.2 秒拉开、行的位置一份纯值、纵向按指针判，§5h）与整条轨换位（§5i）。
- [预览自由变换](docs/architecture/preview-free-transform.md) — `ClipPlacement` 与预览/导出同账。
- [关键帧动画](docs/architecture/keyframe-animation.md) — 源时间锚定、切片与 fill + matte。
- [工程帧率](docs/architecture/project-frame-rate.md) — 唯一事实来源、容差空间与回归矩阵。
- [声音：音量与渐入渐出](docs/architecture/audio-fades.md) — 唯一夹紧点、转场仲裁、dB 换算、只换 audioMix 的快路径。
- [声音场景](docs/architecture/sound-scenes.md) — 九个场景的模型与 v20、效果跑在 tap 里（预览和成片同一份）、挂了场景的轨段增益在 tap 里乘（效果在段增益之后、推子之前）、每段一条效果链各自散余音、最后一段后面垫同一素材当余音的载体、seek 复位、不载入出厂预设、喇叭类先削波后限带、响度补偿用同一串处理量（渲染前记输入）、回归与人工清单。
- [成片的声音](docs/architecture/export-audio-mixdown.md) — 成片的声音就是预览那份混音离线读出来的（导出图里不许有声音滤镜）、读用户那一份状态（展开只许一次）、正好画面那么长、f32 中间文件、`MediaReadQueue.export`、和以前的成片比变了什么（单声道响 3 dB、变速换成预览的算法）。
- [音量曲线](docs/architecture/audio-volume-curve.md) — 曲线属于段（dB、锚源时间、有点时取代 `volume`）、编辑动作本身不改声音、两条管线同一张折线表、导出 `aeval` 平衡树的六条实测约束（放在 `adelay` 之前并减掉首帧定格、最右叶子必须是常数、全精度数字、超大图走文件）。
- [波形与深度缩放](docs/architecture/audio-waveform.md) — 一个文件读一次的三层精度（多级峰值 / 按需原始采样块 / 顶替）、粗级是 min/max 不是平均、画「听到的声音」且爆音涂红、**Canvas 只画 `clipBoundingRect`**（超宽内容的实测地基）。
- [推子与电平表](docs/architecture/audio-mixer.md) — 三级增益一条账（段 × 渐变 × 轨道推子 × 总推子）、推子是常数直接乘进每一段、只动推子走快路径；电平表的七条实测约束（tap 看不到音量要自己乘同一张增益表、**tap 必须跟着合成活否则换 mix 卡 0.6 秒**、按绝对位置累加、提前 280ms、过滤空转回调、**一条合成音轨只装一种源格式否则 tap 死掉、那条轨没声音、播放器可能不走**）。
- [画面渐入渐出](docs/architecture/video-fades.md) — 渐变露出的是下一层、alpha 斜坡两条管线同账、与声音共用的夹紧规则。
- [主轨转场：借余料与定格补足](docs/architecture/transition-handles.md) — 不挪用户片段、三种几何与容量、余料不够用首尾帧定格补足（2026-09-23 拍板）、定格字段只在渲染副本里且只许展开函数写、两条管线怎么做定格。
- [画面段的入场 / 出场动画](docs/architecture/clip-animation.md) — 五种效果都落在三种斜坡上、效果与画面渐变共用一个槽（老工程零迁移）、铺满画布不露边的补偿、逐帧效果走预渲染的代价。
- [视频轨对等化](docs/architecture/video-tracks.md) — 取消画中画、一轨一色、⌥ 点击穿透、轨道头这一列的动作（按住拖 = 整条轨换位置、拖下边缘 = 调行高），以及尚未对齐的两项。
- [画面文字](docs/architecture/text-overlays.md) — 唯一的绘制入口、1080p 基准、版面框即定位框、包络位图、把手的三种数学、九种动画与「只逐帧渲动画段」、数字元件（等宽自己排，苹方没实现字体特性）。
- [滤镜](docs/architecture/filters.md) — 时间轴上的调色段、层号进模型（LUT 不可交换）、强度=表的线性插值、预览挂图层滤镜的实测地基（backgroundFilters 会污染整个窗口）、两条管线的四条对齐约束。
- [录屏生命周期](docs/architecture/screen-recording-lifecycle.md) — 状态机、journal、恢复、退出与快照。
- [Inspector 数值框](docs/architecture/inspector-scrub-number-field.md) — 写入、取消、焦点与光标合同。
- [检查器的排版](docs/architecture/inspector-layout.md) — 固定的窄栏（约 220pt）：一行的最小宽度不许超过它，否则整列被撑宽、右边被裁；菜单 Picker 不许锁宽度；长名字的下拉标题单独一行。
- [定格](docs/architecture/freeze-frame.md) — 一次性提交、PNG 归属、波纹范围与静帧管线。
- [字幕语言流](docs/architecture/subtitle-language-flow.md) — 目标语言可见性、预检与自动检测。
- [字幕轨可见性与布局](docs/architecture/subtitle-track-visibility-and-layout.md) — 一语言一轨、布局、选择模型（点选互斥 / 框选混选），以及三个编辑入口共用的合同。
- [轨道块标记](docs/architecture/clip-markers.md) — 源时间锚定、标记对所有选择互斥、命中区分层。
- [即时提示](docs/architecture/instant-tooltips.md) — 不许用系统 `.help`、快捷键单一来源、面板四条硬约束。
- [本地化](docs/architecture/localization.md) — 写死的文案必须两张表都有、L10n 与 Text 的分工、lproj 小写坑、**sheet / popover 不继承应用内语言**与已知盲区。
- [阻塞的媒体读取](docs/architecture/blocking-media-reads.md) — `copyNextSampleBuffer` 这类会卡住线程的读取不许进 Swift 并发的线程池（同一档 QoS 上卡满核数就整档死锁）、`MediaReadQueue` 的两种用法与宽度、唯一的例外（字幕生成逐窗口读）、什么样的阻塞会死锁。
- [预览性能 ratchet](docs/architecture/preview-perf-ratchet.md) — 量的是活不是 CPU、**每个视图 body
  第一行计数**（守卫钉着，`--fix` 自动补）、时钟连跳走真播放的入口、合成负载当 GPU 代理数字、要有两遍
  一模一样、计数逐项相等（进步必须登记）、基线只许降（抬基线的 PR 不许动产品代码）、**已知的偶发误报**
  （检查器数值框和时间线缩放桥接多一轮 → 重跑）、盲区、**时间线上的块不订阅工程、按值比较**（守卫钉着）。
- [导出设置](docs/architecture/export-settings.md) — 分辨率档位封的是**短边**（竖屏 1080×1920 的 1080p 就是它本身）、只降不升、各管线在哪一步缩；**面板上只放这条管线真消费的设置**（按管线声明，不按控件加开关）；标题→文件名只有一个函数、导出位置的记忆链、视频和字幕文件同一条撞名规则、记住与恢复默认，以及人工回归清单。

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
- [2026-09-24 预览里想拖文字，一按下去变成旋转](docs/bugfixes/2026-09-24-text-rotate-handle-hit-area-at-center.md) — 旋转把手的 `contentShape` 写在 `.offset` 之后，可点的圆留在字的正中心（看不见的 22pt 旋转区），黄点本身反倒点不动；顺带把没选中的字的可点范围从 80% 宽的整框收到看得见的部分。单行样本放过了写反的 y 轴翻转 —— 反向验证时才发现，补了不对称的样本。
- [Bugfix 模板](docs/bugfixes/TEMPLATE.md) — 新案例必须使用的结构。

## 根目录文档

- [README.md](README.md) — 面向使用者的中英双语项目介绍。
- [SrtFlow-Requirements.md](SrtFlow-Requirements.md) — 产品需求与技术结论总表。
