# 成片的声音：预览那个音频引擎离线渲出来

> 2026-09-24 落地「成片 = 预览那份混音」；2026-10-01（PR3a）起渲它的是预览同一个音频引擎。改剪辑导出的声音、
> `ExportAudioMixdown`（`VideoEditExportMixdown.swift`）、`AudioEngineConfig.make`、导出图里接音轨的那几行之前必读。
> 方案与探针见 [声音场景方案](../plans/2026-09-24-sound-scenes.md)、[音频引擎方案](../plans/2026-10-01-audio-engine.md)；
> 引擎本身的合同见 [音频引擎](audio-engine.md)。

## 一、一条管线

**成片的声音就是预览那份混音，由同一个引擎渲出来。** 导出时 `AudioEngineConfig.make(from:)` 从用户那一份状态算出
和预览**同一份**配置（段落、增益、渐变、曲线、推子、场景、变速），`TimelineAudioEngine` 的离线模式（`renderOffline`，
和实时播放是同一张图、同一段渲染代码）把整条时间线渲成 raw f32 立体声 48kHz 文件（工作目录里的 `audio-mixdown.f32`），
ffmpeg 只负责把它编成 AAC、和画面合在一起。导出图里**不许再出现任何声音滤镜**（`checks/export-audio-single-pipeline.sh` 钉着）。

2026-09-24 到 2026-10-01 之间这一步是 AVFoundation 那条路：`VideoEditCompositionBuilder.build` + `makeAudioMix` 建合成、
`AVAssetReaderAudioMixOutput` 读出来。预览换成引擎之后成片也跟着换，不然预览和成片又是两份实现。

以前导出在滤镜图里另搭一整套声音链（每段 atrim → atempo → volume / aeval → afade → adelay，
主轨 concat / acrossfade，最后 amix），和预览的 AVFoundation 混音各算一份，靠一堆「先后顺序」
规矩对齐。用户嫌每个声音功能都要做两遍（「两遍效率很低」），于是只留一条：音量、渐变、曲线、
推子、转场的交叉淡变、首尾定格的静音，以及之后的声音场景，都只在预览这一份里实现。

## 二、七条约束

1. **读的是用户那一份状态。** `render(state:)` 传展开之前的状态，`AudioEngineConfig.make` 自己
   排序、展开转场、滤掉藏起来和静音的，**展开只许一次**。导出图 `plan()` 入口会展开自己那一份（画面要用），
   传给混音的是展开之前留下来的 `requested`。
2. **正好 `duration` 秒。** 引擎按时间线的帧渲到正好 `frames`（最后一截只有画面时渲出来的就是静音）；
   `FrameSink` 照旧补短截长，和画面一样长 —— 以前的滤镜链靠 `anullsrc` 补齐，这条账不能丢。
   配置里一条轨都没有（时间线上没有一个出声的段）时 `.silent`，导出图垫一路 `anullsrc`，成片照样有一条音轨。
3. **中间文件是 f32，写之前过真峰值限幅器（上限 −1 dBFS），限幅前的峰值、压了多久多深、整段响度都要报出去。**
   各轨直接相加、不压不限（同以前的 `amix normalize=0`），和可以过 0 dBFS；引擎渲出来的 float 也不削。可是交给 AAC 编码器的
   信号过了 0 就不可预期（2026-09-30 探针：两轨各 +6 dB 叠加，成片 RMS 比混音掉 4.5 dB、峰值冒到 +12 dBFS、主推子降 3 dB 成片只降 2 dB，
   [案例](../bugfixes/2026-09-30-export-mix-over-0dbfs-into-aac.md)）。第一版（#102）是逐采样硬削；同一天用户拍板换成限幅器
   （[方案](../plans/2026-09-30-export-limiter-and-easing.md)）：
   - **`ExportPeakLimiter`（流式、纯值）**：上限 `defaultCeiling` = 0.891（−1 dBFS，留 1 dB 给编码器的过冲，同配音文件 `AIVoiceLevel.peakCeiling`），
     前瞻 5 ms（240 帧）、释放约 80 ms。每帧算「要压到多少」r = min(1, 上限 / 最响的声道)；前瞻窗内取最小 r（单调队列）；再做同样长的
     滑动平均把台阶变成斜坡 —— 数学上每帧的增益仍 ≤ 它自己的 r，所以**一个采样都不超过上限**；往上只按释放时间一阶慢慢回。
     信号延迟 5 ms：写盘前先攒够前瞻、`flush` 把末尾冲干净，**总长度不变**（第 2 条那本账照旧）。没过顶的地方逐采样原样；
     稳态的过顶正弦出来是等幅的干净正弦，不是方波。
   - **`ExportLoudnessMeter`（流式、纯值）**：BS.1770-4 的整段响度 —— K 加权（`AudioKWeighting`，48 kHz 系数只写这一处，合成音效也用它）
     → 400 ms 块、100 ms 步 → 绝对门限 −70 LUFS → 相对门限 −10 LU → 平均。喂的是限幅之后、真写进文件的采样。只报、不归一
     （用户不要响度目标）。
   - **`Levels`**：`peak`（限幅前）、`outputPeak`、`limitedFrames`、`maxReductionDB`、`loudnessLUFS`；压得超过 `attentionThresholdDB`（3 dB）
     才 `needsAttention`，建议降的量 = 压得最深的那一下。经 `Plan.audioLevels` → `VideoEditExporter.finishedAudioLevels` 到导出面板
     （总是一行「响度 · 峰值」，压过的再一句橙字）和 AI 的 `get_job` 结果（`audio_loudness_lufs`、`audio_peak_dbfs`，压过的带
     `audio_limited_seconds`、`audio_max_reduction_db`，超过 3 dB 才带 `note`）。
   - **预览不限幅**（已知差异）：预览是同一个引擎的实时模式直接出声卡，不经这条路；过顶的地方预览里是线性和（也不削），
     成片是压过的。电平表的红灯照旧管预览。
   30 分钟立体声约 675MB，放在导出的工作目录里，导出结束随目录删。
