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
   一份相互竞争的说明。

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
3. **控制单文件体积。** 新类型或新功能默认按职责开新文件。单文件超过约 800 行即为
   警戒线；改到超标文件时，可顺手拆出职责独立的部分，但不要借题做一次性大重构。
   当前待瘦身：`VideoEditTimelineView.swift`、`VideoEditProject.swift`、
   `VideoEditModels.swift`。

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
| 时间线捏合、滚动、移动、裁切、吸附、框选 | [捏合缩放](docs/architecture/timeline-pinch-zoom.md)、[拖动手势](docs/architecture/timeline-drag-gestures.md)、[拖动卡顿与落点](docs/bugfixes/2026-08-09-timeline-clip-drag-lag-and-alignment.md) |
| 预览变换、叠化、画中画、导出滤镜 | [预览自由变换](docs/architecture/preview-free-transform.md)、[关键帧动画](docs/architecture/keyframe-animation.md)、[Transform 复审](docs/bugfixes/2026-08-04-transform-review.md)、[预渲染复审](docs/bugfixes/2026-08-05-export-prerender-review.md) |
| 工程帧率、关键帧容差 | [工程帧率](docs/architecture/project-frame-rate.md) |
| 音量、dB、渐入渐出、音频滤镜链、audioMix | [声音：音量与渐入渐出](docs/architecture/audio-fades.md) |
| Inspector 数值框、拖调、Transform 写入 | [Inspector 数值框合同](docs/architecture/inspector-scrub-number-field.md) |
| 定格、静帧、图片转视频 | [定格长期约束](docs/architecture/freeze-frame.md)、[定格方案](docs/plans/2026-08-08-freeze-frame.md)、[静帧逐帧解码事故](docs/bugfixes/2026-08-08-still-clip-decode-per-frame.md) |
| 原生录屏、恢复、退出、导入 | [录屏生命周期](docs/architecture/screen-recording-lifecycle.md)（含产物合同）、[实施报告](docs/reports/2026-08-06-native-screen-recording-implementation-report.md)、[Phase 2–4 复审](docs/bugfixes/2026-08-07-screen-recording-phase2-4-review.md)、[静止期尾部黑屏](docs/bugfixes/2026-08-11-screen-recording-idle-tail-black.md)；方案中的旧结论不得覆盖实施报告 |
| 字幕生成、语言检测、翻译、任务取消 | [字幕语言流](docs/architecture/subtitle-language-flow.md)、[原生字幕生成方案](docs/plans/2026-08-06-native-subtitle-generation.md)、[字幕生成复审](docs/bugfixes/2026-08-06-subtitle-generation-review.md)、[PR #22 后续复审](docs/bugfixes/2026-08-09-pr22-review-followups.md) |
| 字幕轨、眼睛、预览叠层、烧录、布局、选择 | [字幕轨可见性与布局](docs/architecture/subtitle-track-visibility-and-layout.md) |
| 轨道块标记、时间线块 overlay、扫帧 peek | [轨道块标记](docs/architecture/clip-markers.md)、[悬停影子播放头](docs/bugfixes/2026-08-08-hover-ghost-playhead-and-delete-key.md) |
| 任何按钮的提示文案、快捷键、hover | [即时提示](docs/architecture/instant-tooltips.md) |
| 任何界面文案、翻译、字符串表、应用内语言切换 | [本地化](docs/architecture/localization.md) |
| 真实窗口、系统权限、手势实测 | [GUI 冒烟流程](docs/testing/gui-smoke-testing.md) |

## 构建与检查入口

- 构建与打包的 Rosetta / arm64 要求、常用命令、打包和验收：
  [docs/build/build-and-packaging.md](docs/build/build-and-packaging.md)。
- 全部自动检查：`scripts/check-all.sh`。CI 在每个 PR 上运行同一入口：
  `.github/workflows/checks.yml`。
- 核心库：`swift run --arch arm64 SrtFlowCoreChecks`。
- 工程存盘与素材重链接、选择模型（点选互斥 / 框选混选）、轨道块标记：
  `scripts/check-project-file.sh`。
- 播放头与悬停 peek 状态机：`scripts/check-player-clock.sh`。
- 预览合成真取帧：`scripts/check-preview-composition.sh`。
- 录屏产物画面轨盖到 T1（尾部不黑）：`scripts/check-screen-recording-writer.sh`。
- 画中画 fill + matte：`scripts/check-export-alpha-compositing.sh`。
- 声音渐入渐出的真实包络（预览 + 导出两条管线）：`scripts/check-audio-fade.sh`。
- 生产导出帧率：`scripts/check-export-frame-rate.sh`；禁止写死帧率扫描：
  `checks/no-hardcoded-fps.sh`。
- 定格时间线变换：`scripts/check-freeze-frame.sh`。
- 按钮提示与快捷键单一来源：`checks/instant-tooltip-wiring.sh`。
- 界面文案在 en / zh-Hans 两张表都配齐、无重复键、占位符一致：
  `scripts/check-localization-coverage.sh`。
- 提示面板的真实落点（摆好之后不许自己变）：`scripts/check-instant-tooltip-panel.sh`。
  **要图形会话，故意不在 `check-all.sh` 里**（无图形会话会假红），改
  `InstantTooltip.swift` 时按 [GUI 冒烟流程](docs/testing/gui-smoke-testing.md) 跑。
- 时间线吸附、框选命中与生产落点：`scripts/check-timeline-snap.sh`；拖动/框选
  接线扫描：`checks/timeline-drag-wiring.sh`。
- 静帧真实编码与边际性能：`scripts/check-still-clip-encode.sh`。
- 翻译配对预检与接线：`scripts/check-translation-preflight.sh`。
- 构建日志不得被吞：`checks/no-swallowed-build-output.sh`。

## 规划与实施报告索引

- [原生录屏方案](docs/plans/2026-08-06-native-screen-recording.md) — 产品目标与阶段方案；
  当前状态以实施报告为准。
- [原生字幕生成方案](docs/plans/2026-08-06-native-subtitle-generation.md) — SpeechAnalyzer、
  Translation、缓存与 macOS 15/26 分层。
- [定格方案](docs/plans/2026-08-08-freeze-frame.md) — 产品参数、提交模型、分辨率政策与
  已知代价。
- [原生录屏实施报告](docs/reports/2026-08-06-native-screen-recording-implementation-report.md) —
  Phase 0–5 的真实进度、实测证据、偏差和未完成项。

## 架构与长期约束索引

- [时间线捏合缩放](docs/architecture/timeline-pinch-zoom.md) — local NSEvent monitor 与失败方案。
- [工程文件与素材重链接](docs/architecture/video-edit-project-file.md) — 格式、定位、脏标记与自动保存。
- [时间线拖动手势](docs/architecture/timeline-drag-gestures.md) — 坐标系、刷新、吸附、唯一落点算法，
  以及框选（相交即选中、混选与「预览最多一套框」、整组一起移动）。
- [预览自由变换](docs/architecture/preview-free-transform.md) — `ClipPlacement` 与预览/导出同账。
- [关键帧动画](docs/architecture/keyframe-animation.md) — 源时间锚定、切片与 fill + matte。
- [工程帧率](docs/architecture/project-frame-rate.md) — 唯一事实来源、容差空间与回归矩阵。
- [声音：音量与渐入渐出](docs/architecture/audio-fades.md) — 唯一夹紧点、转场仲裁、dB 换算、只换 audioMix 的快路径。
- [录屏生命周期](docs/architecture/screen-recording-lifecycle.md) — 状态机、journal、恢复、退出与快照。
- [Inspector 数值框](docs/architecture/inspector-scrub-number-field.md) — 写入、取消、焦点与光标合同。
- [定格](docs/architecture/freeze-frame.md) — 一次性提交、PNG 归属、波纹范围与静帧管线。
- [字幕语言流](docs/architecture/subtitle-language-flow.md) — 目标语言可见性、预检与自动检测。
- [字幕轨可见性与布局](docs/architecture/subtitle-track-visibility-and-layout.md) — 一语言一轨、布局与选择互斥。
- [轨道块标记](docs/architecture/clip-markers.md) — 源时间锚定、四类选择互斥与命中区分层。
- [即时提示](docs/architecture/instant-tooltips.md) — 不许用系统 `.help`、快捷键单一来源、面板四条硬约束。
- [本地化](docs/architecture/localization.md) — 写死的文案必须两张表都有、L10n 与 Text 的分工、lproj 小写坑与已知盲区。

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
- [2026-08-12 渐入开头爆音](docs/bugfixes/2026-08-12-audio-fade-in-pop.md) — 混音器的增益 de-zipper、峰值 vs RMS、场景全落在默认值上的守卫盲区。
- [2026-08-12 提示弹在很远的地方、还没翻译](docs/bugfixes/2026-08-12-instant-tooltip-first-show-far-off.md) — NSHostingView 把尺寸约束灌给面板窗口、摆好≠摆定、本地化查不到是静默降级。
- [Bugfix 模板](docs/bugfixes/TEMPLATE.md) — 新案例必须使用的结构。

## 根目录文档

- [README.md](README.md) — 面向使用者的中英双语项目介绍。
- [SrtFlow-Requirements.md](SrtFlow-Requirements.md) — 产品需求与技术结论总表。
