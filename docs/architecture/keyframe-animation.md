# 关键帧动画：源时间锚定、切片规则、fill+matte 预渲染

> 2026-08-04 引入。改关键帧模型（VideoEditAnimation.swift、VideoEditKeyframeEasing.swift）、预览切片
>（CompositionBuilder、KeyframeSliceTimes）、导出预渲染（VideoEditPrerender.swift）之前必读。
> 相关：[preview-free-transform](preview-free-transform.md)、[限幅 + 缓动方案](../plans/2026-09-30-export-limiter-and-easing.md)。

## 模型（VideoEditAnimation.swift）

- 四行可动画：Position（centerX+centerY）、Scale（width+height）、Rotation、
  Opacity —— 共六条 `KeyframeTrack`，挂在 `EditClip.animation: ClipAnimation?`。
- **关键帧锚在源时间上**（`Keyframe.time` 和 `sourceStart` 同一把尺）。
  这一条定了，变速/裁头尾/分割全都自动正确：分割后两半带同一份轨、各播
  自己窗口内的段落、接缝数值连续（有 check 守着）。时间线 ↔ 源的换算走
  `sourceTime(atTimeline:)` / `timelineTime(atSource:)`。
- 两帧之间按**起点那帧的曲线**插值（默认线性，见下面「缓动」）、两端夹紧；半帧内重写同一时刻是**替换**不是堆积
  （连续拖动反复落同一帧靠它幂等）。**容差自 2026-08-07 起不再是写死的 1/60s**：
  工程有 24/30/60 可选帧率后，容差=工程半帧，且**分空间** —— source 侧
  `半帧 × |speed|`、timeline 侧只用半帧，详见
  [project-frame-rate.md](project-frame-rate.md)（30 fps 工程的半帧恰为 1/60，
  行为与迁移前一致）。
- 空轨回落到静态字段：`animatedPlacement/Rotation/Opacity(atTimeline:)` 是
  唯一取值口，预览合成、交互框、Inspector 数值都从这里读。
- 工程格式 **v3**；升轨（只导出选中的，`TimelineExportSelection.subset`）丢 animation（相对画布的属性）。

## 缓动（2026-09-30）

- `Keyframe.easing: KeyframeEasing`（`VideoEditKeyframeEasing.swift`）= 从这一帧到**下一帧**那一段用什么曲线：linear / easeIn /
  easeOut / easeInOut（最后一帧的没用）。曲线函数只有 `TextEasing` 一份（easeIn → easeInCubic、easeOut → easeOutCubic、
  easeInOut → easeInOutCubic），这里只是挑。`value(atSourceTime:)` 先算 t 再过曲线；**linear 那条式子和以前逐位一致**（自检钉着）。
- **默认值分两头**：检查器手打的帧默认线性（同 CapCut，老行为不变）；AI 的 `set_keyframes` 没给 `easing` 时一律 easeInOut
  （推镜、位移像人手做的）。`KeyframeTrack.set` 只在给了 `easing` 时才换已有帧的曲线，`setEasing` 只换曲线。
- `clipped` 补出来的头帧接着用被切开那段的曲线、`stretched` 带着曲线走（形状尽量保住；分割、`edit_clip keyframes` 都靠它们）。
- 存盘：linear **不落键**（老工程存一轮 diff 是空的）、不认识的值回落 linear（`LenientCodableEnum`）；任一关键帧 easing ≠ linear 才抬
  **v27**（`requiresFormatVersion27`：旧版打开会退回直线，画面节奏当场不一样）。
- **只对画面的六条轨有意义**：音量曲线（`EditClip.volumeCurve`）也是 `KeyframeTrack`，但预览的 audioMix 斜坡和导出的 `aeval`
  读的都是折线表、不看 easing —— 没有任何入口给音量曲线写 easing，别加。
- 预览切片见下一节第 3 条；AI 见「AI 接口」。回归：`scripts/check-project-file.sh` 第 39 组（`checks/ProjectFile/KeyframeEasing.swift`：
  每种曲线在 0 / ¼ / ½ / ¾ / 1 的值、linear 逐位一致、set / clipped / stretched 的规矩、存盘按需写键 + 老文件 + 往返 + v27、
  切片按帧 / 线性一片不多 / 旋转照旧 / 变速 / 400 片上限）、`scripts/check-mcp.sh` 的 `TrackKeyframeChecks`（默认 easeInOut、给了照给的、
  不认识的报错、读回来每个点带曲线）+ `ConfigChecks` 词表对账、`scripts/check-preview-composition.sh` B2（缓动的缩放真合成：
  片数 = 帧数、四分之一处的面积按曲线只有 0.0625 而线性是 0.16）。

## 交互约定（对齐 CapCut）