4. **整段渲染在 `MediaReadQueue.export`**（宽度 1）上同步做：引擎的喂样在这条线程上读文件（`AVAudioFile`），
   不进 Swift 并发的线程池（[阻塞的媒体读取](blocking-media-reads.md)）。每渲一拍看一眼取消标记
   （`renderOffline` 的 consumer 回 false 引擎就停）。
5. **变速的保音调算法预览和成片是同一份**：引擎的 `AudioTimeStretchReader`（AVAudioUnitTimePitch）。
   （2026-10-01 PR3b 之前 AVPlayer 那条路的预览用的是 AVFoundation 的 `.spectral`，是另一种算法。）
6. **按时间线的帧落位。** 引擎从 0 起连续渲，段落的位置在配置里（`Segment.start`），没有「读出来的块带时间戳」
   这回事；段与段之间渲的是静音，不会把后面的声音往前挪（挪了就是声画不同步）。
7. **导出不挂电平表**（`meters` 为 nil）。声音场景的效果链在引擎的渲染块里跑（`SceneBox`），离线和实时是
   同一段代码 —— 这正是「只做一遍」成立的前提（[音频引擎](audio-engine.md) 合同第 7 条、[声音场景](sound-scenes.md)）。

## 三、和以前比变了什么（2026-09-24 探针实测，都是「成片向预览看齐」）

2026-10-01 起渲成片的是引擎。PR3a 时它和 AVFoundation 那份混音逐 10 ms 窗口差 ≤ 0.03 dB（44.1k 单声道重采样 0.29 dB；
变速是两种算法、≤ 0.95 dB）；PR3b 删掉那条路之后 `scripts/check-audio-engine.sh` 改对着纯 Swift 的 oracle 混音器量（差 ≤ 0.027 dB）。
下表是 2026-09-24 从 ffmpeg 滤镜链换到预览混音时量的，「成片向预览看齐」的结论不变 —— 只是现在两边连渲染代码都是同一份。

| | 以前的成片 | 现在的成片（= 预览） |
| --- | --- | --- |
| 音量、渐变、曲线、推子、上层轨 / 音频轨的声音 | — | 相差 ≤ 0.01 dB（AAC 编码本身 ≤ 0.05 dB） |
| 借余料的叠化 | acrossfade | 预览的两条斜坡，差 0.21 dB |
| 变速段 | ffmpeg `atempo` | AVFoundation `.spectral`：稳态正弦差 0.02 dB；语音这种信号逐 50ms 窗口差 1 dB 上下（最大 2.8 dB，在段首）——两种变速算法的差，现在和预览听到的一致 |
| **单声道素材** | ffmpeg 转立体声时每个声道 −3 dB | AVFoundation 把单声道原样放进两个声道：**成片比以前响 3 dB**，和预览一致 |
| 段落在时间线上的位置 | `adelay` 按整毫秒 | 合成的时间刻度 1/600 秒（与预览相同，最多差 0.83ms） |

速度：10 分钟、30 段、4 条合成音轨的时间线读 1.7 秒（357 倍实时，峰值内存 31MB）；30 分钟、
60 段、35 条合成音轨、混着 48k / 44.1k 单声道 / mp3 读 25 秒（75 倍实时，79MB）。

