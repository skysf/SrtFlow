# 阻塞的媒体读取不进 Swift 并发的线程池

> 2026-09-23 事故后定下的硬约束。写任何 `AVAssetReader` 读取循环之前必读；在 async 函数
> 或 `Task` 里做其他会卡住线程的事（等信号量、同步 IO、等子进程）之前也要读。
> 案例：[打开工程后缩略图和波形全空](../bugfixes/2026-09-23-waveform-decode-deadlocks-thread-pool.md)。

## 约束

循环调 `AVAssetReaderOutput.copyNextSampleBuffer()` 的读取，**不许跑在 Swift 并发的协作
线程池里**。也就是说，不许写在 async 函数里，也不许包进 `Task { }` / `Task.detached`。
要读的话：

1. 在 async 函数里做完异步的准备工作（`loadTracks`、`load(.formatDescriptions)` 等）；
2. 把「建 reader → `startReading` → 循环读」写成**单独的同步函数**；
3. 交给 `MediaReadQueue`（`Sources/SrtFlow/MediaReadQueue.swift`）去跑：
   - 只要一个结果时：`await MediaReadQueue.run(on: MediaReadQueue.detail) { readTile(…) }`；
   - 读的途中要陆续往外交东西时（比如波形总览边读边画）：在
     `MediaReadQueue.overview.addOperation { … }` 里读，每攒出一份就 `feed.yield`，读完
     `feed.finish()`；async 那一边 `for await` 这条 `AsyncStream`。参照
     `WaveformDecoder.decode`。

## 为什么

- `copyNextSampleBuffer()` 会卡住调用它的线程，一直等到 CoreMedia 在自己那边把下一块
  解出来。CoreMedia 做这份活时，沿用的是调用方的 QoS。
- 协作线程池每个 QoS 只有 CPU 核数条线程，**堵住的不补**。同一档上同时卡着的读取一旦
  凑满核数，这一档就再也派不出线程：CoreMedia 的活排不上队，卡着的读取也就永远等不到
  数据。结果是**死锁**：从此整档 QoS 都不再执行任何东西，同一档的 GCD 活也停，CPU 0%。
- 实测（8 核）：用生产的 `WaveformStore` 同时读 7 个文件，0.23 秒读完；读 8 个就永远不
  返回。同样的循环挪到 `OperationQueue` 上之后，宽度从 1 到 64，43 个文件都能全部读完。
- 跟着一起死的不止读取本身，同一档上的所有 task 都会停。2026-09-23 缩略图就是这样没的：
  取图的 task 在 utility 档，它本身并不阻塞，却一直排不上。要是死的是 userInitiated 档，
  打开工程、扫描字体都会挂住。
- 「限流，但还留在池子里读」不算修好：那是在赌同时卡住的读取永远少于核数。可核数随机器
  变，别处也可能在同一档卡线程。

## 两条队列

| 队列 | QoS | 宽度 | 用途 |
| --- | --- | --- | --- |
| `overview` | utility | 2 | 波形总览，整个文件从头读到尾；打开工程时几十个文件一起排队 |
| `detail` | userInitiated | 2 | 深度放大时读原始采样，一秒一块，用户正盯着看 |

宽度只关系到性能（和播放抢 CPU、内存），和死锁无关。43 个短素材：宽度 1 用 0.92 秒，
宽度 2 用 0.77 秒，3 以上约 0.7 秒。宽度取 2，这样一条被长录屏占住时，另一条照样往下走。

## 例外

- `SubtitleGen/AudioWindowReader.extract`：字幕生成按窗口抽音频，`TranscriptionTask` 里
  严格一个窗口读完再读下一个，同一时刻最多卡住一条线程，凑不满。**哪天要并行抽，先把它
  挪到 `MediaReadQueue`。** 守卫的白名单里写着同样的理由。

## 同类的别的阻塞

问题不限于 `AVAssetReader`。在 async 函数里等信号量、`waitUntilExit()`、
`readDataToEndOfFile()`，都会占住池子里的线程。要不要死锁，看的是**等的东西需不需要同一档
的线程**：

- 等外部进程（比如 `MediaProbe` 退回 ffmpeg 解析的那条路）不会死锁，只是占着线程；
- 等本进程里别的活（信号量、CoreMedia 解码）会死锁。

拿不准的，一律按「会死锁」处理，挪出池子。

## 回归

| 检查 | 守什么 |
| --- | --- |
| `scripts/check-waveform.sh` 第 7 节 | 同时读 `min(40, max(16, 2 × 核数))` 个文件，总览和原始采样块各一轮，必须全部读完；看门狗跑在普通线程上，30 秒没读完就判红（死锁时 await 永远不回来，没有看门狗的话守卫只会挂住，不会变红） |
| `checks/blocking-media-reads.sh` | `copyNextSampleBuffer` 写在 async 函数里就红（白名单只有 `AudioWindowReader`，理由见上）。已知盲区：同步函数里再包一层 `Task { }`，这条看不出来 |

**人工回归**（自动化够不着的真实工程，发版前实机验证）：

- [ ] 打开一份素材数多于 CPU 核数的工程（比如 `AI_Video_SouthPole` 那份，43 个素材）：
      几秒之内，所有视频块都出缩略图，所有音频块都出波形。
- [ ] 放大到按帧显示，在叠着好几条音频轨的位置来回滚动：波形逐渐变清楚，界面不卡，
      不留空块。