- 每行 `‹ ◇ ›`：跳上帧 / 播放头处打·删帧 / 跳下帧；标题行总控四行齐打。
- **行里有帧后，改数值或拖预览框自动在播放头处落新帧**（setPlacement /
  livePlace / setRotation / setClipOpacity 里的分支）；播放头不在段内则
  落回静态字段。
- 删掉某行最后一帧时，把此刻的插值**固化回静态字段** —— 画面不跳。
- 时间线块底边画菱形（全轨并集），只展示不交互（拖动改帧是下期）。

## AI 接口（2026-09-29，用户拍板：按机器的习惯设计）

存储模型不变（关键帧锚在素材帧上），接口按三条规矩来（[案例](../bugfixes/2026-09-29-keyframes-outside-clip-after-ai-edits.md)）：

- **没有隐藏状态**：`get_timeline` 报的关键帧永远在片段现在的范围里 —— `AIKeyframes.summary` 报的是这段范围里实际播的
  （`EditClip.clippingAnimation`：范围外的帧收成两头插值出来的帧，`KeyframeTrack.clipped`）；AI 传的时间夹进片段；
  `split_clip` 两半各只留自己范围里的帧、切点补帧（画面不变）。真人在检查器里裁的段照旧留整条轨，只是报给 AI 时收进范围。
- **意图用参数说**：`edit_clip keyframes` = `keep_frames`（默认：留在原画面上、窗口外的帧收成两头的值）/ `stretch`
  （`KeyframeTrack.stretched`，按新窗口等比重排）/ `clear`；结果里 `keyframes_note` 说明发生了什么。速度变了范围不变，三种都原样。
- **让 AI 少算**：`set_keyframes relative=true`，时间是片段的比例（0 = 第一帧、1 = 最后一帧）。
- **缓动**：`set_keyframes easing`（linear / easeIn / easeOut / easeInOut，词表 `MCPVocabulary.keyframeEasings` 和 `KeyframeEasing` 对账）
  管这一次给的每一段；没给一律 easeInOut。`get_timeline` 报的每个点末尾带那一段的曲线名。

## 预览切片（CompositionBuilder）

指令切片边界在原有转场折点之外追加（规则和数字都在 `KeyframeSliceTimes`，纯值，2026-09-30 从 builder 拆出来）：每个关键帧的时间线时刻；旋转相邻帧
之间按 **≤6°/片** 加密（`setTransformRamp` 是矩阵线性插值，走弦不走弧，
角度大了明显缩水变形）；**带缓动的段按帧加密**（工程帧率；曲线靠密集折线逼近，每片两端的值落在曲线上，
线性段一片不多）；单段上限 400 片；不透明度动画 × 转场衰减是两条
线性通道的**乘积**（二次曲线），转场窗口内按 0.1s 加密。片内一切都线性，
所以每片用两端取值的 ramp 就是精确重建 —— `applyOpacity` 已重构为
「fadeFactor × animatedOpacity」端点求值，别改回分支穷举的老写法。

线性的位置/缩放动画的矩阵插值本身精确（平移/缩放分量独立线性），不用加密。
`coversCanvasOpaquely` 对动画段保守返回 false（叠化走近似路径）。

边界攒齐之后**先落到 1/600 秒的格子上、按格子去重**再铺指令（`CompositionSlices`，2026-09-29）：
关键帧、转场的半程、段的起止挨得再近也不许让指令表空出一格 —— 空一格整个视频合成判无效、预览全黑
（[案例](../bugfixes/2026-09-29-preview-black-slice-boundaries-straddle-a-tick.md)）。求值仍用边界本身的秒。

## 导出：AVFoundation 预渲染（VideoEditPrerender.swift）

ffmpeg 做不了干净的逐帧缩放（流尺寸中途不能变）和透明度插值，所以动画段
在 `plan()` 里先用**预览同一套合成代码**渲成中间片（预览=导出按构造一致），
再当普通素材进 ffmpeg 图：

- **主轨段**：黑底 ProRes 422 一条，`fps=<工程帧率>,setsar=1,format=yuv420p`
  后直接进 concat/xfade 链（帧率取 `state.frameRate`，写死会被
  `checks/no-hardcoded-fps.sh` 拦下）。声音不进中间片，音频链照旧读原素材。
