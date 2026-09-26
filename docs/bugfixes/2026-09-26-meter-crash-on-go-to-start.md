# 2026-09-26 播放中按 Return 回到开头，App 在音频线程上崩溃

## 症状

用户装上 0.14.0 试新功能，按了一下 Return（回到开头），App 直接崩溃退出。崩溃报告：
`EXC_BREAKPOINT (SIGTRAP)`，崩在 `AQProcessingTapManager` 线程（音频的 processing tap），
帧 0 是 SrtFlow 自己的代码。

## 根因

用同一版本的未剥离二进制（`.build/arm64-apple-macosx/release/SrtFlow`，UUID 和装进
/Applications 的那个一样）`atos` 符号化：

```
SampleRing.add(position:left:right:now:)          VideoEditAudioMeter.swift:131
AudioMeterEngine.write(...)                        VideoEditAudioMeter.swift:270
TapContext.consume(_:frames:start:)                VideoEditAudioMeter.swift:411
meterTapProcess（tap 的 C 回调）
```

电平表的环形缓冲按**绝对采样位置**记账：`block = position / 256`、`slot = block % 块数`、
`index = position % capacity`。位置是 tap 回调给的时间换算的（`range.start.seconds × 48000`）。
负数取余还是负数 —— 位置 ≤ -256 时 `slot` 为负，第 131 行 `blockIndex[slot]` 越界，Swift 当场 trap；
(-256, 0) 之间 `slot` 是 0、`index` 是负的，第 141 行越界。崩在 131 行 = 那一拍 tap 报的时间
至少比 0 早 5.3 毫秒。

以前没崩过，是因为以前没有「播放中精确跳到 0」这个动作：回到开头（Return / Home，同一个 PR 里
新加的）就是播放不停、`seek(to: 0)` 精确跳过去。

**没查到的：tap 在什么条件下报负时间。** 写了个静音的命令行探针（AVPlayer + 同一种 PreEffects tap +
合成，播放中精确 seek 到 0，打出每一拍的 `range.start`），单轨、加上保音调算法、再加变速段都试了，
跳回 0 之后头几拍都是时长 0 的空转、第一拍有效的时间是 +0.05～+0.07 秒，**没复现出负时间**。用户工程里
多轨、多段、转场、声音场景，哪一样把时间推到了 0 之前没再追。修法不依赖它：负时间从哪来都不许越界。

## 修复

- `SampleRing` 拆进自己的文件 `Sources/SrtFlow/VideoEditMeterRing.swift`（纯值，不依赖 AVFoundation，
  自检能单独编），`add` 开头 `guard position >= 0 else { return }`：0 之前没有时间线，界面读电平也
  从 0 起读（`peak` 本来就 `max(0, from)`），丢掉什么都不会少。
- 查过同一条 tap 链上别的按时间算下标的地方：声音场景（`VideoEditSoundSceneTrack.process`）的下标都
  `max(0, min(frames, …))` 夹过，增益表 `gain(at:)` 对早于第一个点的时间返回 1 —— 都不怕负时间。

## 验证

- `checks/AudioFade/MeterRing.swift`（`scripts/check-audio-fade.sh` 第 8c 组）：往环里加 -300、-256、-255、-1
  四个位置（两种越界各两个），从 0 读的峰值必须还是 0；再加 0 和 255 两个正常采样，峰值照常。
- **反向验证**：临时删掉那行 `guard`，把环的文件和这组自检单独编成一个小程序跑（不用编整个音频自检）：
  `Fatal error: Index out of range`、退出码 133（SIGTRAP）—— 和现场同一个崩法；恢复后通过。
- 没在真机上重放「播放中按 Return」：现场的触发条件没复现出来（见根因），能钉住的是崩溃的那一步。

## 教训 / 防回归

- **从外部回调拿来的时间，拿去当下标之前先问一句「会不会是负的」**。tap、AVPlayer 的时间回调都是平台给的，
  文档不保证单调、不保证 ≥ 0；负数取余在 Swift 里还是负数。长期约束记在
  [推子与电平表](../architecture/audio-mixer.md)（电平表那几条实测约束里）。
- 新加一个「跳到某处」的入口（这次是回到开头），等于给整条播放管线加了一种从没走过的时序；回到 0 这种
  边界值更要多看一眼下游谁拿时间做算术。
- 崩溃报告剥离了符号时，同一次构建的 `.build/.../release/SrtFlow` 就是带符号的那一份（先比 UUID）。
