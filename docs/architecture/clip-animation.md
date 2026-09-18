# 画面段的入场 / 出场动画：一个槽、两条管线、不露边

> 2026-09-18 引入（[方案](../plans/2026-09-18-clip-animation.md)）。改模型
> （`VideoEditClipAnimation.swift`）、求值器（`VideoEditClipAnimator.swift`）、
> 预览切片（`VideoEditCompositionBuilder.swift`）或导出路由
> （`VideoEditExportGraph.swift`）之前必读。
> 相关：[画面渐入渐出](video-fades.md)、[关键帧动画](keyframe-animation.md)、
> [预览自由变换](preview-free-transform.md)、[画面文字](text-overlays.md)。

## 它是什么

Inspector 里每个画面段的 **Animation** 区：In / Out 各选一种效果 + 一个强度。
图片在本工程里不是叠层（拖进来就被 `StillImageClipFactory` 转成静帧循环视频），
所以「给图片加动画」＝「给段加动画」，视频段同样有。

五种效果，**都落在 AVFoundation 图层指令的三种斜坡上**：

| 效果 | 落点 | 自带淡变 |
| --- | --- | --- |
| Fade | 不透明度斜坡（就是画面渐变本身） | —— |
| Rise | 平移（下方浮入 / 继续上移出） | 是 |
| Pop | 缩放（`easeOutBack` 回弹） | 是 |
| Zoom | 缩放（`easeOutCubic` 缓推） | 是 |
| Wipe | 裁切矩形斜坡（横向揭开） | 否 |

**模糊 / 对焦不在列**：预览侧的图层指令没有逐帧滤镜这一说，要做只能自建
`AVVideoCompositing` 合成器（轻量化原则那一档，需用户批准）。导出侧倒能用
`sendcmd` 逐帧发 `gblur` 的 sigma 凑出来，但那样预览看不到模糊，违反同账。

## 一个槽：效果和时长共用 `videoFade*`

**`ClipPresetAnimation` 里没有时长。** In=Fade 就是 v10 起的「画面渐变」，
两者共用 `EditClip.videoFadeInDuration / videoFadeOutDuration`：

- 老工程零迁移 —— 解码时没有 `presetAnimation` 键、时长又 > 0 的，一律认作
  `.fade`（`EditClip.init(from:)`）。不认回来的话，用户调好的淡入淡出一打开就没了。
- 纯 Fade 仍走 ffmpeg 的 `fade=…:alpha=1` 快路径，**不预渲染**，导出不变慢。
- 「这一段头尾各多久」只有一处真值。

### 不变量：`kind == .none` ⟺ 那一侧时长为 0

写入侧两者永远一起改（`VideoEditProject+ClipAnimation.swift`）：选上效果时给
`ClipPresetAnimation.defaultDuration`，选回 None 时清零。破了它就会出现两种坏状态：
界面显示"无动画"而画面还在淡（时长没清），或者选了效果画面纹丝不动（时长是 0）。
`checks/ProjectFile` 有守卫。

### 仲裁只有一处：`ClipPreset.effective`

夹紧（`FadeWindow.clamped`）和转场让位（`suppressing`）都复用画面渐变那一份 ——
接缝上有转场时那条边整个归转场管，入/出场动画和画面渐变一样让位、不叠加。
预览、导出、Inspector 的提示文案三处都从这个函数取，各算各的必然分叉。

## 不露边（产品决策第 4 条）

盖满画布的段一旦往上浮或者缩小，边上就会露出底下那一层（主轨是黑场、
上层轨是主轨画面）。判据是**纯几何**的 `EditClip.placementCoversCanvas`
（旋转过的段保守算作没盖满）。盖满时：

- 位移按量补放大：框往上挪 `dy`（框高的比例），下边要够回原位就放大到 `1 + 2·dy`；
- **Pop 反过来做**：从 `1 + a` 落到位，而不是从 `1 - a` 弹出来 —— "弹"这件事
  本身就是缩放，没法靠补偿盖住；
- 末了兜一道 `scale ≥ 1`：回弹曲线尾巴那点越界被夹掉，观感是"落到位停住"，
  而不是闪一帧黑边。

不盖满的段（角落里的 PNG、比例对不上留空的图）**不补** —— 本来就没有露出来的
边可盖，补了只是一次莫名其妙的缩放。

`checks/PreviewComposition` 两道守卫：纯值层面逐点扫 `scale ≥ 1 + 2|offset|`；
像素层面真取帧量"上下边不许比中心暗"（画布特意用 320×180，64×36 上那几个像素
的黑条量不出来，守卫红不了就等于没守）。

## 两条管线

