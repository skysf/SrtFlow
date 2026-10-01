# 预览和成片的声音：自己的音频引擎（播放 / seek 无感）

> 2026-10-01 方案。用户的要求：大工程里播放中点时间线、按空格都要「像 FCP 一样无感」。一天的压力测试
> （第三节）量出来：卡的不是视频、不是界面，是 AVPlayer 处理多条音轨的方式，而且是它的固有开销。
> 用户拍板（第二节）：**自己做音频引擎**；视频只做优化媒体，还卡再谈；缓存尽量小。
> 本文是动代码之前给用户看的那一份：数字、架构、时钟怎么对齐、每个功能怎么搬、分几刀、怎么验。
> **当前状态以长期约束文档和代码为准**（做完之后：[推子与电平表](../architecture/audio-mixer.md)、
> [成片的声音](../architecture/export-audio-mixdown.md)、[声音场景](../architecture/sound-scenes.md) 都要改写）。
> 相关：[主线程卡顿日志](../testing/main-thread-stalls.md)、[电平条问播放器要时间堵住主线程](../bugfixes/2026-10-01-meter-current-time-blocks-main-thread.md)、
> [阻塞的媒体读取](../architecture/blocking-media-reads.md)、[写代码的规范](../architecture/coding-standards.md)。

## 一、目标与验收

| 动作 | 现在（南极工程，42 段主轨 + 9 条音轨 64 段，M1） | 目标（2026-10-01 用户定） |
| --- | --- | --- |
| 播放中点时间线 → 声音接着响 | 约 1.0–1.5 秒 | ≤ 1 帧（42 ms @ 24 fps） |
| 播放中点时间线 → 画面出来 | 约 1 秒 | ≤ 2 帧（视频那一半靠优化媒体，另一个方案） |
| 停着按空格 → 播放头开始走 | 约 0.5 秒 | ≤ 2 帧 |
| 按空格 → 图标变 | 偶尔慢半拍（最长 2.4 秒） | 立刻（#117 已修掉大头） |

## 二、拍过的板（2026-10-01 用户）

| 决定 | 口径 |
| --- | --- |
| 做音频引擎 | 要无感就必须做；AVPlayer 的下限是「每条音轨 40 ms、串行」，任何参数都碰不到 |
| 视频不做引擎 | 先做优化媒体（另一份方案）；做完还卡再谈 |
| 成片同步切到引擎离线渲染 | 用户交给我定，按「丝滑优先」+ 一条管线定的：留 AVFoundation 那份混音只为导出，就得继续养一轨一格式、tap 那整套 |
| 迁移期允许开关并存 | 3–4 个 PR 落地，中间用开关护住正式版，最后一刀删旧路 |
| 缓存尽量小 | 音频**不缓存**（直接读原件就够快，第三节）；视频优化媒体只给长 GOP 的源、只转用到的段、上限 10 GB |
| 新场景 | 水下、面具（参考音频我自己找）；场景做成「配方 → 效果链」数据驱动，MCP 词表扩两个词 |
| 验收数字 | 第一节那张表 |
| 顺序 | 心跳日志（#116）→ 本文 → 用户看过再动代码 → PR1 / PR2 / PR3 → 测试版真剪 → 视频优化媒体 |

## 三、量出来的数字（探针都在会话 scratchpad，`seekprobe/probe*.swift`，以后要重跑就按这一节再写）

### 1. AVPlayer 的合成：播放中 seek 的代价 = 每条音轨约 40 ms，串行

同一条合成照 App 的规则搭出来（A/B 主轨 + 2 条上层轨 + 按「轨 × 源格式」开出 22 条合成音轨、每条挂 tap），
播放中随机点 10–30 下，量到画面出来 / 重新在播（中位数）：

