# 2026-09-18 画面段的入场 / 出场动画（图片与视频通用）

> 文字那套动画（[text-overlays.md](../architecture/text-overlays.md) §动画）搬到**段**上。
> 图片在本工程里不是叠层：拖进来就被 `StillImageClipFactory` 转成静帧循环视频，
> 之后完全是个普通 `EditClip`。所以「给图片加动画」＝「给段加动画」，
> 能做什么由段的两条管线定死。

## 产品决策（用户 2026-09-18 拍板）

1. **效果清单**：In / Out 各选一种 —— `None / Fade / Rise / Pop / Zoom / Wipe`。
   逐字类（打字机 / 逐字浮现 / 描边生长）是文字概念，图片没有字，不适用；
   **模糊与对焦不做**（理由见下一节）。
2. **吞掉「画面渐变」**：Inspector 不再单列 Fade in / Fade out 两行。
   In=Fade **就是**今天的画面渐变，时长存的还是
   `EditClip.videoFadeInDuration / videoFadeOutDuration` ——
   老工程零迁移（设过渐变的段打开就是 In=Fade），且**纯 Fade 仍走 ffmpeg 的
   `fade` 快路径、不预渲染**。
3. **作用范围**：所有非纯音频的段都给（图片只是静帧视频，同一条代码路径；
   只给图片等于人为加闸，日后必拆）。
4. **不露边**：铺满画布的段做位移/缩放类动画时自动补偿，**绝不露出下面那层**；
   不铺满的段（角落 PNG、比例对不上留空的图）纯位移不补 —— 那种情况本来就
   没有「露出来的边」可盖，补了只是一次莫名其妙的缩放。
5. **循环强调（Breathe / Ken Burns）这一刀不做**。面板只有 In / Out /
   Intensity 三行，**不出现**只能选 None 的 Emphasis 行。
6. **批量套用**放第二刀（多选时同一面板 + 套用按钮）；写入路径从第一刀起就按
   「能接多段」设计。
7. 顺手修一个既有 bug：带动画的段走导出预渲染时，画面渐变**没有**让位给转场
   （§既有 bug）。

## 选型约束：为什么只有这五种

预览/导出同账是硬约束（[preview-free-transform.md](../architecture/preview-free-transform.md)、
[keyframe-animation.md](../architecture/keyframe-animation.md)）。段的两条管线是：

| 管线 | 能力 |
| --- | --- |
| 预览 | AVFoundation 默认合成器：**仿射变换斜坡 + 裁切矩形斜坡 + 不透明度斜坡**，没有逐帧滤镜 |
| 导出 | ffmpeg 图；带逐帧动画的段先用**预览同一套合成**预渲染成中间片（`AnimatedClipPrerenderer`），上层轨走 fill+matte |

于是收下的五种正好一一落在这三种斜坡上：

| 效果 | 落点 |
| --- | --- |
| Fade | 不透明度斜坡（＝今天的画面渐变，导出侧 `fade=…:alpha=1`） |
| Rise | 平移（+ 自身淡入淡出） |
| Pop | 缩放（`easeOutBack` 回弹） |
| Zoom | 缩放（`easeOutCubic` 缓推，无回弹） |
| Wipe | 裁切矩形斜坡（与擦除转场同一套机制） |

**模糊 / 对焦不收**：预览侧图层指令做不了模糊，导出侧倒能用 `sendcmd` 逐帧发
`gblur` 的 sigma 凑（实测 vendor 的 ffmpeg 8.1 里 sigma 带 `T` 标志），
但那样预览看不到模糊 —— 要两边都对只能自建 `AVVideoCompositing` 合成器，
属于 AGENTS.md 里「重量级方案先征得用户同意」那一档。以后要加从这里起步。

## 数据模型

```swift
/// 预设动画（与 `ClipAnimation` 的手打关键帧是两回事，别弄混）
struct ClipPresetAnimation {   // VideoEditClipAnimation.swift
    var entrance: ClipPresetKind = .none   // none/fade/rise/pop/zoom/wipe
    var exit: ClipPresetKind = .none
    var intensity: Double = 0.6            // 0…1 幅度总控
}
```

