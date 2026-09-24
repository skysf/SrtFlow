# 成片的声音：离线读出预览那份混音

> 2026-09-24 落地。改剪辑导出的声音、`ExportAudioMixdown`（`VideoEditExportMixdown.swift`）、
> `makeAudioMix`、导出图里接音轨的那几行之前必读。方案与探针见
> [声音场景方案](../plans/2026-09-24-sound-scenes.md)。

## 一、一条管线

**成片的声音就是预览那份混音。** 导出时用和预览同一个 `VideoEditCompositionBuilder.build` +
`makeAudioMix` 建出合成，`AVAssetReaderAudioMixOutput` 把整条混音原样读成 raw f32 立体声
48kHz 文件（工作目录里的 `audio-mixdown.f32`），ffmpeg 只负责把它编成 AAC、和画面合在一起。
导出图里**不许再出现任何声音滤镜**（`checks/export-audio-single-pipeline.sh` 钉着）。

以前导出在滤镜图里另搭一整套声音链（每段 atrim → atempo → volume / aeval → afade → adelay，
主轨 concat / acrossfade，最后 amix），和预览的 AVFoundation 混音各算一份，靠一堆「先后顺序」
规矩对齐。用户嫌每个声音功能都要做两遍（「两遍效率很低」），于是只留一条：音量、渐变、曲线、
推子、转场的交叉淡变、首尾定格的静音，以及之后的声音场景，都只在预览这一份里实现。

## 二、七条约束

1. **读的是用户那一份状态。** `render(state:)` 传展开之前的状态，`build` / `makeAudioMix` 自己
   排序、展开转场，**展开只许一次**。导出图 `plan()` 入口会展开自己那一份（画面要用），传给混音
   的是展开之前留下来的 `requested`。
2. **正好 `duration` 秒。** 离线读在最后一个有声音的采样处就停了（最后一截只有画面时会短），
   重采样的段还会短十几毫秒：读短了补静音、长了截掉，和画面一样长 —— 以前的滤镜链靠 `anullsrc`
   补齐，这条账不能丢。一个出声的段都没有时，导出图垫一路 `anullsrc`，成片照样有一条音轨。
3. **中间文件是 f32。** 各轨直接相加、不压不限（同以前的 `amix normalize=0`），和可以过 0 dBFS；
   编码前落成整数就把过载削平了。30 分钟立体声约 675MB，放在导出的工作目录里，导出结束随目录删。
4. **阻塞读取在 `MediaReadQueue.export`**（宽度 1），不进 Swift 并发的线程池
   （[阻塞的媒体读取](blocking-media-reads.md)）。读的途中每拿一块就看一眼取消标记。
5. **变速的保音调算法只有一个常量**：`VideoEditCompositionBuilder.timePitchAlgorithm`（`.spectral`），
   预览的播放条目和混音读取都用它。
6. **按时间戳落位。** 读出来的块按它的时间戳写到文件里的对应位置，缺一截补静音，不许把后面的声音
   往前挪（挪了就是声画不同步）。
7. **导出不挂电平表的 tap**（`meters` 为 nil）。要在 tap 里**改声音**的功能（声音场景），导出照样
   挂它那一份 tap —— 离线读同样会调 tap，这正是「只做一遍」成立的前提。

## 三、和以前比变了什么（2026-09-24 探针实测，都是「成片向预览看齐」）

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
| `scripts/check-audio-fade.sh` | 真跑导出（`plan()` + ffmpeg）量包络，和预览逐窗对：渐变、变速、曲线、推子、接缝；第 6 组断言导出图里没有声音滤镜、混音文件以 f32le 输入接进去；第 6b 组断言正在播的预览换上的 mix（用户状态 + plan）在两种要展开的缝上和成片一致，且符合绝对期望 |
| `checks/export-audio-single-pipeline.sh` | 导出图的真代码里没有声音滤镜；导出图调了混音、接了它的文件；混音读的是 `build` 的合成并挂着它的 audioMix；两边的保音调算法是同一个常量 |
| `checks/transition-handles-wiring.sh` | `makeAudioMix` 自己展开转场（三个预览入口传的是用户状态） |
| `scripts/check-export-frame-rate.sh`、`check-video-fade.sh` 等 | 真导出照常跑通（含没有声音的时间线走 `anullsrc`） |

**反向验证（2026-09-24）**：混音读取不挂 audioMix → `check-audio-fade` 导出那几组的渐变全红、
单一管线守卫点名那一行；在导出图里塞一行 `afade` → 守卫红；撤掉 `makeAudioMix` 里的展开 →
第 6b 组红（见 [案例](../bugfixes/2026-09-24-preview-mix-ignores-transition-expansion.md)）。

**人工回归**（发版前实机）：

- [ ] 一段有渐入渐出、画了音量曲线的口播，导出后和预览逐段听一遍，听不出差别。
- [ ] 有变速段（1.5x / 0.75x）的工程：成片的变速听感和预览一样。
- [ ] 最后几秒只有画面的工程：成片总长不变，结尾那几秒是静音，不是提前结束。
- [ ] 导出进行到「读声音」那一段（进度条还在 0）点 Stop：马上停下，不留临时文件。
