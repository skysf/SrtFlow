# 2026-10-01 播放中按空格，播放 / 暂停图标慢半拍：电平条每秒 300 次问播放器要时间，被播放器的锁堵住主线程

## 症状

用户在南极工程（42 段主轨、9 条音轨 64 段、合成里 22 条音轨）里播放时按空格，播放 / 暂停图标
**有时候**要等一下才变；不是每次，也不是改完东西才有，纯播放中就有。

## 根因

- 探针先排除了播放器本身：`AVPlayer.pause()` / `play()` 调用本身 0 ms，rate 的 KVO 0–2 ms。
- 真 App 播放 40 秒，主线程平均只有 36–42% 忙（`ps -M`）；「有时候」说明是零星的长卡顿，平均值看不见。
  进程外的 `sample` 挂不上这个 App（调用图是空的），所以写了
  [主线程心跳看门狗](../testing/main-thread-stalls.md)（PR #116）让 App 自己抓。
- 看门狗第一次跑就抓到了：播放中主线程卡 **2443 ms、318 ms、213 ms**，栈都是
  `TrackMeterBars` 的 `TimelineView` 闭包 → `-[AVPlayerItem currentTime]` →
  `FigPlayerAsyncDispatchToPlayerQueue` → `pthread_mutex_lock`。电平条每条轨每秒 30 次、十条轨
  每秒 300 次在主线程上调 `clock.player.currentTime()`；它要拿播放器内部那把锁，而多轨合成播放中
  播放器自己的队列正忙着（栈的另一头是 `FigAudioUnitRenderPipelineCreate` 一类的音频管线活），
  主线程就排在后面等。空格按下去，按键事件排在这 2.4 秒后面。
- 同一把锁还有第二个主线程读者：AVKit 的 `AVPlayerView` 默认往系统「正在播放」报状态
  （`AVNowPlayingInfoController` → `canSeekChapterForward` → `currentTime`），抓到一次 **874 ms**。
- 为什么以前没人看见：小工程里播放器的队列几乎不忙，锁随手就拿到了；22 条音轨 + 22 个 tap
  才把它忙到能堵住主线程。性能 ratchet 数的是「做了多少件活」，等锁不算活，所以 ratchet 也看不见。

## 修复

- `PlayerClock.estimatedTime`（`VideoPreviewView.swift`）：播放头**不问播放器**，用最近一跳
  （时钟的周期回调，每 50 ms 一次）加上从那一跳到现在过了多久，最多补一跳；停着就是最近一跳。
  算术是纯值 `PlaybackTimeEstimate.estimate`，`checks/PlayerClock/main.swift` 第 12 组钉着。
- `TrackMeterBars`（`VideoEditTrackFader.swift`）读 `clock.estimatedTime`。
- `PlayerViewRepresentable`：`updatesNowPlayingInfoCenter = false`。剪辑器也不该出现在系统的媒体控制里。
- 扫描守卫 `checks/player-time-no-sync-read.sh`（check-all 第 1 组）：`Sources/SrtFlow` 里不许再出现
  `currentTime()`；Now Playing 必须关着；电平条必须在读 `estimatedTime`（扫空判红）。

## 验证

- `scripts/check-player-clock.sh`：第 12 组五条（停着、播放中补 20 ms、回调晚到最多补一跳、时钟倒退、
  没收到过回调）。
- `checks/player-time-no-sync-read.sh`；反向验证：把电平条改回 `clock.player.currentTime().seconds` → 红，
  把 `updatesNowPlayingInfoCenter = false` 删掉 → 红，恢复后绿。
- 进程内冒烟（南极工程拷贝，播放 40 秒，`play.out.json` 的 `stalls`）：修前播放中 5 次卡顿、最长 **2443 ms**，
  `currentTime` 的栈四次（2443 / 318 / 213 / 874 ms）；修后播放中 3 次、最长 **129 ms**，电平条和 Now Playing 的栈
  一次都没有了。注意冒烟跑的是 debug 构建，`SampleRing.peak`、malloc 那种百毫秒的栈是没优化的代码，release 没有。
- **还剩一处**：按下暂停那一拍 AVKit 自己的 `AVPlayerController updateAtMinMaxTime` 在主队列上问了一次 `currentTime`
  （578 ms，播放器正在拆 22 条轨的音频管线）。`controlsStyle = .none` 也拦不住它，那是 `AVPlayerView` 内部的控制器；
  要去掉它得把预览画面换成裸的 `AVPlayerLayer`，另开一个 PR（调色和盖一块都挂在这一层上，要连着那两个 GUI 冒烟一起验）。
  音频引擎做完之后播放器里没有音轨、它的队列不再忙，这把锁也就没人抢了。

## 教训 / 防回归

- **播放器的 getter 不是免费的。** `currentTime()` 看着像读一个数，其实是同步跨队列拿锁；播放器一忙它就是
  一次不定长的等待。界面要的时间只从回调来（`PlayerClock.time` / `estimatedTime`）。长期约束写进
  [推子与电平表](../architecture/audio-mixer.md) 第三节第 9 条。
- **平均值看不见的卡顿要逐次抓。** 主线程 40% 忙和 2.4 秒的卡顿并不矛盾；看门狗抓到栈之前，
  「电平条每秒 500 次重绘」这种账上的大头其实是无辜的。
- **AVKit 的便利功能自带主线程读者。** 用 `AVPlayerView` 时 Now Playing 默认开着，关掉它是一行。
