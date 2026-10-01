# 音频引擎：时间线的声音自己播、自己渲

> 2026-10-01 起（PR1a：引擎本体 + 离线渲染 + 等价自检；**还没接进 App**，App 里的声音仍走 AVPlayer 的合成）。
> 为什么要有它、量过的数字、分几刀见 [方案](../plans/2026-10-01-audio-engine.md)。做完 PR3 之后
> [推子与电平表](audio-mixer.md)、[成片的声音](export-audio-mixdown.md)、[声音场景](sound-scenes.md) 按引擎改写。

## 一、是什么

`Sources/SrtFlow/AudioEngine/`，每个文件一件事：

| 文件 | 管什么 |
| --- | --- |
| `AudioEngineConfig.swift` | 从 `TimelineState` 算出来的纯值：哪条轨、哪一段、从素材哪一秒起、在时间线哪一段出声、段的增益（`GainTable.Sampler`）、轨道推子、总推子、总长 |
| `AudioRing.swift` | 一段声音的环：喂样线程写、渲染块读、无锁；按**时间线的帧**定位；seek 用「新一轮」标记，读者自己跳过去 |
| `AudioSegmentReader.swift` | 按段读原件（`AVAudioFile` + `AVAudioConverter` 转 48 kHz），不缓存 |
| `AudioTrackFeeder.swift` | 一条轨的喂样：一段一条流（环 + 读取器），提前一秒开流、走在播放头前面半秒；seek 各流重读；把活着的流发布给渲染块 |
| `AudioTrackRenderer.swift` | 渲染块：从各流的环里取这一拍、乘段增益（64 帧一块线性插值）和轨道推子、累加 |
| `AudioPublished.swift` | 给渲染块看的「此刻生效的那一份」：原子指针交换，发布方留最近 8 份不放 |
| `TimelineAudioEngine.swift` | 图（每轨一个 `AVAudioSourceNode` → mainMixer = 总推子）、播放头锚点、实时的 play / pause / seek、离线整段渲染 |

## 二、合同

1. **段落和增益的规则只有一份。** `AudioEngineConfig.make` 走的是 builder 插声音的那套判定（整轨 / 单段隐藏、静音、
   还在转静帧的占位块不出声；主轨接缝不到 `mainGapTolerance` 的零头接在上一段末尾；首尾定格留空）和
   `AudioMixBuilder.addVolumeRamps` 那一张增益表（音量 × 渐变 × 曲线，转场交叉淡变的仲裁在 `FadeWindow.previewMainTrack`）。
   自检拿 AVFoundation 的混音当参照逐窗口比，差 ≤ 0.15 dB（重采样的素材 0.3 dB）。
2. **播放头只是几个数。** 渲染块拿引擎的采样时间，按锚点（`PlaybackAnchor`：采样时间 ↔ 时间线的帧）换成时间线位置；
   seek = 发布新锚点 + 各轨喂样从新位置重读；暂停 = 锚点标成不播（出静音，图不停）。不拆任何东西。
3. **渲染块实时安全**：不分配、不加锁、不碰 Dictionary / String；草稿缓冲预分配；流的列表、锚点经 `AudioPublished`
   无锁地取；环是单写者单读者。欠载（环里没有数据）计数在 `underrunFrames`，冒烟和自检看它。
4. **喂样在普通线程上**（阻塞读不进 Swift 并发池，[阻塞的媒体读取](blocking-media-reads.md)）；离线渲染时喂样在
   调用方的线程上同步做（每拍先 `service` 再 `renderOffline`）。
5. **一段一条流**：主轨转场处前后两段相叠、增益各不同，渲染块分别乘再相加；不需要 A/B 槽，也没有
   「一轨一格式」这条规矩（每条流自己转格式）。
6. **音频不缓存**：直接读 mp3 / aac / wav 原件；mp3 的精确定位 `AVAudioFile` 自己做。
7. **离线和实时是同一张图**：成片（PR3）和自检都走 `renderOffline`，和实时播放的渲染块是同一段代码。

## 三、还没做的（按方案的刀）

- PR1b：接进 App（开关 `SRTFLOW_AUDIO_ENGINE`）、视频合成不插音轨、`PlayerClock` 由引擎喂时间、和视频对表、ducking。
- PR2：声音场景与余音、电平表、变速保音调（现在变速是「当成采样率 × speed 重采样」，音调会变）。
- PR3：成片切到引擎离线渲染、开关默认开、删旧路。

## 四、回归

`scripts/check-audio-engine.sh`（`scripts/check-all.sh` 第 4 组，要 ffmpeg 造正弦素材）：八条时间线
（音频轨 + 推子 + 总推子、渐入渐出、音量曲线、主轨叠化、主轨接缝零头、静音段 + 隐藏轨 + 主轨推子、上层轨、
44.1 kHz 单声道）两边各渲一遍，逐 10 ms 窗口比 RMS、整段 RMS、帧数正好、零欠载，空时间线没有轨。

反向验证（2026-10-01）：渲染块不乘段的增益 → 渐变 / 曲线 / 叠化三组红（792 / 690 / 192 个窗口）；
喂样把素材起点读错 100 ms → 四组红（段尾一边有声一边静音）。恢复后 49 项全绿。
