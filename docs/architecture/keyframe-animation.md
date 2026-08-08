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
- 线性插值、两端夹紧；半帧内重写同一时刻是**替换**不是堆积
  （连续拖动反复落同一帧靠它幂等）。**容差自 2026-08-07 起不再是写死的 1/60s**：
  工程有 24/30/60 可选帧率后，容差=工程半帧，且**分空间** —— source 侧
  `半帧 × |speed|`、timeline 侧只用半帧，详见
  [project-frame-rate.md](project-frame-rate.md)（30 fps 工程的半帧恰为 1/60，
  行为与迁移前一致）。
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
