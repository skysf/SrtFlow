# 预览区自由变换（ClipPlacement）：两条管线必须同账

> 2026-08-04 引入。改预览合成（CompositionBuilder）、导出滤镜图（ExportGraph）
> 或预览交互层（ClipTransformCanvas）之前必读。

## 模型

`EditClip.placement: ClipPlacement?` —— 中心 + 宽高，全部是**相对画布的 0…1
归一化值**（宽随画布宽、高随画布高）。约定：

- **nil = 默认布局**：主轨等比铺满居中；画中画走 `overlayFraction` +
  `overlayAnchor` 九宫格。老工程、没摆过的段都是 nil。
- **九宫格和自由摆放互斥**：点停靠位、动大小滑块都会把 `placement` 清回 nil
  （`setOverlayLayout` / `overlaySizeBinding`），否则那些控件看起来"失灵"。
- 宽高**各自独立**（拉边把手允许变形），所以不能只存一个 scale。
- `resolvedPlacement(canvas:isOverlay:)` 是唯一的"此刻实际框"换算口；
  预览选中框、拖动起点都从它取，别在视图里重算默认布局。

## 两条渲染管线，一份时间账

| 管线 | placement 的落点 |
| --- | --- |
| 预览（AVFoundation） | `fittingTransform(placement:)`：非等比 scale + 平移进目标像素框 |
| 导出（ffmpeg） | 主轨：`scale=w:h` + `color=black` 画布 + `overlay=x:y:shortest=1`（**不用 pad** —— pad 不接受负坐标/超界，overlay 允许探出画面）；画中画：`scale=w:h` + overlay 整数坐标 |

改任何一边都要对照另一边；验收标准是同一时刻预览截图和导出抽帧长一样。
像素尺寸过 `evenPixel`（正偶数，yuv420 要求），坐标取整。

## 交互层（ClipTransformCanvas / ResizableFrameBox）

- 把手手势一律 `DragGesture(coordinateSpace: .global)` + 手势开始抓
  `startRect` 重放绝对增量 —— 把手挂在框边上，手势一生效框就动，`.local`
  就是反馈回路（同 [timeline-drag-gestures](timeline-drag-gestures.md) 的裁切把手教训）。
- 角把手等比（增量大的方向定 scale）、边把手单边自由拉伸、框内拖动移动。
- 拖动过程只写 `state`（`livePlace` → liveApply），**不重建合成**；松手
  `endLiveEdit()` 才重建 —— 所以拖动中画面不动、框动，松手后画面跟上（~0.3s）。
- 形状复用 `ResizableFrameBox`（movable=false，移动仍走形状自己的手势）：
  线条只给左右把手，正方形只给四角，长方形全套。
- 命中测试从最上层往下：画中画行号大的在上，主轨垫底；形状叠层在
  ClipTransformCanvas 之上，形状点击天然优先。

## 工程文件

`placement` 走手写宽容解码（`decodeIfPresent`，nil 兜底），
`checks/ProjectFile/main.swift` 里有存取往返检查。**分割等"从旧段构造新段"
的代码必须把 `placement` 带上**（同 `stillImageURL` 的教训）。
