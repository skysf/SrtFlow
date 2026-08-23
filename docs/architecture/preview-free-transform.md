# 预览区自由变换（ClipPlacement + Transform 面板）：两条管线必须同账

> 2026-08-04 引入，同日扩入 Transform 面板（旋转/不透明度/翻转/裁切）。
> 改预览合成（CompositionBuilder）、导出滤镜图（ExportGraph）
> 或预览交互层（ClipTransformCanvas）之前必读。

## 模型

`EditClip.placement: ClipPlacement?` —— 中心 + 宽高，全部是**相对画布的 0…1
归一化值**（宽随画布宽、高随画布高）。约定：

- **nil = 默认布局**：主轨等比铺满居中；画中画走 `overlayFraction` +
  `overlayAnchor` 九宫格。老工程、没摆过的段都是 nil。九宫格的尺寸是
  「画布宽 × fraction」，但**高度会爆出画布的（竖版素材）整体等比收进画布**
  —— 公式只有 `OverlayAnchor.defaultSize` 一份，`defaultPlacement`、
  合成 `fittingTransform`、导出九宫格 `scale=w:h:force_original_aspect_ratio=
  decrease` 三处必须都走它的账（横版素材算出来和收高前逐像素一致）。
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
`setPlacement` 会把约等于默认布局的摆放归一回 nil。**归一化容差必须小于
一个可见输出像素**（现为半像素：X/宽 `0.5/renderWidth`、Y/高
`0.5/renderHeight`）——固定归一化容差（如 0.001 ≈ 1920 宽下 1.9px）会把
Inspector 的 ±1px 步进整个吞回默认值，点了没反应。

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
（导出就是这么做的：先合黑底再 xfade）。预览的叠化按接缝分两条路径，判定
用 `coversCanvasOpaquely(canvas:isOverlay:)`：

- 两侧都**盖满画布且不透明**（仅翻转、放大出画布都算满足）→ 「后段垫底、
  前段淡出」，逐像素精确等于 dissolve，全程不变暗；
- 任一侧盖不满或半透明 → 后段改为全程线性淡入（从黑亮起）贴合压平模型，
  残余近似是中点亮度轻微下凹（默认合成器层叠乘法所致，最坏 25%）。

判定条件必须贴着数学前提（盖满 + 不透明）写，别拿 `hasVisualTransform`
这类粗粒度标志凑 —— 仅翻转被误送进近似路径就是白闪变暗。回归靠
`scripts/check-preview-composition.sh` 真取帧量像素守着。

**推移 / 擦除转场（2026-08-23 起，`ClipTransition` 三族）**：转场语义仍然
作用在「压平到黑底之后」的段上。接缝分派集中在 CompositionBuilder 的
「主轨接缝的转场分派」后处理（要等两侧的 fitted transform 都算完才判得了
前提，别搬回主轨循环里）：

- **推移族**（pushLeft/Right/Up/Down → xfade slideleft/…）：两段各挂平移
  斜坡（出场滑出、进场从对面滑进），并把裁切收进「静止时的画布」——
  压平模型里滑出画布的内容不会被滑回来看见，不裁的话放大出画布的段一滑
  就穿帮。前提：两侧变换**轴对齐可逆**（90° 的 preferredTransform、翻转、
  缩放、半透明、盖不满都行；任意角旋转、关键帧动画不行 —— 画布裁切表达
  不了）。满足时逐像素等于「压平再整幅滑动」。
- **擦除族**（wipeLeft/… → xfade wipeleft/…）：只给**出场段**挂线性缩小的
  `setCropRectangleRamp` 窗口（∩ 用户裁切；求交的 min/max 在移动边扫过
  用户裁切边处各有一个折点，必须进切片表）。进场段整幅垫底、**无任何
  前提**：窗口外露出的就是进场段 + 黑底，天然贴合压平模型。出场段前提：
  满幅不透明（`coversCanvasOpaquely`）+ 轴对齐。
- 前提不满足 → 回退成叠化的「双向线性淡变」近似路径。
- **方向语义是实测合同**：pushLeft/wipeLeft 的进场段从**右**边进来（画面
  内容 / 擦除边向左运动），与 xfade 的 slide/wipe 逐向实测一致，写死在
  `ClipTransition.motion` / `wipeRemainingRect` 里。改方向前先用纯色素材
  跑一遍 xfade 确认，预览与导出必须同向。
- 回归：`scripts/check-preview-composition.sh` 的推移/擦除组 —— 方向探针、
  「两色探针」（分辨擦除露出自己的另半边 vs 推移滑进另半边，纯色素材下
  两者长得一样）、旋转段回退；`scripts/check-export-frame-rate.sh` 逐种
  转场真跑生产 `plan()` + ffmpeg（xfadeName 拼错在滤镜图配置期就 EINVAL）。

转场选择器（`VideoEditTransitionPicker.swift`）的卡片小样是 SwiftUI 的示意
动画，不走合成器；悬停演示的几何直接复用 `ClipTransition.motion` /
`wipeRemainingRect`，跟合成模型同源。

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
- 中心对齐（`CenterSnap` / `CenterGuideLines`）：移动接近画布正中时吸附并亮
  黄色横/竖参考线，缩放只在恰好对中时亮线不吸（吸中心会拽歪锚在对角的
  手感）。剪辑变换框和形状拖动共用同一套，别各写一份阈值。

## 工程文件

`placement` 走手写宽容解码（`decodeIfPresent`，nil 兜底），
`checks/ProjectFile/main.swift` 里有存取往返检查。**分割等"从旧段构造新段"
的代码必须把 `placement` 带上**（同 `stillImageURL` 的教训）。
