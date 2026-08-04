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
`scripts/check-project-file.sh`（工程存盘与素材重链接，源码在 `checks/ProjectFile/`）

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

## 根目录既有文档

- [SrtFlow-Requirements.md](SrtFlow-Requirements.md) — 产品需求说明与技术结论总表
- [README.md](README.md) — 项目介绍（面向使用者）