变速段的输出**不能逐位重复**（`.spectral` 两次读能差 0.39 dB），所以自检里凡是有变速的对账都要
留容差；不变速的段两次读逐位相同。

## 四、回归

| 检查 | 守什么 |
| --- | --- |
| `scripts/check-audio-fade.sh` | 真跑导出（`plan()` + ffmpeg）量包络，和预览逐窗对：渐变、变速、曲线、推子、接缝；第 6 组断言导出图里没有声音滤镜、混音文件以 f32le 输入接进去；第 6b 组断言正在播的预览换上的 mix（用户状态 + plan）在两种要展开的缝上和成片一致，且符合绝对期望；第 10a 组（`checks/AudioFade/Limiter.swift`，纯值）：限幅器没过顶逐采样原样、过顶一个采样不超上限、+6 dB 稳态正弦出来是干净的等幅正弦、50 Hz 不被抽扁、尖峰时刻不变 / 前 5 ms 是斜坡 / 1 s 后回到原样、分块喂 = 整段喂且总长不变；响度表按 EBU Tech 3341（−23 → −23、门限、单声道低 3.01）；第 10b 组（`Ceiling.swift`，真跑导出）：过 0 dBFS 的混音限幅前的峰值 / 压了多久多深照实记、f32 里没有一个采样超过 −1 dBFS 且峰值 / 均方根 = √2（不是削平）、整段响度和 ffmpeg `ebur128` 差 < 0.5 LU、成片峰值不冒出 0、成片响度和混音一致、主推子压下来不压且峰值 / 响度都线性 |
| `checks/export-audio-single-pipeline.sh` | 导出图的真代码里没有声音滤镜；导出图调了混音、接了它的文件；混音是 `AudioEngineConfig.make` 那份配置交给 `TimelineAudioEngine(mode: .offline)` 的 `renderOffline` 渲出来的 |
| `scripts/check-audio-engine.sh` | 引擎离线渲染 = 纯 Swift 的 oracle 混音器（12 组，含电平表、场景、变速，[音频引擎](audio-engine.md) 第五节）—— 成片和预览用的就是这一份渲染代码 |
| `checks/transition-handles-wiring.sh` | `makeAudioMix` 自己展开转场（三个预览入口传的是用户状态） |
| `scripts/check-export-frame-rate.sh`、`check-video-fade.sh` 等 | 真导出照常跑通（含没有声音的时间线走 `anullsrc`） |

**反向验证（2026-09-24）**：混音读取不挂 audioMix → `check-audio-fade` 导出那几组的渐变全红、
单一管线守卫点名那一行；在导出图里塞一行 `afade` → 守卫红；撤掉 `makeAudioMix` 里的展开 →
第 6b 组红（见 [案例](../bugfixes/2026-09-24-preview-mix-ignores-transition-expansion.md)）。
**（2026-09-30）**：限幅器不乘增益 → 10a 大片红、10b「f32 没有一个采样超过 −1 dBFS」红；换回硬削 → 10a「均方根 = 上限 / √2」
「逐采样差 < 2%」红、10b「峰值 / 均方根 = √2」红。

**（2026-10-01 PR3a，成片换成引擎渲）**：混音不走 `.offline` 的引擎 → 守卫点名那一行；不用 `AudioEngineConfig.make` →
守卫两行红。换了渲染器之后 `check-audio-fade.sh` 真跑导出的那几组照常全绿 —— 成片的包络仍和预览逐窗一致；只有
「大厅 · 成片 vs 预览」改成对着引擎自己渲的那份比（`enginePCM`，并单声道按 (L + R) / √2，和 ffmpeg `-ac 1` 一个口径）：
tap 那条路在这条 5 秒的时间线上余音载体要被拉长，余音比引擎散得慢（3.3 秒处差 4.2 dB），而用户现在听的预览就是引擎。

**人工回归**（发版前实机）：

- [ ] 一段有渐入渐出、画了音量曲线的口播，导出后和预览逐段听一遍，听不出差别。
- [ ] 有变速段（1.5x / 0.75x）的工程：成片的变速听感和预览一样。
- [ ] 最后几秒只有画面的工程：成片总长不变，结尾那几秒是静音，不是提前结束。
- [ ] 导出进行到「读声音」那一段（进度条还在 0）点 Stop：马上停下，不留临时文件。
- [ ] 几个音效叠在音乐上、故意推过 0 dBFS 的工程：导出面板那一行「响度 · 峰值」出来，橙字说压了多久多深；成片听音效的那几下
      不「啪」也不闷，音乐部分和预览一样响。
