# 画面：单段的渐入渐出（video fades）

> 2026-09-17 随「上层视频轨对等化」一起引入。改 `VideoEditVideoFade.swift`、
> CompositionBuilder 的「单段画面渐变」后处理、或 ExportGraph 的
> `transformSteps` 之前必读。
>
> **2026-09-18 起它在界面上叫「In / Out = Fade」**：Inspector 的渐变两行被
> [入场 / 出场动画](clip-animation.md)那一块接管了，本文描述的模型、字段
> （`videoFade*Duration`）、夹紧和转场仲裁**一个字没变** —— 变的只是它现在是
> 五种效果里的一种，其余四种要逐帧渲染、走预渲染那条路。

## 这是什么，不是什么

**是**：给**一段**素材的头尾各加一条透明度斜坡。一段的事，任何轨道都能设。

**不是**：接缝上的转场（`ClipTransition`）。转场要两段、会让时间线整体变短、
在预览和导出里走完全不同的实现。两者在同一条边上**互斥**，见下面的仲裁。

## 渐变到什么：露出下面那一层

这里做的一律是**整层 alpha 的线性斜坡**，不是「淡到黑」。渐变露出来的是这一段
**底下那一层**：

| 段在哪 | 底下是什么 | 看起来 |
| --- | --- | --- |
| 主轨（最底下那条视频轨） | 画布黑底 | 淡入淡出黑场 |
| 上层视频轨 | 主轨画面 | 从主轨画面里化进来、再化回去 |

两种观感来自**同一个滤镜、同一条斜坡**，差别只在垫在下面的是什么。正因如此
预览和导出才不用各写一套。

**别改成显式淡向黑色。** 上层轨那样会把主轨闪黑一下 —— 这正是
`scripts/check-video-fade.sh` 第 2 组和 `scripts/check-preview-composition.sh`
第 5 组专门钉的方向（两组都从**起点**量起，不是只量中点）。

## 两条管线，一份斜坡

| 管线 | 落点 |
| --- | --- |
| 预览（AVFoundation） | `PlacedClip.fadeIn/fadeOut` → layer instruction 的 `setOpacityRamp`。转场用的是同一套机制，所以单段渐变只是在接缝分派**没占用**的边上补一手 |
| 导出（ffmpeg） | `VideoFade.filterSteps` → `fade=t=…:alpha=1`，接在 `transformSteps` 变换链的**最末尾** |

两处的乘法语义必须一致，而它们天然一致：

- 预览：`fadeFactor(item:at:) * clip.animatedOpacity(...)` —— 显式相乘。
- 导出：`fade=…:alpha=1` 是**乘**在已有 alpha 上的，不是覆盖。实测
  `colorchannelmixer=aa=0.5` 的段淡入，中点 alpha=64 而不是 128。

所以半透明的段渐变到**自己的不透明度**为止，两边逐帧一致。

## 三条硬约束

1. **夹紧规则与声音共用一份**（`FadeWindow.clamped`，见
   `VideoEditFadeWindow.swift`）。产品语义逐字相同（「这一段的开头/结尾渐变
   多久」），抄第二份一定会在边界条件上分叉：谁先夹、超长怎么按比例收、多小
   算没设。存的是**用户的意图**，「不超过段长」在读侧收口 —— 段被拉长之后
   渐变应当跟着恢复，而不是写入那一刻就被当时的段长永久截短。

2. **`fade` 必须在变换链最末尾。** `st` 读的是链上的当前时间轴，而链上
   `setpts=(PTS-STARTPTS)/speed` 和 `fps` 都已经跑过，此刻 t=0 正是这一段在
   时间线上的起点、总长正是 `timelineDuration`。拿源长度算淡出起点的话，
   变速的段会淡错地方（2x 的段在一半处就开始淡出）。

3. **转场仲裁：有转场的那条边，用户设的渐变让位**（`VideoFade.effective`）。
   为什么不叠加：两段衰减相乘会在接缝处压出一个明显的暗块。为什么不取较长者：
   那样用户设的值会被静默改写，而转场时长本来就是他另外调过的。
   界面上必须**当场说清楚**（Inspector 的 `videoFadeNote`），不能让人以为坏了。

   声音那边有 `previewMainTrack` / `exportMainTrack` 两个口径，画面这边只有一个
   —— 画面转场的交叉淡变在两条管线里都**不经过**这条斜坡（预览由
   CompositionBuilder 的接缝分派另挂，推移/擦除两族根本不是淡变；导出由段与段
   之间的 `xfade` 做），所以只需要「抑制」，不需要「替换」。

## 连带的判定

- `hasVisualTransform` **包含**画面渐变：渐变要在 rgba 上做 alpha 斜坡，只有
  变换链那条路会先 `format=rgba`，轻量路径（`scale`+`pad`）挂不上 `fade`。
- `coversCanvasOpaquely` 对有渐变的段**返回 false**：它在头尾是半透明的，
  叠化的「后段垫底、前段淡出」精确路径不成立（前提就是满幅不透明）。
- 预览的黑底轨（`needsOpaqueBase`）判据本来就看 `fadeIn/fadeOut != nil`，
  单段渐变挂上去之后自动纳入，不用另加条件。

## 回归

| 守什么 | 在哪 |
| --- | --- |
| 导出真产物：上层轨渐变露出主轨、主轨渐变淡向黑、转场仲裁 | `scripts/check-video-fade.sh` |
| 预览真取帧：同样三件事 | `scripts/check-preview-composition.sh` 第 5 组 |
| 夹紧规则（与声音共用） | `scripts/check-audio-fade.sh` + `scripts/check-project-file.sh` |
| 工程格式 v10 登记 | `scripts/check-project-file.sh` |

两条管线的断言**必须成对改**：只改一边就是「预览看着对、成片不对」，而这正是
这套东西最容易出的问题。
