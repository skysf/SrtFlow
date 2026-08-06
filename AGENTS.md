# AGENTS.md — 文档索引与协作规则

给 AI 代理与新贡献者的导航页。**本文件只做目录和规则，不写细节**；细节按分类
放在 `docs/` 下。

## 规则（所有 AI / 贡献者必须遵守）

1. **修复任何 bug 后，必须在 `docs/bugfixes/` 写一份案例**（按
   [TEMPLATE.md](docs/bugfixes/TEMPLATE.md)：症状 → 根因 → 修复 → 验证 → 教训），
   文件名 `YYYY-MM-DD-<slug>.md`，并在下方索引里补一行。
2. 案例中沉淀出的**长期约束**（"这里只能这样做"）单独落到 `docs/architecture/`，
   案例里链接过去，避免只存在于一次性记录中。
3. 新增其他文档归入 `docs/` 对应分类目录，并回本文件补一行索引。

## 全局工程原则（动手写代码前先过一遍）

1. **轻量化优先。** 能白嫖 macOS 现成能力（AVFoundation / AppKit / SwiftUI）
   就不自建，不引第三方依赖；同一个功能有重量级和轻量级两种做法时选轻的，
   重量级方案（自写合成器、自建文件管理这类）必须先问用户。先例：混合模式
   因为要自写 Metal 合成器被否、工程的文件管理整个交给 Finder。
2. **复用优先，抽象克制。** 同一个模式出现**第二次**就抽成共享组件，按仓库
   现有先例的粒度来（`ResizableFrameBox` 同时服务剪辑和形状、
   `LenientCodableEnum` 统一宽容解码、`liveApply`/`perform` 统一改动入口）；
   但别为想象中的将来提前造泛型 —— 有真实的第二个用例再抽象，泛型只用在
   真正多类型复用的地方（提前抽象既违背轻量化，堆多了还会拖垮 Swift 类型
   检查）。
3. **单文件别养大。** 新类型/新功能默认开新文件（按职责命名，先例：
   `VideoEditPreviewTransform.swift`）；单文件超过 **~800 行**就是警戒线，
   新代码别再往超标文件里堆，改到超标文件时顺手把职责独立的块拆出去。
   **不要**为拆而拆地搞一次性大重构。当前超标待瘦身：
   `VideoEditTimelineView`、`VideoEditProject`、`VideoEditModels`。

## 构建（docs/build/）

- [build-and-packaging.md](docs/build/build-and-packaging.md) —
  ⚠️ Rosetta 终端必须 `swift build --arch arm64`、常用命令、打包脚本、产物验收清单

## 测试（docs/testing/）

- [gui-smoke-testing.md](docs/testing/gui-smoke-testing.md) —
  真实窗口冒烟测试全流程：改名启动避同名进程、按窗口 ID 截图、事件注入边界、
  `SRTFLOW_SMOKE_VIDEO` / `SRTFLOW_FFMPEG` 环境变量钩子

自检命令：`swift run SrtFlowCoreChecks`（核心库）、
`scripts/check-project-file.sh`（工程存盘与素材重链接，源码在 `checks/ProjectFile/`）、
`scripts/check-preview-composition.sh`（预览合成的叠化×变换模型，真取帧量像素，
源码在 `checks/PreviewComposition/`）、
`scripts/check-export-alpha-compositing.sh`（导出画中画动画的 fill+matte 合成，
真跑一遍项目自带 ffmpeg 量输出像素，纯 shell 不依赖 Swift 编译）

## 规划（docs/plans/）

- [2026-08-06-native-subtitle-generation.md](docs/plans/2026-08-06-native-subtitle-generation.md) —
  原生字幕生成（SpeechAnalyzer 转写 + Translation 翻译、canonical 原文 +
  companion 译文轨、按需 formatVersion v4、sidecar 词级缓存）：**主体已实现**
  （2026-08-06，含端到端冒烟），构建基线不动（tools 5.9 / .v14），能力按
  macOS 14/15/26 分层；改这块前必读，剩余实机验证项见其 17.2/17.3