| 管线 | 落点 |
| --- | --- |
| 预览 | `VideoEditCompositionBuilder`：`PlacedClip.preset` ← 仲裁结果；变换走 `composedTransform`（关键帧 ⊕ 预设 ⊕ 推移转场），裁切走 `cropRectangle`（擦除转场 ∩ 用户裁切 ∩ 预设擦除），透明度在 `applyOpacity` 里乘上预设那一份 |
| 导出 | 逐帧效果 → `AnimatedClipPrerenderer` 用**预览同一套合成**渲中间片（主轨一条黑底 ProRes、上层轨 fill+matte 两条），ffmpeg 图里当普通素材吃；纯 Fade 照旧走 `VideoFade.filterSteps` |

### 预览切片：片内必须线性

图层指令的斜坡只会线性插值，所以切片边界要含住所有折点（`ClipAnimator.sliceTimes`）：

- `fade` 线性、`wipe` 的 reveal 与裁切矩形对时间都线性 → **只要窗口两端**；
- `rise`/`pop`/`zoom` 带缓动 → 窗口内**按工程帧加密**（单侧上限 120 片）。

### 三条容易踩的线

1. **`PlacedClip.preset` 和 `fadeIn/fadeOut` 互斥**。要逐帧的效果整条交给
   `preset`（它自己的曲线里就含淡变），纯 `.fade` 才挂透明度斜坡 ——
   两条路同时开会把透明度乘两遍。
2. **擦除要全程挂裁切矩形**。窗口外那一片必须明确给出"整幅"这个矩形
   （`ResolvedClipPreset.usesWipe` 那一支），少给一片整条斜坡就断了，
   表现是擦除完全不生效。
3. **预渲染的临时时间线里没有邻居**，仲裁必须在外面做完再传进去
   （`renderMain(clip:fades:…)`）。见
   [2026-09-18 预渲染烤进渐变](../bugfixes/2026-09-18-prerender-fade-ignores-transition.md)。

## 保守回退（有意为之）

带逐帧动画的段在接缝上一律走**近似**路径：`coversCanvasOpaquely` 对它返回 false
（叠化改双向淡变）、`pushSideExact` 也拒绝它（推移改双向淡变）。理由和关键帧段
一样 —— 精确路径要按静态变换把这一段"压平到静止时的画布"，段里别处还在动的话
动起来就会被裁掉一块。代价是「入场动画 + 该段尾部有推移/擦除转场」这种组合里，
转场退化成交叉淡变。

## 批量套用（多选）

一节课几十张图，一张张点不现实：多选时 Inspector 给同一套控件
（`multiClipAnimationSection`），改动落到**所有选中的画面段**上，纯音频段跳过。

- 写入路径从一开始就收 `[UUID]`（`VideoEditProject+ClipAnimation.swift`），
  单段面板传 `[id]` —— 两条路一份实现，不会分叉。
- 值不一致时**如实显示「多个值」**（`Binding<ClipPresetKind?>` 取不到共同值就是
  `nil`，下拉里临时多一项 Mixed），不拿第一段的值冒充全体：冒充的话用户看一眼
  以为都设好了，实际另外十几段还是原样。
- 时长框的上限取**最短那一段**：比它长的值在短段上会被夹紧，框里显示的和真正
  生效的就对不上了。

## 代价：预渲染是按段整条渲的

一张 60 秒的图加 0.6 秒的 Rise，也要渲一条 60 秒的 ProRes 中间片（上层轨两条）。
图片段有 60 秒上限（`StillImageClipFactory.stillDuration`），视频段没有 ——
所以 Inspector 在超过 30 秒的段上会提示"导出会变慢"。
真要治本得做**窗口化预渲染**（只渲入/出场窗口，中间段照走原素材），
方案里留了第三刀，实测之后再定。

## 回归守卫

| 检查 | 守什么 |
| --- | --- |
| `scripts/check-clip-animation.sh` | **两条管线逐点对账**：同一份时间线，预览取帧与真导出抽帧在同一时刻、同一区域的值必须一致（五种效果 + 上层轨 fill/matte）；纯 Fade 不许走预渲染 |
| `scripts/check-preview-composition.sh` | 求值器的曲线（Fade 线性、擦除线性、铺满时 `scale ≥ 1 + 2\|offset\|`）+ 真取帧的擦除几何与"不露边" |
| `scripts/check-video-fade.sh` | 预渲染不许把该让位的渐变烤进中间片（回归守卫）+ 擦除真导出 |
| `scripts/check-project-file.sh` | 老工程迁移、`kind ⟺ 时长` 不变量、v15 闸门、分割/定格的取舍，以及生产接线（写入收 `[UUID]`、导出路由、仲裁传参） |

## 人工回归清单（自动化够不着的）

- 五种效果各自在「铺满画布的主轨图」和「角落里的上层轨 PNG」上各看一遍：
  没有黑边闪烁、没有位置跳变、动画结束后停在摆放框上。
- 动画播放时预览里的**选中框不跟着飞**（动画是叠在基准上的偏移，不改存下来的
  摆放值）。
- 主轨接缝有转场时，那一侧的入/出场不生效，且 Inspector 当场有说明。