- **时长不在这个结构里**：沿用 `EditClip.videoFadeInDuration /
  videoFadeOutDuration`。一份存储、零迁移，而且「纯 Fade 不预渲染」这条快路径
  是靠 kind 判的，时长换个地方存只会多一次同步。
- 夹紧继续走 `FadeWindow.clamped`（和声音渐变、文字动画**同一份**）：各自不超过
  段长，两者之和超了按比例同收。存意图、读侧夹紧。
- 时长范围沿用画面渐变的 `0…段长`（0 = 关），**不套**文字那个 0.1–5s 的帽子 ——
  整段淡入本来就是合理诉求，合并之后老工程的值也不许被截短。
- 缓动曲线复用 `TextEasing`，不新开参数。质感来自曲线，摊开只会让人调丑。
- 命名：本工程已有 `ClipAnimation`＝**手打关键帧轨**，本结构是**预设**，
  两者可以同时存在（预设叠在关键帧解析出来的基准上）。

### 工程格式 v15（按需）

`requiresFormatVersion15` = 有任何段用了 **`.fade` 以外**的 kind。
理由同 v14（新增的枚举值也算持久数据）：只认 v14 的旧版打开后那一段会
**静默变回硬切/纯淡入**，成片当场不一样；随手编辑触发自动保存就永久丢失。
`.fade` 不算 v15 数据 —— 它落的就是 v10 就有的那两个键，旧版读得懂。

## 动画语义（求值器 `ClipAnimator`，纯函数）

`state(for:at:canvas:) -> ClipAnimationState { opacity, offset, scale, reveal }`，
预览与导出（预渲染）共用同一入口；时刻先经 `TextAnimator.quantize` 钉到工程帧。

入场 / 出场**不会重叠**（`FadeWindow.clamped` 保证），求值是干净的三段式。
出场是入场的**连贯延续**而非原路退回（与文字同口径）：Rise 出场继续向上走、
Zoom 出场继续推进。Wipe 例外，原路收回（几何量原路才读得懂）。

### 铺满画布的段：不露边规则（拍板第 4 条）

判据是**几何**的 `placementCoversCanvas(canvas:)`（摆放框盖住画布四边；
旋转过的段保守算作不铺满）。铺满时：

| 效果 | 不铺满（角落 PNG / 留空的图） | 铺满画布 |
| --- | --- | --- |
| Rise | 下方浮上来 + 淡入 | 同上，**再按位移量补放大** `1 + 2·\|dy\|/H` |
| Pop | 0.65 → 1.05 → 1（从小弹出来） | **1.35 → 1**（从大落到位，同一条 back 曲线取反向） |
| Zoom | 1.10 → 1 | 同左（本来就不露边） |
| Wipe / Fade | 裁切 / 透明度 | 同左（天生不露边） |

末了统一兜一道 `scale = max(scale, 1)`：回弹曲线尾部那点越界（最多 ~2%）
被夹掉，观感就是「落到位停住」，而不是闪一帧黑边。

## 两条管线落点

| 部件 | 位置 |
| --- | --- |
| 模型 + 存盘 + 格式闸门 | `VideoEditClipAnimation.swift`（新） |
| 求值器 + 切片边界 | `VideoEditClipAnimator.swift`（新，纯函数，自检直接逐帧调） |
| 预览：变换/裁切/透明度合成 | `VideoEditCompositionBuilder.swift`（三处分支合并成「关键帧 ⊕ 预设 ⊕ 转场」） |
| 导出：路由 | `VideoEditExportGraph.swift`（`isAnimated` → `needsPrerender`） |
| 导出：中间片 | `VideoEditPrerender.swift`（顺带修 §既有 bug） |
| Inspector 面板 | `VideoEditInspector+ClipAnimation.swift`（新，取代 `+VideoFade.swift`） |
| 写入（撤销/实时分离） | `VideoEditProject+ClipAnimation.swift`（新，顺带把 `setVideoFade` 搬过来） |