## 架构与实现决策（docs/architecture/）

- [timeline-pinch-zoom.md](docs/architecture/timeline-pinch-zoom.md) —
  时间线捏合缩放为什么只能用 local NSEvent monitor（含全部失败方案与回归清单）；
  **改时间线手势/滚动代码前必读**
- [video-edit-project-file.md](docs/architecture/video-edit-project-file.md) —
  `.srtflowproj` 工程格式、为什么不做 App 内文件夹管理、素材重链接的四层线索、
  脏标记与自动保存的唯一入口；**改工程存盘/素材路径/自动保存前必读**
- [timeline-drag-gestures.md](docs/architecture/timeline-drag-gestures.md) —
  块布局原点恒为 0、边缘把手手势必须 `.global` 坐标系（反馈回路）、拖动中的
  动画豁免与异步缩略图去抖；**给时间线加把手/改拖动手势前必读**
- [preview-free-transform.md](docs/architecture/preview-free-transform.md) —
  预览区变换框与 `ClipPlacement`：归一化摆放、九宫格互斥、预览/导出两条管线
  同账（导出用 overlay 不用 pad）；**改预览合成/导出滤镜图/变换框前必读**
- [keyframe-animation.md](docs/architecture/keyframe-animation.md) —
  关键帧动画：源时间锚定（变速/分割自动正确）、切片规则（旋转 ≤6°/片）、
  导出走 AVFoundation 预渲染 + 画中画 fill+matte；**改动画/预渲染前必读**
- [inspector-scrub-number-field.md](docs/architecture/inspector-scrub-number-field.md) —
  Inspector 数值框：离散/live 两条写入路径、拖调取消收尾、拒绝自动聚焦、
  cursor rect 局部光标；**改数值框/拖调/Transform 写入入口前必读**

## Bug 修复案例（docs/bugfixes/）

- [2026-08-03-trackpad-pinch-zoom.md](docs/bugfixes/2026-08-03-trackpad-pinch-zoom.md) —
  触控板捏合缩放反复"修好"又失败：事件序列锁定 + Rosetta 旧二进制两个根因
- [2026-08-03-project-file-lifecycle.md](docs/bugfixes/2026-08-03-project-file-lifecycle.md) —
  工程文件首版的 11 处数据丢失路径：书签被自动保存抹掉、切工程/退出不看写盘
  成败、导入竞态、静帧静默丢失等；教训是生命周期边界要逐条过失败分支
- [2026-08-03-scrub-preview-keyframe-snap.md](docs/bugfixes/2026-08-03-scrub-preview-keyframe-snap.md) —
  拖播放头/悬停扫块时预览不逐帧刷新：不带 tolerance 的 seek 是无穷容差吸关键帧；
  修成零容差 + 链式 seek（QA1820）防洪
- [2026-08-03-trim-flicker-halved.md](docs/bugfixes/2026-08-03-trim-flicker-halved.md) —
  裁切块闪烁卡顿 + 裁切量恰好半速：把手 .local 坐标系随裁切自移形成反馈回路；
  另修动画豁免与缩略图/波形去抖
- [2026-08-04-editor-tools-review.md](docs/bugfixes/2026-08-04-editor-tools-review.md) —
  评审返工三连：工具模式要整个关掉旧手势（GestureMask 不是 guard 回调）、
  画中画升主轨要丢 placement、线条选中框要按旋转后包络
- [2026-08-04-opacity-green-background.md](docs/bugfixes/2026-08-04-opacity-green-background.md) —
  半透明图层让预览背景变暗绿：默认合成器混合路径不铺 backgroundColor
  （YUV 零填充=绿），修法是垫一条 AVAssetWriter 生成的不透明黑底轨
- [2026-08-04-transform-review.md](docs/bugfixes/2026-08-04-transform-review.md) —
  Transform 评审返工三连：加字段必须升 formatVersion（旧版拒开胜过静默毁字段）、
  叠化「垫底=精确」的前提被变换破坏、缓存文件要「临时名→校验→原子替换」
