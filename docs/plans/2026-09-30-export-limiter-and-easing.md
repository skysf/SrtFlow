# 导出真峰值限幅 + 响度报告，关键帧缓动

> 2026-09-30 方案。用户拍板「先做 1 和 2」（限幅、缓动），做完出一版 Beta（0.18.5）让用户真剪一次。
> 执行分三个 PR（第五节）。**当前状态以长期约束文档和代码为准**：
> 限幅与响度 → [成片的声音](../architecture/export-audio-mixdown.md) 第二节第 3 条；
> 缓动 → [关键帧动画](../architecture/keyframe-animation.md)「缓动」一节。
> 相关：[过 0 交给 AAC](../bugfixes/2026-09-30-export-mix-over-0dbfs-into-aac.md)、[阻塞的媒体读取](../architecture/blocking-media-reads.md)、
> [AI 接口（MCP）](../architecture/ai-control-mcp.md)、[配方卡中文稿](2026-09-28-mcp-recipes.md)、[写代码的规范](../architecture/coding-standards.md)。

## 一、目标

两件事，用户 2026-09-30 定的顺序：

- **A. 导出：把硬削换成真峰值限幅器，混音时顺手量出整段响度，两样都报出去。** #102 把过 0 dBFS 的混音在 −1 dBFS 硬削了：
  不失真给 AAC 编码器，但削平本身就是另一种失真。婚礼工程那种「17 个音效叠在音乐上」正是最常见的过顶方式。
- **B. 关键帧缓动。** AI 做的推镜、位移现在都是直线插值，看着像机器做的；加缓动等于所有动画一起升级。

用户没定的按最简单的做（第三、四节写明）。**不做**：响度目标（−14 LUFS 归一）、预览里的限幅。

## 二、拍过的板

| 决定 | 口径 | 理由 |
| --- | --- | --- |
| 先 A 后 B，再出 Beta 0.18.5 | 含 #101 #102 和这两件 | 上次婚礼一晚报了 21 条：真实使用比任何单个功能都值钱 |
| 限幅器只在写 f32 那一步 | 预览走 AVPlayer，不经这条路，**预览不限幅**（已知差异，写进架构文档） | 预览里做限幅要另搭一套（tap 里做），用户没要 |
| 只报响度，不归一 | 面板和 AI 的结果都带 LUFS，用户自己决定推子 | 用户 2026-09-30 明确不做响度目标 |
| 缓动的默认值 | 检查器手打的默认线性（同 CapCut）；AI 没给时默认 easeInOut | AI 做的多是推镜和位移，缓入缓出最像人做的；手打的沿用老行为 |
| 曲线的名字 | `linear` / `easeIn` / `easeOut` / `easeInOut`，存盘和 AI 同一套（同 `crossFade`、`strokeDraw` 的写法） | 一套词表、一条对账 |
| `set_keyframes` 的 `easing` 是整次调用一个 | 不按点给（四个点对象各加一个字段要 600 字，清单预算只剩 39） | 存储仍是每帧一个，检查器（PR 3）能逐段改 |
| 检查器的曲线选择器 | 单独一个小 PR（PR 3） | 一个 PR 一件事 |

## 三、A：限幅 + 响度（PR 1，已实施）

### 查到的事实

- 混音写盘在 `VideoEditExportMixdown.swift`：`FrameSink.append` → 封顶 → 写；读取在 `MediaReadQueue.export`（宽 1）上阻塞跑，
  一块一块流式写，30 分钟立体声 675 MB。**限幅器必须流式**：有前瞻就要一个延迟环，末尾要冲干净，总长度不许变。
- 探针实测（#102）：AVFoundation float 混音完全线性；AAC 编码器收了过 0 的信号成片 RMS 掉 4.5 dB、峰值冒到 +12 dBFS。
  所以封顶必须在写 f32 那一步。
- K 加权已经有一份（`SoundEffectBuffer.maxMomentaryLoudness`，BS.1770 的 48 kHz 系数）；整段响度还要加门限（绝对 −70 LUFS、
  相对 −10 LU）。30 分钟约 18,000 个 100 ms 子块，存得下。