单文件体积：`VideoEditCompositionBuilder.swift` 已 1122 行、`VideoEditProject.swift`
是点名待瘦身对象 —— **本次新增逻辑一律进新文件**，只在旧文件里留调用点。

预览切片边界（`addAnimationBoundaries` 旁边补）：
- 透明度/缩放/位移都带缓动 ⇒ 在**入/出场窗口内按工程帧加密**（0.6s@30fps = 18 片），
  单侧上限 120 片；
- Wipe 的 reveal 是**线性**、裁切矩形对 reveal 也是线性 ⇒ 只要窗口两端两个边界，
  不加密（片内线性，端点求值＋斜坡就是精确重建）；
- 半透明/裁切会让默认合成器切到混合路径 ⇒ `needsOpaqueBase` 判据要把预设动画算进去，
  否则未覆盖区是零填充 YUV 的暗绿色。

## 既有 bug：预渲染段的画面渐变没让位给转场

`AnimatedClipPrerenderer.renderMain/renderOverlay` 造的临时时间线里只有它自己、
`transitionAfter = .none`，于是 `VideoFade.effective(hasTransitionBefore:false,
hasTransitionAfter:false)` **把本该让位给转场的渐变烤进了中间片**；预览侧
（`VideoEditCompositionBuilder` 拿的是真实接缝）是正确让位的 ——
「预览让位、成片还在淡黑」。今天要凑齐「关键帧 + 画面渐变 + 该边有转场」才撞得上，
2A 之后 `In=Fade + Out=Rise` 这种组合会让它变成常态，所以这一刀顺手修：
把**仲裁过的**窗口传进预渲染。按仓库规矩补 `docs/bugfixes/` 一篇 + 一条
反向验证过的回归守卫（`checks/VideoFade` 已经在真跑导出抽帧，加场景即可）。

## 导出代价（要让用户看得见）

预渲染是**按段整条渲**的：一张 60 秒的图加 0.6 秒的 Rise，也要渲一条 60 秒
ProRes 422 中间片（上层轨还要 fill+matte 两条）。图片段有 60 秒上限（`stillDuration`），
最坏 ~1GB；**视频段没有上限**，10 分钟的段会渲出十几 GB。

- 第一刀：复用现成机器（整段预渲染），面板上对长段给一句提示。
- 第三刀（可选）：**窗口化预渲染** —— 只渲入/出场窗口，中间段照走原素材，
  把长视频的代价打掉。留到实测之后再定。

## 分刀

| 刀 | 内容 | 验收 |
| --- | --- | --- |
| 1 | 模型 + 求值器 + 面板（吞掉画面渐变）+ 预览切片 + 导出路由 + v15 + 修既有 bug + 架构文档 | `check-project-file.sh`（往返 + v15 闸门）、`check-preview-composition.sh`（真取帧）、`check-video-fade.sh`（含 bug 回归，反向验证过）、`check-all.sh` 全绿 |
|   | **已完成**（2026-09-18）：实施状态以 [architecture 文档](../architecture/clip-animation.md)和检查结果为准。 | |
| 2 | `checks/ClipAnimation`（真跑一次导出抽帧，与预览逐场景对账）+ 批量套用到所选段 | 新 check 进 `check-all.sh`；预览/成片逐场景同账 |
|   | **已完成**（2026-09-18）：40 项对账全绿，反向验证过 —— 把导出路由改回只认关键帧，擦除那组当场变红（预览在擦、成片在淡）。批量套用见 [architecture 文档](../architecture/clip-animation.md#批量套用多选)。 | |
| 3（可选） | 窗口化预渲染；Ken Burns / Breathe（拍板第 5 条推迟的） | 导出时长与中间片体积实测对比 |

## 人工回归清单（自动化够不着的）

- 五种效果各自在「铺满画布的主轨图」和「角落里的上层轨 PNG」上各看一遍，
  确认没有黑边闪烁、没有位置跳变。
- 动画播放时选中框**不跟着飞**（动画是叠在基准上的偏移，不改存下来的摆放值）。
- 主轨接缝有转场时，那一侧的入/出场不生效，面板当场有说明。