| 场景 | 画面出来 | 重新在播 |
| --- | --- | --- |
| 最像 App（26 轨，spectral，有 tap） | 988 ms（p90 1129） | 1451 ms（p90 1576） |
| 只有 22 条音轨 | 858 ms | 1310 ms |
| 22 条音轨、无 tap | 855 ms | 940 ms |
| 音轨装箱到 16 条（同格式装一起） | 640 ms | 1099 ms |
| 音轨装箱到 8 条（全归一成 wav，无 tap，varispeed） | 423 ms | 496 ms |
| 4 条音轨 | 177 ms | 627 ms |
| 22 条轨各只放一整段 wav（没有接缝、没有空档） | 851 ms | 1310 ms |
| 只有 4 条视频轨，原片 | 50 ms（p90 232、最大 288） | 50（p90 173、最大 183） |
| 只有 4 条视频轨，全帧内代理 | 16 ms（p90 41、最大 50） | 52（p90 96、最大 97） |

- 和段数、格式、空档无关（整段 wav 和 89 段一样），是每条轨重搭管线的固定开销。
- **旋钮全部无效**：容差 1 帧、关 `automaticallyWaitsToMinimizeStalling`、`preferredForwardBufferDuration` 0.1、精确时序资产、
  varispeed / timeDomain / spectral —— 855–990 ms。
- 停着 seek 2 ms；「先暂停再 seek 再播」770 ms（暂停后管线的拆卸是异步的，seek 照样等它）。
- 停着按播放：声音 81 ms 回来（varispeed 12 ms），**播放头要 110–530 ms 才开始走**（22 条轨）。
- tap 不拖慢 seek，但让「重新在播」多等约 370 ms。

### 2. 视频：解码速度是硬件上限，自己做引擎最多快 15%

| 素材 | AVPlayer seek 时的解码速度 | 直接喂 VideoToolbox（中间帧不输出） | 一个 GOP 要解多久 |
| --- | --- | --- | --- |
| AI 短片 1080p24，10 秒一个关键帧 | 570 fps | 652 fps | 370 ms |
| 录屏 1080p30，8.3 秒一个关键帧 | 约 356 fps | 374 fps | 670 ms |
| AI 短片 1920×1088 24fps，8 秒一个关键帧 | 约 490 fps | 571 fps | 335 ms |

单文件 seek 到 10 秒片子的 9.9 秒处：原片 418 ms 画面 / 508 ms 续播；转成全帧内 H.264 14 / 33 ms；ProRes Proxy 19 / 39 ms。
录屏前 60 秒：原片 24.3 MB、seek 693 ms；原分辨率 0.5 秒一个关键帧（12 Mbps）83 MB、27–36 ms；全帧内 172 MB、20 ms。
—— 视频的杠杆是关键帧间隔，不是代码层级；细节进「优化媒体」那份方案。

### 3. 音频引擎：三种做法

| 做法（22 条轨，同一批素材） | seek 到全部轨出声 | 66 条轨 | 磁盘 | 播放 CPU |
| --- | --- | --- | --- | --- |
| AVAudioPlayerNode 每轨一个，seek 时停掉重排 | 226 ms | 574 ms | 0 | 2% |
| conform 成 PCM + `AVAudioSourceNode` 按游标读 | 9 ms | 10.5 ms | 约 600 MB | 1% |
| **不缓存：每轨后台线程边解码边预读半秒，seek 时清环重解** | **8.9 ms**（最大 19.6） | 10.2 ms（最大 43） | **0** | 15%（探针写得糙） |

9 ms 就是声卡一个 IO 缓冲（11.6 ms）：seek 只改游标，渲染线程下一拍就从新位置出样。
**选第三种**：不要磁盘缓存；CPU 那 15% 是探针里 1 ms 轮询 + 逐采样取余造成的，正式实现按块拷、按需唤醒会低得多。

### 4. 主线程

真 App 播放 40 秒：主线程平均 36–42% 忙、进程约 110%。心跳看门狗（#116）抓到的卡顿：电平条每秒 300 次
`player.currentTime()` 被播放器队列的锁堵住 2443 / 318 / 213 ms，AVKit Now Playing 874 ms（#117 修掉，修后播放中最长 129 ms）；
还剩 AVKit 自己的 `AVPlayerController` 在暂停那一拍问一次 `currentTime`（578 ms）—— 换裸 `AVPlayerLayer` 才能去掉。
**引擎做完后播放器里没有音轨、它的队列不再忙，这把锁也就没人抢了。**

## 四、架构

