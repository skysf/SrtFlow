# 预览区自由变换（ClipPlacement + Transform 面板）：两条管线必须同账

> 2026-08-04 引入，同日扩入 Transform 面板（旋转/不透明度/翻转/裁切）。
> 改预览合成（CompositionBuilder）、导出滤镜图（ExportGraph）
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
  预览选中框、拖动起点、Inspector 的 Position/Scale 都从它取。

Transform 面板追加的四个字段（都有「无操作」默认值，全默认走原来的轻量路径，
`hasVisualTransform` 是统一的判定口）：

- `rotationDegrees` —— 绕摆放框中心，**正角度 = 顺时针**（SwiftUI
  rotationEffect、CGAffineTransform 在 Y 朝下坐标系、ffmpeg rotate 三边天然
  一致，别再加负号）。
- `opacity`、`flippedHorizontally/Vertically`。
- `crop: ClipCrop?` —— 四边各裁掉源画面（显示方向）的归一化比例。裁完剩下
  的画面填进摆放框；**默认摆放框按裁后的宽高比算**（裁成 1:1 默认就显示成
  正方形），见 `croppedDisplaySize`。

**变换顺序是合同**：裁切 → 翻转 → 缩放进摆放框 → 绕框中心旋转 → 平移到位。
预览（`fittingTransform` 拼 CGAffineTransform + `setCropRectangle`）和导出
（filter 链顺序）都按这个来，改一边必改另一边。

Inspector 的语义：Position = 摆放框中心相对画布中心的**输出像素**偏移；
Scale = 相对默认布局宽度的百分比，改动等比乘在当前宽高上（保留边拉伸变形）；
`setPlacement` 会把约等于默认布局的摆放归一回 nil。

## 两条渲染管线，一份时间账

| 管线 | 落点 |
| --- | --- |
| 预览（AVFoundation） | `fittingTransform`：完整 CGAffineTransform（翻转=负缩放）+ `setCropRectangle`（裁切矩形要逆着 preferredTransform 换算回源轨自然坐标）+ layer opacity（转场斜坡整体乘 clip.opacity） |
| 导出（ffmpeg） | `transformSteps`：`crop` → `hflip/vflip` → `scale` → `format=rgba`（旋转/半透明才加）→ `rotate=θ:ow=rotw(θ):oh=roth(θ):c=black@0` → `colorchannelmixer=aa`；主轨叠 `color=black` 画布，**overlay 用中心表达式 `cx-w/2`** —— 旋转会把输出框撑大，只有中心是不变量。**不用 pad**：pad 不接受负坐标/超界，overlay 允许探出画面 |

改任何一边都要对照另一边；验收标准是同一时刻预览截图和导出抽帧长一样。
像素尺寸过 `evenPixel`（正偶数，yuv420 要求），坐标取整。

**预览的黑底轨**：时间线上有任何半透明图层（不透明度、转场淡入淡出）时，
CompositionBuilder 会垫一条 `BlackBaseVideoFactory` 的不透明黑视频当底 ——
默认合成器在混合路径上不铺 `backgroundColor`，见
[2026-08-04-opacity-green-background](../bugfixes/2026-08-04-opacity-green-background.md)。
工厂是 actor 单飞：唯一临时文件 → 校验 → 原子替换，消费前还要再验一遍，
「文件存在」不等于「文件可用」。

**叠化 × Transform 的合成模型**：转场语义上作用在**压平到黑底之后**的段上
（导出就是这么做的：先合黑底再 xfade）。预览的叠化对两侧都是不透明满幅的
普通段用「后段垫底、前段淡出」—— 逐像素精确等于 dissolve；接缝**任一侧
`hasVisualTransform`** 时后段改为全程线性淡入（从黑亮起）贴合压平模型，
残余近似是中点亮度轻微下凹（默认合成器层叠乘法所致）。改这段逻辑前先想清
「垫底=精确 dissolve」的前提条件是两侧不透明满幅。

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