- **画中画段**：默认合成器的 `backgroundColor` **只支持不透明色（alpha 被
  忽略，文档明说）**，透明背景根本出不来 —— 走 fill + matte 双渲染：
  fill 是内容压黑底，**带完整不透明度**（静态 + 动画）；matte 是纯白素材
  （BlackBaseVideoFactory 的白色版）套**同一份**摆放/旋转/不透明度动画压
  黑底，白=可见、灰=半透明、边缘抗锯齿灰阶就是 alpha 渐变。两条的权重必须
  完全对齐——都是 `内容 × coverage × opacity`（fill 多一个真实色因子，
  matte 是纯白所以约掉只剩权重本身）——ffmpeg 里靠这一点才能用 matte 把
  fill 除回真实色，见下面第 3 条。两条的摆放基准都固化成显式 placement
  （matte 的素材尺寸和原素材不同，靠素材推默认布局会各说各话）；关键帧要
  经由时间线时刻**换算到 matte 自己的源轴**（remappedAnimation）。

四个踩过的坑（前两个详见
[2026-08-04-prerender-avfoundation-pitfalls](../bugfixes/2026-08-04-prerender-avfoundation-pitfalls.md)，
后两个详见
[2026-08-05-export-prerender-review](../bugfixes/2026-08-05-export-prerender-review.md)）：

1. 合成里**无内容的空轨**（A/B 双轨是无条件建的）AVPlayer 容忍、
   AVAssetExportSession 直接报 InvalidVideoComposition（表述是
   "Operation Stopped"）—— build() 收尾统一清空轨。
2. 别指望 `backgroundColor` 的 alpha；带透明的产物一律 fill+matte。
3. **fill+matte 合回 ffmpeg 图时，fill 的 RGB 其实是预乘过的**（黑底=0，
   `真实色 × coverage × opacity` 就是预乘的定义），`alphamerge` 只是把这份
   RGB 原样接上 matte 给的 alpha，产物对 ffmpeg 而言是 straight alpha
   语义——直接喂给 `overlay` 默认的 straight 混合，边缘（任何非 0/1 alpha
   处）会被多乘一次权重，画面比正确值暗（50% 覆盖处只有该有亮度的一半）。
   **`overlay` 自带的 `alpha=premultiplied` 选项在这张图上不生效**（它依赖
   帧的 `alpha_mode` 元数据协商，`alphamerge` 不会打这个标记，实测多种内部
   格式组合数值都不对，别再往这个方向试）。正确做法：`blend` 滤镜按 matte
   把 fill 手动除回真实色（`真实色 = 255×fill/matte`，`blend=all_expr=
   'if(gt(B,0),min(255,255*A/B),0)'`）再 alphamerge，交给 `overlay` 的就是
   名副其实的 straight alpha。**这条链子必须满足两个前提，任一个不满足都
   是数值错但不报错**：
   - **fill 和 matte 的权重必须完全一致**（都是 `coverage×opacity`，不能
     一个带 opacity 一个不带）——否则除法商里会残留没约掉的 opacity 因子，
     相当于把 opacity 设置按 `1/opacity` 的倍数抵消掉一部分甚至全部。
   - **matte 的 rgb24 版本必须独立从 matte 的原始输入转，不能从 matte 的
     gray 版本派生**——同一条流喂给两个下游会让 `alphamerge` 拿到的 alpha
     整段跑偏（实测 128 变成 76，ffmpeg 内部原因不明），两条各转各的就
     没事。
4. **`AVAssetExportSession` 是有状态生命周期的对象，`cancelExport()` 只能
   用在已经起跑的会话上**——对一条还没起跑（`.unknown`）的会话先调
   `cancelExport()` 再启动导出，AVFoundation 内部断言失败，抛
   `NSInternalInconsistencyException`（Objective-C 异常，Swift `do/catch`
   拦不住，直接崩进程）。取消令牌（`ExportCancellationToken.startSession`）
   必须把**真正的启动动作**（回调式 `exportAsynchronously`，同步返回时
   导出已开始）放进和 `cancel()` 同一把锁的临界区里执行——取消线程拿到
   锁时只剩「还没起跑（永远不会起跑）」和「已经起跑（cancelExport 合法）」
   两种世界，中间态结构上不存在。**「先原子登记、出临界区再启动」不够**
   （登记和启动之间仍有缝，评审实测能崩）；async 的 `export()` 也**放不进
   临界区**（自带挂起点），换新 API 时必须保住「启动在临界区内」这个性质。

## 回归

`scripts/check-preview-composition.sh`（13 项）：透明度/缩放动画的抽帧
亮度曲线、旋转切片数、主轨预渲染端到端、fill 和 matte 烘焙同一份不透明度、
matte 角落纯黑。`scripts/check-export-alpha-compositing.sh`（4 项）：真跑
一遍项目自带 ffmpeg，验 fill+matte→straight alpha 的边缘混合数值、
「matte 从 gray 派生 rgb24」反例必须明显跑偏、「fill 不带 opacity」反例
也必须明显跑偏（两个反例都是防止坑被「优化」回去）。工程文件侧
（`check-project-file.sh`）：动画往返、v3 版本、插值/变速/分割连续性。
