# 2026-10-06 挪了一段音频（或带声音的视频），画面挪了、声音还在原来的地方

## 症状

用户 2026-10-06 报告：在时间线上拖动音频段、或者带声音的视频段，松手之后画面按新位置播，
**声音还停在原来的时间**出。

按根因推出来的触发条件（修复前的自检第 13 组逐条复现了）：

- 同一条轨上挪、**没越过别的段**（这条轨上段的先后顺序没变）→ 声音留在原地；越过了另一段、
  或者拖到别的轨上 → 是对的。
- 之后随便做一个结构性的改动（加 / 删 / 分割一段、按 V 藏一段、加 / 去掉声音场景）→ 全部突然正常，
  所以显得时灵时不灵。
- 主轨磁吸开着时挪主轨块多半是换顺序，主轨上反而不容易撞见；音频轨、上层轨、联动跟着挪的那些最容易撞。
- 同一个洞还会漏：**裁头**（start + sourceStart 变）、**裁尾**（声音按旧的尾巴继续出、或提前停）、
  **变速**、AI 的 `edit_clip` 改入出点、换源（upscale 换文件、素材重链接换路径）。

从引擎接进预览那一天起就有（2026-10-01 PR1b，`5addc75`），之后每个测试版都带着。

## 根因

挪一段之后的链路：`perform` → `differsOnlyInAudioMix` 为 false（位置变了，不是只改音量）→
`scheduleRebuild()` → 重建完 `audioEngineHost.apply(AudioEngineConfig.make(from: snapshot))`
（`VideoEditProject.swift`）→ `TimelineAudioEngine.replace(config:)`。

`replace` 开头有一条快路径：

```swift
if Self.sameStructure(config, new) { updateGains(config: new); return }
```

而 `sameStructure` 只比三样：轨的个数和名字、每条轨上段的 **clipID 顺序**、每段有没有场景。
段在时间线上的 `start / end / sourceStart / speed / url` 一个都不比。挪一段、裁头裁尾、变速、换文件之后
id 和顺序都没变，就被判成「结构没变」，走 `updateGains` —— 它只往喂样线程送 `SegmentUpdate`，里面只有增益、
场景、补偿（`AudioTrackFeeder.swift`）。喂样器的 `track` 是 `let`，每条流（`SegmentStream`）的
`startFrame / endFrame / sourceStart` 在开流时从旧的 segment 抄死、文件按旧的 url 开，之后开新流也照旧的
`track.segments` 开。于是画面（播放器的条目整个重建）挪了，声音还按旧账出，直到下一次真的结构变化
（id 列表变了）才整个重开。

**为什么自检没抓到**：`scripts/check-audio-engine.sh` 的每条时间线都是**新建引擎渲一遍**；
`check-audio-fade.sh` 的 `Envelope.swift` 只在只改增益时调 `updateGains`。没有一条「先按 A 建、再
`replace(B)`、再渲」—— 而引擎的生命周期里 `replace` 比新建走得多得多（每次重建预览都走它）。

**为什么用户到 10-06 才撞上**：这几天 AI 驱动的剪辑多是加 / 删 / 分割 / 定格（id 换了，真重开）；要手动拖一段
带声音的、不越过别的段，才走到这条路，而且下一次结构性改动就把它盖掉了。

判据在两层各有一份：状态那层的 `differsOnlyInAudioMix` 写成「把音量那几样抹平之后两边完全相等」，
它的注释特意警告过**别去枚举「哪些字段算变了」**，枚举的写法每加一个字段就漏一次；引擎那层的
`sameStructure` 恰恰是枚举写法（只数 id 和场景），漏的就是几何。

## 修复

- `AudioEngineConfig.Segment.Structure`（`Sources/SrtFlow/AudioEngine/AudioEngineConfig.swift`）：
  一段开流时就抄死、流活着时改不了的那部分 —— `clipID / url / start / end / sourceStart / speed / hasScene`，
  `Equatable`。增益、场景的参数、补偿不在里面（它们能在流活着时换）。
- `TimelineAudioEngine.sameStructure`（`TimelineAudioEngine.swift`）改成比 `segments.map(\.structure)`：
  几何有一项不同就整条 `replace`（所有轨的流重开，和加 / 删一段走的是同一条路；播放中大约一个 IO 缓冲的静音）。
  只换增益的快路径不变：`refreshAudioMix` / `previewAudioLive` 送来的配置和 `differsOnlyInAudioMix`
  抹平的是同一批字段，都不在 `Structure` 里，照旧走 `updateGains`、流不重开。
- 顺手把 `sameStructure` 从 `private` 放成模块内可见，自检直接对它断言。

没做：只重开挪了的那一段的流、别的流不动（`AudioTrackFeeder` 要能换 `track`）。除了这个 bug 没有第二个用例，
整条重开的代价（一拍静音）和现在每次加 / 删一段一样，先不做（写进 [音频引擎](../architecture/audio-engine.md) 第四节）。

## 验证

- 新加 `checks/AudioEngine/Replace.swift`（`scripts/check-audio-engine.sh` 第 13 组）：A1 一段 880 Hz 占 0–2 秒、
  A2 一段静音的把总长撑到 4 秒；按 A 建引擎、`replace(B)`、离线渲到 B 的总长，必须和直接按 B 建的引擎逐 10 ms
  窗口一样（帧数正好、零欠载）。B 分别是：挪到 1.5–3.5 秒、裁头（从 0.5 秒起）、裁尾（到 1.2 秒）、2 倍速、
  换成 330 Hz 的文件（RMS 比不出谁是谁，数过零）；只改音量的 B 还要是同一个结构、快路径把声音压 6 dB。
- **反向验证**（守卫先于修复跑）：`sameStructure` 只比 clipID 时 11 条红 —— 五个几何用例各两条
  （「两份配置不该是同一个结构」+「N 个窗口一边有声一边静音」：挪一段 592 个窗口、裁头 96、裁尾 156、变速 180，
  都是 `0.000s 参照 −120 dB、引擎 −30 dB` 这种旧位置还在响），换文件那条量到 879.7 Hz（还在读旧文件）；
  只改音量那条两边都绿（快路径没丢）。
- 修复后 `scripts/check-audio-engine.sh` 134 checks 全过（本机约 4 分半，和修复前同一台机器、同一份素材）。
- 实机：修完出测试版给用户在真工程里拖一段带声音的听（自检走的 `replace` 和实时播放是同一个函数，实时只多
  一步 `startFeeders`）。

## 教训 / 防回归

1. **「结构没变」要按开流 / 建对象时抄死了什么来定，不是按 id。** 凡是构造时抄进去、之后不再读配置的字段
   （这里是 `start / end / sourceStart / speed / url`），都是结构的一部分；判「能不能只换参数」的函数要和构造函数
   读同一批字段。合同写进 [音频引擎](../architecture/audio-engine.md) 第二节第 9 条。
2. **同一条判据在两层各有一份时，两份要用同一种写法。** 状态层已经用「抹平之后相等」避开了枚举漏项，引擎层
   却是枚举写法，漏项就落在它这儿。
3. **自检要有「换配置」这一步。** 引擎的生命周期里 `replace` 比新建常见得多，只测新建等于没测换配置；
   以后给引擎加任何「不重开也能换」的快路径，第 13 组要加一条反例（几何变了）和一条正例（只改那个参数）。
