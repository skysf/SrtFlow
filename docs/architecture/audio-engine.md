# 音频引擎：时间线的声音自己播、自己渲

> 2026-10-01 起（PR1a：引擎本体 + 离线渲染 + 等价自检；PR1b：接进 App，**开关默认关**，正式版的声音仍走 AVPlayer 的合成）。
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
| `TimelineAudioEngine.swift` | 图（每轨一个 `AVAudioSourceNode` → mainMixer = 总推子，另有一个静音的时钟节点）、引擎时钟（只从渲染块的时间戳来）、播放头锚点、实时的 play / pause / seek、换配置 / 只换增益 / 让路 / 静音、离线整段渲染 |
| `PlaybackAudioSource.swift` | 时钟驱动引擎的那几个方法（协议，不依赖任何东西，`PlayerClock` 的自检只编它） |
| `AudioEngineFlag.swift` | 迁移期的开关：`SRTFLOW_AUDIO_ENGINE=1` 或 `defaults write com.srtflow.SrtFlow audioEngine -bool YES`；默认关 |

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
8. **引擎的时钟只从渲染块的时间戳来**（节点的 48 kHz 域）。`outputNode.lastRenderTime` 是声卡自己的采样率
   （这台机器 44.1 kHz），拿它算位置播放头会以 0.92 倍速走：2026-10-01 冒烟欠载 51k 帧、视频对表 60 次。
   一个静音的时钟节点一直挂着，没有一条轨出声的时间线也有人每拍更新时钟。

## 三、接进 App 的样子（PR1b，开关开着时）

- **声音是主时钟。** `PreviewAudioEngineHost`（VideoEditProjectAudioMix.swift）在第一次重建预览时建引擎、起图、
  `PlayerClock.attachAudioSource`；从此播放头每 50 ms 从引擎读（`observePlaybackTime` 仍是唯一入口），
  播放器的周期回调只用来对表：视频和引擎差过一帧、连着两拍，就 `setRate(_:time:atHostTime:)` 把视频重新钉到
  引擎的时间表上（`driftCorrections` 计数，冒烟结果里有；修完时钟之后 32 秒 4 次 seek 是 0 次）。
- **开播 / seek 都只是改几个数**：`PlayerClock.play()` 先让引擎从播放头起播，再 `setRate` 让视频从此刻起跟；
  播放中 seek 同样 —— 引擎一个 IO 缓冲就出声，视频自己定位、定位要多久就晚多久赶上来（不改时间表）；
  停着 seek 照旧精确定位 / 链式扫帧。暂停 = 引擎锚点钉住 + 播放器 pause。
- **合成里不插音轨**：重建预览时把 builder 建出来的音轨拆掉（`removeTrack`），audioMix 不挂、电平表的 tap 不建
  —— 播放器只剩画面，seek 才快。成片不受影响（`ExportMixdown` 自己再建一份带声音的合成）。
- **快路径和即时试听走配置**：`refreshAudioMix` / `previewAudioLive` 开关开着时算一份 `AudioEngineConfig`
  交给 `updateGains`（结构没变只换增益，流不重开；结构变了退到 `replace`）。
- **试听让路**：`AudioLibraryAudition` 压播放器音量的同时让引擎的总推子乘同一个让路量。
- **冒烟静音**：`SRTFLOW_SMOKE_MUTE` 也让引擎静音（渲染照跑，输出不出声卡）；结果里带 `audioEngine`
  （开没开、欠载几帧、视频对了几次表）。
- 已知：每次 seek / 开播之后头一拍（约 10 ms）环里还没有数据，当静音（欠载计数里能看到，32 秒 6 次 seek
  共 2505 帧）；电平表在这条路上还是空的、声音场景不生效、变速会变调 —— PR2。

## 四、还没做的（按方案的刀）

- PR2：声音场景与余音、电平表、变速保音调（现在变速是「当成采样率 × speed 重采样」，音调会变）、seek 后第一拍的预填。
- PR3：成片切到引擎离线渲染、开关默认开、删旧路。

## 五、回归

`scripts/check-audio-engine.sh`（`scripts/check-all.sh` 第 4 组，要 ffmpeg 造正弦素材）：八条时间线
（音频轨 + 推子 + 总推子、渐入渐出、音量曲线、主轨叠化、主轨接缝零头、静音段 + 隐藏轨 + 主轨推子、上层轨、
44.1 kHz 单声道）两边各渲一遍，逐 10 ms 窗口比 RMS、整段 RMS、帧数正好、零欠载，空时间线没有轨。

反向验证（2026-10-01）：渲染块不乘段的增益 → 渐变 / 曲线 / 叠化三组红（792 / 690 / 192 个窗口）；
喂样把素材起点读错 100 ms → 四组红（段尾一边有声一边静音）。恢复后 49 项全绿。

进程内冒烟（南极工程拷贝，`SRTFLOW_AUDIO_ENGINE=1`，播放 32 秒 + 4 次播放中 seek + 暂停 / seek / 播放）：
引擎开着时进程 CPU 约是关着时的一半（16.8 s vs 35.9 s），视频对表 0 次，欠载只有每次 seek 的头一拍。
人工回归（开关开着）：播放中点时间线声音是否立刻接上、暂停 / 播放是否立刻、视频和声音对不对口型、
拖推子 / 音量线时声音是否跟手、试听音乐时时间线是否让路。