- 配音文件的封顶也是 −1 dBFS（`AIVoiceLevel.peakCeiling`），它自己有一个按 10 ms 格子的小限幅器（一句一个文件、整段在内存里），
  和这里的流式限幅器是两个工具，这次不合并。

### 设计

- 三个纯值类型各自成文件、自检够得着：
  - `ExportPeakLimiter`（流式真峰值限幅）：上限 −1 dBFS，前瞻 5 ms（240 帧），释放约 80 ms。做法：每帧算「要压到多少」
    r = min(1, 上限 / 最响的声道)；前瞻窗内取最小值（单调队列）；再用同样长的滑动平均把台阶变成斜坡（数学上每帧增益仍 ≤ 它自己的 r，
    所以一个采样都不超上限）；往上只按释放时间一阶慢慢回。信号延迟 5 ms，写盘前先攒够前瞻、末尾冲干净，总长度不变。
  - `ExportLoudnessMeter`（BS.1770-4 整段响度）：K 加权 → 400 ms 块、100 ms 步 → 绝对门限 → 相对门限 → 平均。
  - `AudioKWeighting`：K 加权的系数只写这一处，合成音效的最大瞬时响度也改用它。
- `FrameSink` 只负责喂它们、写盘；写出去的采样喂响度表（量的是真写进文件的声音）。
- `Levels` 改成：`peak`（限幅前）、`outputPeak`、`limitedFrames`、`maxReductionDB`、`loudnessLUFS`；压得超过 3 dB
  （`attentionThresholdDB`）才建议降主推子，建议的量 = 压得最深的那一下。
- 面板：成品那一行下面总是显示「响度 −14.1 LUFS · 峰值 −1.0 dBFS」；压过的再加一句橙字「声音有 0.35 秒超过了 −1 dBFS，最多压了
  3.1 dB。把主音量降 3.1 dB 会更干净。」（不到 3 dB 只说前半句）。文案两张表。
- AI：`get_job` 带 `audio_loudness_lufs`、`audio_peak_dbfs`、压过的带 `audio_limited_seconds`、`audio_max_reduction_db`，
  压过 3 dB 以上才带 `note`。`export_video` 的说明不改（清单预算只剩 39 字），规矩写在结果里。

### 验收（`scripts/check-audio-fade.sh` 第 10 组）

- 10a 纯值：没过顶逐采样原样；+6 dB 的 440 Hz 稳态正弦出来是 −1 dBFS 的干净正弦（均方根 = 上限 / √2、和等幅正弦逐采样差 < 2%）；
  50 Hz 过顶不超上限也不被抽扁；尖峰时刻不变、前 5 ms 是单调斜坡（最大一步 < 0.002）、10 ms 后还压着、1 s 后回到原样；
  7 帧分块喂和整段喂逐位一样、各种长度（0 / 1 / 239 / 240 / 241 / 1000 / 10007 帧）总长不变。
  响度表：EBU Tech 3341 的 997 Hz 立体声 −23 dBFS ≈ −23 LUFS、−20 ≈ −20（±0.3）；后接 20 秒静音结果不变；只有左声道低 3.01；
  全静音 nil；分块喂一样；限幅后的响度 = 等幅正弦的响度。
- 10b 真跑导出：两轨各 +6 dB 叠加 —— 限幅前峰值 = 一条轨的 4 倍、压了 > 1 秒、压得最深 = 峰值到 −1 dBFS 的差、要提醒；
  f32 里没有一个采样超过 −1 dBFS 且最响处贴着它；**峰值 / 均方根 = √2**（削平的会接近 1）；整段响度和 ffmpeg 的 `ebur128` 差 < 0.5 LU
  （一条轨、两轨各 +6 各一次）；成片解回来的峰值不冒出 0、响度和混音一致；主推子 0.2 之后一帧不压、峰值线性、响度比一条轨低 1.94 LU。
- 反向验证（2026-09-30）：限幅器不乘增益 → 10a 大片红、10b「f32 没有一个采样超过 −1 dBFS」红；换回硬削 → 10a「均方根 = 上限 / √2」
  「逐采样差 < 2%」红、10b「峰值 / 均方根 = √2」红。

## 四、B：缓动（PR 2 已实施；检查器选择器 PR 3 已实施）

