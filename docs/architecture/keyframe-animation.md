# 关键帧动画：源时间锚定、切片规则、fill+matte 预渲染

> 2026-08-04 引入。改关键帧模型（VideoEditAnimation.swift）、预览切片
>（CompositionBuilder）、导出预渲染（VideoEditPrerender.swift）之前必读。
> 相关：[preview-free-transform](preview-free-transform.md)。

## 模型（VideoEditAnimation.swift）

- 四行可动画：Position（centerX+centerY）、Scale（width+height）、Rotation、
  Opacity —— 共六条 `KeyframeTrack`，挂在 `EditClip.animation: ClipAnimation?`。
- **关键帧锚在源时间上**（`Keyframe.time` 和 `sourceStart` 同一把尺）。
  这一条定了，变速/裁头尾/分割全都自动正确：分割后两半带同一份轨、各播
  自己窗口内的段落、接缝数值连续（有 check 守着）。时间线 ↔ 源的换算走
  `sourceTime(atTimeline:)` / `timelineTime(atSource:)`。
- 线性插值、两端夹紧；半帧（1/60s）内重写同一时刻是**替换**不是堆积
  （连续拖动反复落同一帧靠它幂等）。
- 空轨回落到静态字段：`animatedPlacement/Rotation/Opacity(atTimeline:)` 是
  唯一取值口，预览合成、交互框、Inspector 数值都从这里读。
- 工程格式 **v3**；升轨（selectionForExport）丢 animation（相对画布的属性）。

## 交互约定（对齐 CapCut）

- 每行 `‹ ◇ ›`：跳上帧 / 播放头处打·删帧 / 跳下帧；标题行总控四行齐打。
- **行里有帧后，改数值或拖预览框自动在播放头处落新帧**（setPlacement /
  livePlace / setRotation / setClipOpacity 里的分支）；播放头不在段内则
  落回静态字段。
- 删掉某行最后一帧时，把此刻的插值**固化回静态字段** —— 画面不跳。
- 时间线块底边画菱形（全轨并集），只展示不交互（拖动改帧是下期）。

## 预览切片（CompositionBuilder）

指令切片边界在原有转场折点之外追加：每个关键帧的时间线时刻；旋转相邻帧
之间按 **≤6°/片** 加密（`setTransformRamp` 是矩阵线性插值，走弦不走弧，
角度大了明显缩水变形；单段上限 400 片）；不透明度动画 × 转场衰减是两条
线性通道的**乘积**（二次曲线），转场窗口内按 0.1s 加密。片内一切都线性，
所以每片用两端取值的 ramp 就是精确重建 —— `applyOpacity` 已重构为
「fadeFactor × animatedOpacity」端点求值，别改回分支穷举的老写法。

位置/缩放动画的矩阵插值本身精确（平移/缩放分量独立线性），不用加密。
`coversCanvasOpaquely` 对动画段保守返回 false（叠化走近似路径）。

## 导出：AVFoundation 预渲染（VideoEditPrerender.swift）

ffmpeg 做不了干净的逐帧缩放（流尺寸中途不能变）和透明度插值，所以动画段
在 `plan()` 里先用**预览同一套合成代码**渲成中间片（预览=导出按构造一致），
再当普通素材进 ffmpeg 图：

- **主轨段**：黑底 ProRes 422 一条，`fps=30,setsar=1,format=yuv420p` 后直接
  进 concat/xfade 链。声音不进中间片，音频链照旧读原素材。
- **画中画段**：默认合成器的 `backgroundColor` **只支持不透明色（alpha 被
  忽略，文档明说）**，透明背景根本出不来 —— 走 fill + matte 双渲染：
  fill 是内容压黑底（不带不透明度）；matte 是纯白素材（BlackBaseVideoFactory
  的白色版）套**同一份**摆放/旋转/不透明度动画压黑底，白=可见、灰=半透明、
  边缘抗锯齿灰阶就是 alpha 渐变。ffmpeg 里 `alphamerge` 合回 rgba 原位叠放。
  两条的摆放基准都固化成显式 placement（matte 的素材尺寸和原素材不同，
  靠素材推默认布局会各说各话）；关键帧要经由时间线时刻**换算到 matte 自己
  的源轴**（remappedAnimation）。

两个踩过的坑（详见
[2026-08-04-prerender-avfoundation-pitfalls](../bugfixes/2026-08-04-prerender-avfoundation-pitfalls.md)）：

1. 合成里**无内容的空轨**（A/B 双轨是无条件建的）AVPlayer 容忍、
   AVAssetExportSession 直接报 InvalidVideoComposition（表述是
   "Operation Stopped"）—— build() 收尾统一清空轨。
2. 别指望 `backgroundColor` 的 alpha；带透明的产物一律 fill+matte。

## 回归

`scripts/check-preview-composition.sh`（13 项）：透明度/缩放动画的抽帧
亮度曲线、旋转切片数、主轨预渲染端到端、fill 不被压暗、matte 烘焙不透明度、
matte 角落纯黑。工程文件侧（`check-project-file.sh`）：动画往返、v3 版本、
插值/变速/分割连续性。