- [2026-08-04-prerender-avfoundation-pitfalls.md](docs/bugfixes/2026-08-04-prerender-avfoundation-pitfalls.md) —
  预渲染两坑：空轨在 AVPlayer 能播但导出报 "Operation Stopped"；
  backgroundColor 的 alpha 被忽略 → 带透明的产物走 fill+matte 双渲染
- [2026-08-05-inspector-scrub-field-gestures.md](docs/bugfixes/2026-08-05-inspector-scrub-field-gestures.md) —
  Inspector 数值框拖调完全无效：`currentEditor()` 对没在编辑的字段也返回非
  nil、检查器出现时字段被自动聚焦进编辑态；另修 ±1px 被固定归一化容差吞掉
  （容差必须亚像素）。长期约束见 architecture/inspector-scrub-number-field
- [2026-08-05-export-prerender-review.md](docs/bugfixes/2026-08-05-export-prerender-review.md) —
  导出评审三轮六连：预渲染失败删用户目标文件、画中画边缘因预乘 alpha 被
  多乘一次而变暗（`alpha=premultiplied` 实测不生效，改手动除回真实色）、
  预渲染 Stop 无效+泄漏临时文件；复审又抓到三个：Stop 点在 build() 期间
  崩溃整个 App（对未起跑的 session 调 cancelExport() 再 export()，这个
  修了两版——原子登记不够，`exportAsynchronously` 的启动动作必须进临界区）、
  修复本身把 fill 的 opacity 除没了（除法只测了 coverage 没测 opacity）、
  ffmpeg 成功后提交前还有一条没查的取消窗口
- [2026-08-06-subtitle-generation-review.md](docs/bugfixes/2026-08-06-subtitle-generation-review.md) —
  字幕生成评审返工十连 + 二至五轮共十四连：长素材缺口必须切窗逐窗落盘、
  跨 await 写回要带 generation+快照双守卫（且 generation 挡不住同工程改
  时间线 —— 写回一侧用当下状态重算或对映射输入 CAS）、纯音频 clip 的
  info 为 nil（指纹要回退磁盘线索）、可听性只有 CompositionBuilder 一份
  合同、`.onSubmit` ≠ 编辑结束且兜底提交自身要 dirty+CAS、取消检查的
  完备面 = 每个 await 前后 + 终态提交前且要逐阶段核对取消通道（下载靠
  Progress.cancel）、「不存 session」包括不存它的衍生闭包（取消动作留在
  withTaskCancellationHandler 的结构化作用域）、continuation 收尾责任按
  状态机点名（queued 取消当场自收）、**身份要随触发源传递**（jobID 绑
  configuration 进 action、回调捕获 token 执行时 CAS，进门才读「当前值」
  等于没有身份）、App 级 reservation 走引用计数账本且清理在终态前
  await 完成（fire-and-forget 会拆掉新任务的租约）、租约语义写死
  （成功=调用方持有）、覆盖类账本宁缺毋假（静默跳块 = 永久缺口）、
  catch 面 = 责任面、错误路径禁止返回成功零值、预览堆叠方向要对齐
  libass（最早在最底）、缓存读时 touch 才是真 LRU + checksum 信封；
  共性：每轮修复自身就是下一轮 P1 的攻击面
- [2026-08-06-build-version-and-shell-traps.md](docs/bugfixes/2026-08-06-build-version-and-shell-traps.md) —
  打包脚本写死 `VERSION:-0.3.0` 默认值，发到 0.4.1 后不传 VERSION 就静默打出贴错
  版本号的 DMG（dist/ 里真有两个）；改成兜底取 git tag。修它时又踩两个 shell 陷阱：
  裸 `$VAR` 紧跟中文会把多字节首字节吃进变量名（`set -u` 直接挂，与 bash 版本/
  locale 无关），`pipefail` 下 `VAR="$(a|b)"` 会在赋值处就死掉、绕开自己写的报错。
  **改 `.sh` 前必读**

## 根目录既有文档

- [SrtFlow-Requirements.md](SrtFlow-Requirements.md) — 产品需求说明与技术结论总表
- [README.md](README.md) — 项目介绍（面向使用者）