```
                 TimelineState（唯一事实）
                        │
        ┌───────────────┴────────────────┐
        ▼                                ▼
 视频：AVPlayer + 只有视频轨的合成     声音：TimelineAudioEngine（本文）
 （builder 不再插音轨、不再 audioMix）   AVAudioEngine 做图 / 设备 / 求和 / 输出
        │                                │  每条时间线轨一个 AVAudioSourceNode
        │  setRate(_:time:atHostTime:)   │  渲染核心（我们的代码）：按游标取样 → 段增益 × 渐变 × 曲线
        │◄───── 时钟：声音是主 ──────────│  → 场景效果链 → 轨道推子 → 电平 → 输出；总推子在 mainMixer
        ▼                                ▼
   AVPlayerView / AVPlayerLayer       声卡（实时）  或  manual rendering → f32（成片）
```

### 1. 分工

- **视频留在 AVPlayer。** `VideoEditCompositionBuilder.build` 只建视频轨 + videoComposition；`AudioMixBuilder`、
  `CompositionAudioTracks`、tap、`SceneTailCarrier` 整条删掉（PR3）。预览画面先用现成的 `AVPlayerView`，
  之后另开一刀换裸 `AVPlayerLayer`（调色和盖一块挂在这一层上，要连着两个 GUI 冒烟一起验）。
- **声音全在 `TimelineAudioEngine`**（新模块，`Sources/SrtFlow/AudioEngine/`，每个文件一件事）：
  - `AudioEngineGraph`：AVAudioEngine 实例、每轨一个 `AVAudioSourceNode`（48 kHz 立体声 float 非交错，**所有轨同一个格式**）、
    mainMixer（总推子）、输出。实时和离线（manual rendering）是同一张图。
  - `AudioTrackReader`：一条轨的后台读线程（普通 `Thread`，不进 Swift 并发池 —— [阻塞的媒体读取](../architecture/blocking-media-reads.md)）：
    按轨道时间线找到此刻的段，用 `AVAudioFile` 读原件、`AVAudioConverter` 转成引擎格式、变速段先离线拉伸（见第六节），
    写进这条轨的环（半秒）；seek = 清环、从新位置重读。
  - `AudioTrackRenderer`：渲染块（实时线程，**不分配、不加锁**）：从环里取这一拍的采样，乘段增益（`GainTable.Sampler`，
    现成的）、跑场景效果链（`SceneTrackRenderer`，现成的、本来就在实时 tap 里跑）、乘轨道推子、量电平（按块峰值，
    写进无锁的单写者单读者槽），输出。
  - `AudioEngineClock`：渲染块每拍推进的位置 + `AVAudioTime` 的 host 时间 → 任何线程都能算出「此刻播放头在哪」，不问任何人。
  - `AudioEngineConfig`：主线程算好的一份纯值（每轨的段表、增益采样器、场景配置、推子），换配置是原子换引用；
    拖推子 / 拖曲线时直接换配置，**不再重建合成、不再算 audioMix**。
- **时钟：声音是主，视频跟。** 开播 / seek 时 `player.setRate(1, time: t, atHostTime: h)` 把视频钉到引擎的 host 时间表上；
  播放中每秒对一次表，差过一帧就软对齐一次（视频合成没有音轨时走 host clock，和声卡时钟的漂移是 ppm 级，预计几分钟差不到 1 ms）。
  `PlayerClock` 改成由引擎喂时间（`observePlaybackTime` 仍是唯一入口），没有视频的工程也照常走。
- **不变的东西**：波形、缩略图、字幕生成的可听快照、AI 的 listen / transcribe / beats 都直接读文件，不经播放器，不动。
  `AudioGain`、`FadeWindow`、`VolumeCurve`、`GainTable`、`SoundScene` 配方、`SceneTrackRenderer` 的 DSP 照用。

### 2. 为什么不是别的

