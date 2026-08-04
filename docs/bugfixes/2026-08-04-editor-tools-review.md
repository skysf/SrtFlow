# 编辑器三件套的评审返工：工具模式没关旧手势、升轨带错摆放、线条框不随旋转

- **日期**：2026-08-04
- **来源**：PR #4 合并前评审发现，三处都未发布即修复
- **相关**：[preview-free-transform](../architecture/preview-free-transform.md)、
  [timeline-drag-gestures](../architecture/timeline-drag-gestures.md)

## 一、分割（刀片）模式下移动/裁切手势还活着

**症状**：切到分割工具后，本想点一刀，手抖 4pt 就变成移动素材；点在块边缘
2pt 的偏移会触发裁切把手——那一刀不但没落下，素材还被改了。

**根因**：加工具模式时只在**点击回调**里判断了 `activeTool == .split`，
移动 `DragGesture` 和两侧裁切把手仍无条件挂着。手势系统先到先得：拖动一旦
被识别，点击就永远不会发生。

**修复**（`VideoEditTimelineView.swift`）：
- 移动手势 `.gesture(moveGesture, including: split ? .subviews : .all)` ——
  `GestureMask.subviews` 保留上面的点击、掐掉本手势；
- 裁切把手在分割模式下**整个不渲染**（不是 guard 回调）。

**验证**：真实窗口注入——分割模式下块内拖 60pt 素材纹丝不动，左缘拖 30pt
无裁切，点击照常切开。

**教训**：**引入互斥的工具模式时，旧模式的手势要整个关掉，不是在回调里
加 guard。** guard 挡住的只是效果，手势还在吞事件，新模式的交互会被静默
吃掉。SwiftUI 里用 `GestureMask` / 条件渲染，别用回调里的 if。

## 二、摆放过的画中画走「Selected only」导出变黑底小窗

**症状**：给画中画拖过自由摆放（placement）后，只选它导出单个视频，出来的
是黑底上一个小窗，而不是约定的完整画面。

**根因**：`selectionForExport` 在只选画中画时会把它**升为主轨**（约定：
「导出单个视频＝完整画面」），但升轨时没清 `placement`——导出器看到
placement 就继续走黑底 overlay 分支。加字段时漏排查了这条**隐式的轨道
转换路径**。

**修复**（`VideoEditModels.swift`）：升主轨的段 `placement = nil`；顺手把
整个选中导出逻辑从 `VideoEditProject` 下沉成 `TimelineState.
selectionForExport(ids:)` 纯值变换，`checks/ProjectFile` 补了 9 项回归
（单选画中画升轨丢摆放、混选保留摆放、多条画中画只有升轨那条丢）。

**教训**：给剪辑模型**加字段时，把所有「从旧段构造/转换新段」的路径过一遍**
——分割、复制、升轨、跨轨移动。这次分割记得带上（有 stillImageURL 的前车
之鉴），升轨这条却是反过来：不该带的带上了。字段语义依赖上下文（相对完整
画面的摆放）时，换了上下文就要重新审视。

## 三、旋转后的线条选中框方向不对

**症状**：线条转到 90° 画面上是竖线，选中框和左右把手还横着躺。

**根因**：绘制走 `rotationEffect`，但 `ShapeAnnotation.frame(in:)` 和变换框
都忽略 `rotationDegrees`。

**修复**（`VideoEditView.swift`）：线条的框按**旋转后的包络**计算
（`|L·cosθ| × |L·sinθ|`）；转过角度的线把手隐藏（横向把手在斜线上语义
不成立），长度仍在检查器调。

**教训**：给带变换（旋转/翻转）的元素加选中框时，框要套在**变换后的几何**
上；把手只在语义仍然成立的姿态下提供。