### 查到的事实

- 模型 `VideoEditAnimation.swift`：`Keyframe {time, value}`，`KeyframeTrack.value(atSourceTime:)` 直线插值、两端夹紧；关键帧锚在源时间上，
  变速 / 裁 / 分割都靠它自动对；六条轨挂在 `EditClip.animation`。
- 预览：`VideoEditCompositionBuilder` 把每个关键帧的时间线时刻加进指令切片边界；片内用 `setTransformRamp` / `setOpacityRamp` 线性重建，
  「片内一切都线性」是前提。旋转已经有加密的先例（相邻帧之间 ≤ 6°/片、单段上限 400 片）。边界攒齐后要落 1/600 秒格子去重
  （`CompositionSlices`，别绕开）。导出的动画段走预渲染，用的是同一套合成代码。
- 曲线函数已有：`VideoEditTextEasing.swift`（linear、easeOutCubic、easeInCubic、easeOutBack、easeInOutSine）。
- 格式版本：`VideoEditFormatVersion.swift` 的登记模式（旧版打开会静默丢掉的字段要登记、抬版本）；枚举一律 `LenientCodableEnum`。
- 工具清单预算只剩 39 字（71,961 / 72,000）。给 `set_keyframes` 加 easing 之前先砍别的说明。
- 风格卡里三张让 AI 用 `set_keyframes` 慢推（documentary、cinematic-opening、product-promo）。

### 设计

- 模型：`Keyframe` 加 `easing: KeyframeEasing = .linear`（`LenientCodableEnum`：linear / easeIn / easeOut / easeInOut），意思是**从这一帧到下一帧
  的那一段**用什么曲线。`value(atSourceTime:)` 先算 t，再过曲线（easeIn → easeInCubic、easeOut → easeOutCubic、easeInOut → 新加 easeInOutCubic）。
  `clipped` / `stretched` 带着 easing 走。老工程没有 easing 键 = linear，一个字都不变；登记新的格式版本（任一关键帧 easing ≠ linear）。
- 预览：位置 / 缩放 / 不透明度的段 easing ≠ linear 时按帧加密切片（工程帧率；单段上限沿用 400），旋转照旧 ≤ 6°/片再叠加密。线性段一片不多。
  切片的规则从 builder 拆成纯值 `KeyframeSliceTimes`（builder 登记在基线里只许降，拆出去之后还短了）。
- AI：`set_keyframes` 整次调用一个 `easing`（词表 `MCPVocabulary.keyframeEasings`，和 App 的枚举对账）；AI 没给时默认 easeInOut；
  `get_timeline` 的关键帧摘要每个点末尾带曲线名。风格卡三处慢推加一句「缓动用默认的 easeInOut」（先中文稿再英文）。
  预算：只从 `set_keyframes` 自己的说明里压（四处「Timeline seconds, inside the clip.」、x / y 的说明、四个列表的说明），加完 71,960 / 72,000。
- 检查器（PR 3）：四行下面一行「曲线」菜单（线性 / 缓入 / 缓出 / 缓入缓出），有两帧以上的轨才显示；显示 / 改的都是播放头所在那一段
  （六条轨一起，首帧之前算第一段、末帧之后算最后一段）；文案两张表、菜单不锁宽度。标题行右边已经挤着 ‹ ◇ › 和复原，所以另起一行。

### 验收

插值（每种曲线 t = 0 / 0.25 / 0.5 / 0.75 / 1、两端夹紧、linear 和以前逐位一致）、`clipped` / `stretched` 保曲线、工程文件往返 + 老文件读出来是 linear、
`TrackKeyframeChecks` 加 easing、`ConfigChecks` 词表对账、预览切片：缓动段每片两端的值都落在曲线上、片数 = 帧数。

## 五、顺序

1. 这份方案 + AGENTS 索引，跟 PR 1 一起提。
2. PR 1 限幅 + 响度 → CI 绿合并。
3. PR 2 缓动（模型 + 预览 + 导出 + AI + 卡）→ 合并。
4. PR 3 检查器曲线选择器（小）。
5. VERSION=0.18.5 出 Beta 装上，给用户真剪一次；报上来的问题另起一轮。