- 不用 `AVAudioPlayerNode`：停掉重排是 10 ms 一条轨（第三节），还是和轨数成正比。
- 不 conform 成 PCM：直接读原件一样快，省 600 MB 磁盘；mp3 的精确定位 `AVAudioFile` 自己会做。
- 不自己解码视频：硬件就那么快（第三节 2）。
- 不做 `AVSampleBufferAudioRenderer` + `AVSampleBufferRenderSynchronizer`（AVFoundation 自己的底层渲染器）：
  它要我们自己解码、自己喂 CMSampleBuffer，比 AVAudioEngine 多一层，没有换来什么。

## 五、时钟对齐怎么验（PR1 的验收）

1. 探针：引擎播 5 分钟，每秒记一次「引擎位置 − 视频 `currentTime`」（这一次允许在探针里调它）：漂移 < 1 帧则软对齐一次都不用；
   否则按实测定对齐周期。
2. 冒烟加步骤：`seek` 之后量「声音从新位置出样」「画面出来」各多少毫秒（看门狗 + 引擎时钟 + `AVPlayerItemVideoOutput`）；
   `key 空格` 之后量「播放头开始走」。这三个数就是第一节的验收，进冒烟结果，人工看一眼。
3. 口型：一段带人声的素材，画面和声音各自导出一帧 / 一拍比时间戳（自检），差 ≤ 1 帧。

## 六、每个功能怎么搬

| 功能 | 现在在哪 | 引擎里 |
| --- | --- | --- |
| 段音量、渐入渐出、音量曲线 | `AudioMixBuilder` 铺 `setVolumeRamp` + 同一张 `GainTable` 给 tap | 同一张 `GainTable.Sampler` 在渲染块里逐采样乘；三条规则（唯一夹紧点、转场仲裁、曲线取代 volume）原样 |
| 轨道推子、总推子、静音、隐藏 | 推子乘进每段 / 总推子乘总表；隐藏不插进合成 | 推子 = 配置里的常数；隐藏 = 这条轨不排段；总推子 = mainMixer.outputVolume |
| 主轨转场的声音交叉淡化 | A/B 两条合成轨各铺斜坡 | 一条轨同时有两段在响就相加（每段自己的读游标和增益），不需要 A/B 槽 |
| 上层视频轨的声音 | 每条一条合成轨 | 每条视频轨一条声音轨（和音频轨同一个类型） |
| 声音场景 + 余音 | tap 里 `SceneTrackRenderer`，段尾垫载体 | 同一份 DSP 在渲染块里跑；段结束后链继续吃静音吐余音，不用垫载体 |
| 电平表 | tap 写环、界面在播放头处读 | 渲染块按块算峰值写无锁槽，界面 30 Hz 读；没有 280 ms 提前量、没有按位置累加 |
| 变速保音调 | `scaleTimeRange` + `.spectral` | 读的那一侧：变速段用 manual rendering 的 `AVAudioUnitTimePitch` 离线拉伸进环（预览和成片同一段代码） |
| 试听的 ducking | 压 `AVPlayer.volume` | 压 mainMixer 的一个 duck 增益 |
| 拖推子 / 拖曲线的即时试听 | 节流 20 次/秒重算 audioMix | 换配置引用，零成本 |
| 成片的声音 | `AVAssetReaderAudioMixOutput` 读合成 → f32 → 限幅 / 响度 → ffmpeg | 引擎 manual rendering 读同一份配置 → f32，后面不变 |
| 一轨一格式、tap 复用、tap 死掉 | 三条规矩 + 两个案例 | **不存在了** |

## 七、分刀

| PR | 内容 | 开关 | 验收 |
| --- | --- | --- | --- |
| PR1a（已合） | 引擎本体：图、喂样线程、环、渲染核心（增益 / 渐变 / 曲线 / 推子 / 总推子）、锚点式时钟、离线渲染；**不接 App** | 无（App 不变） | `check-audio-engine.sh`：八条时间线逐 10 ms 窗口差 ≤ 0.15 dB（实测 ≤ 0.027；重采样 0.287）、帧数正好、零欠载；长期约束 [音频引擎](../architecture/audio-engine.md) |
| PR1b（已合） | 接进 App：开关开时合成里拆掉音轨、`PlayerClock` 由引擎喂时间（声音是主时钟）、视频 `setRate` 钉到引擎并对表、ducking、拖推子 / 曲线换配置、冒烟静音 | `SRTFLOW_AUDIO_ENGINE=1` / `defaults write com.srtflow.SrtFlow audioEngine -bool YES`，默认关 | 冒烟：CPU 减半、视频对表 0 次、欠载只有每次 seek 的头一拍；第五节的三个数等测试版实听 |
| PR2a（已合） | 电平表：渲染块写进同一个环 | 同上 | `check-audio-engine.sh` 第 10 组；冒烟里电平条在画 |
| PR2b（已合） | 场景 + 余音：效果链跟着流，段尾之后喂零 | 同上 | `check-audio-engine.sh` 第 11 组（和 tap 那条路逐窗口比、余音、反向验证） |
| PR2c（已合） | 变速保音调（AudioTimeStretchReader） | 同上 | `check-audio-engine.sh` 第 12 组 |
| PR2d（已合） | 电平表改无锁槽（seek 后第一拍预填判定不做：8 ms 的起声延迟听不出） | 同上 | `check-audio-engine.sh` 第 10 组；冒烟里主线程不再等电平表的锁 |
| PR3a（已合） | 成片切到引擎离线渲染（`ExportAudioMixdown.renderWithEngine`：同一份 `AudioEngineConfig` → `renderOffline` → f32）；开关默认开；`export-audio-single-pipeline` 守卫改成「导出只经引擎」；性能基线登记 `meters.tapCreate` 归零 | 默认开，`SRTFLOW_AUDIO_ENGINE=0` / `-bool NO` 关回 | `check-audio-fade.sh` 导出各组全绿（换了渲染器包络仍和预览逐窗一致）；`check-audio-engine.sh` 84 项 |
| PR3b-1（已合） | 自检先不靠 AVPlayer 那条路：`check-audio-engine.sh` 的参照换成纯 Swift 的 oracle 混音器（ffmpeg 解码 + 逐采样乘增益表）；`check-audio-fade.sh` 的「预览」改成引擎离线渲（快路径 = `updateGains`、电平表 = 槽、钉点 = 增益表自己的不变量） | 不动开关 | 两项自检全绿；反向验证 oracle 不乘推子 → 十条红 |
| PR3b-2 | 删旧路（`AudioMixBuilder` 的 tap 接线、`CompositionAudioTracks`、`TapContext` / `SampleRing`、`SceneTrackRenderer` / `SceneTailCarrier`、开关本身、`meters.tapCreate` 计数）；守卫（transition-handles / timeline-drag / export-audio-single-pipeline）改钉引擎；架构文档改写 | 删掉开关 | 导出自检全绿；性能基线删 tapCreate 键 |
| Beta | 用户真剪 | | 第一节四个数 |
| 之后 | 预览画面换裸 `AVPlayerLayer`；优化媒体（另一份方案） | | |

## 八、风险与已知差异

- **实时安全**：渲染块里一次分配或一次锁都可能爆音。规矩：配置只换引用、环是单写者单读者、DSP 预分配（`SceneTrackRenderer` 已经这样）。
- **读线程**：一轨一条普通线程（不进 Swift 并发池）；22 条线程空转的开销要量；欠载（环里不够一拍）要计数并进冒烟结果。
- **变速的听感**会变（`AVAudioUnitTimePitch` 的 spectral 和 AVFoundation 的 spectral 不是同一份实现），预览和成片一起变、互相一致。
- **两份状态机并存的那几周**：开关关着时一切如旧；开着时旧的 tap 一个都不建。自检两边都跑。
- **时钟**：视频走 host clock、声音走声卡时钟，漂移要量（第五节）；对表只软对齐，不许一秒跳一次。
- **没有视频轨的工程**：播放头完全由引擎驱动，`PlayerClock` 的订阅者不感知区别。
- **内存**：每轨 0.5 秒环 ≈ 200 KB，66 轨 13 MB。

## 九、不做

- 扫帧出声（音频 scrubbing）：仍然静音。
- M/S、EQ、混响参数面板：引擎里加节点很容易，本次不加；新场景（水下、面具）走配方，随 PR2 或单独 PR。
- 预览里的限幅：仍是已知差异（成片有、预览没有）。
