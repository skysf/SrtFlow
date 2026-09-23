# 2026-09-23 打开工程后缩略图和波形全空：读 PCM 的阻塞循环把线程池堵死

## 症状

用当天 21:49 装的 0.12.0 打开 `AI_Video_SouthPole/Edit.srtflowproj`（43 个素材：25 段主轨
视频，外加一堆配音和音效）：

- 视频块只有一块深色的底，**没有缩略图**；
- 音频块只有那条黄色的音量线，**没有波形**；
- 等多久都不出来，进程 CPU 0%。

预览照常播放，转场库的预览图也照常显示，所以文件本身读得了。只在**一次要读很多个
文件**时出现：导入一两个素材、素材少的工程都正常。当天加这两个功能时的自测没碰到。

## 根因

波形在 245ca47（当天 16:04）改成「一个文件读一次」之后：

- `WaveformStore.peaks(for:)` 每遇到一个新文件就开一个 `Task.detached(priority: .utility)`，
  **不限并发数**；
- `WaveformDecoder.decode` 是 async 函数，**在里面循环调
  `AVAssetReaderTrackOutput.copyNextSampleBuffer()`**。这是个阻塞调用：它卡住当前线程，
  一直等到 CoreMedia 在自己那边把下一块解出来。

Swift 并发的 task 跑在协作线程池上。这个池子每个 QoS 只有 CPU 核数条线程（这台机器
8 条），**线程堵住了系统不补**。打开工程时 43 个文件同时开读：最先进入读取循环的 8 个，
把 utility 这一档的 8 条线程全部卡在 `copyNextSampleBuffer` 上。CoreMedia 要给它们解码，
那份活沿用 utility 的 QoS，可这一档已经派不出线程了。于是这 8 个读取永远等不到数据：
**死锁**。

证据（都是在真 App 或独立二进制里量出来的）：

1. **打日志**：43 条 `DECODE start`，一条 `loop end` 都没有。
2. **心跳**：另起一条普通线程，每秒往 `.utility`、`.userInitiated`、默认优先级各派一个
   Task，再往 GCD 的 `.utility` 丢一个 block。userInitiated 和默认优先级的每秒都响，
   **utility 的 Task 和 GCD block 一次都没跑**，整档 utility 都停了。
3. **线程栈**（`arch -arm64 sample`，见下文「查的过程」）：`com.apple.root.utility-qos.cooperative`
   上**恰好 8 条线程**，全都停在
   `WaveformDecoder.decode → -[AVAssetReaderTrackOutput copyNextSampleBuffer] → FigSemaphoreWaitRelative`。
   CoreMedia 的 `readerOfflineMixer`、`audioqueue.source`、`audiomentor` 各 8 条，也全在等
   信号量。
4. **临界点**：把生产的 `WaveformStore` 编进独立二进制，同时读 N 个文件。N = 6、7 时
   0.23 秒读完；N = 8、9、12、43 时永远不返回。8 正是这台机器的核数。用 ffmpeg 现造的
   WAV 也是 7 个过、8 个死，和编码格式无关。

**缩略图为什么也没了**：`ThumbnailTileCache` 取图的 task 也是
`Task.detached(priority: .utility)`。它自己不阻塞（`AVAssetImageGenerator.image(at:)` 是
async 的），但 utility 这一档已经没有线程了，它根本没有机会开始跑。一个死锁，两种症状。

**同样写法的第二处**：深度放大时读原始采样块的 `WaveformDetailCache`（0ecf0af），也是在
`Task.detached(priority: .userInitiated)` 里循环调 `copyNextSampleBuffer`，每次请求开一个
task。独立二进制实测：同时要 7 个文件的块，0.22 秒全部回来；8 个就永远不回来。这次
死的是 userInitiated 这一档，打开工程、扫描字体都在这一档上。放大时屏上只要有 8 段以上
带声音的块就会踩到。还没人踩到，这次一起修了。

## 修复

- 新文件 `Sources/SrtFlow/MediaReadQueue.swift`：两条 `OperationQueue`，用的是 GCD 的普通
  线程，不是协作线程池。`overview` 是 utility、宽度 2；`detail` 是 userInitiated、宽度 2。
  `run(on:_:)` 把一段阻塞的读取交过去，再 await 结果。
- `WaveformDecoder.decode`：async 里只做找音轨、读声道数。读 PCM 的循环挪进同步函数
  `read(asset:track:sourceChannels:emit:)`，放到 `MediaReadQueue.overview` 上跑。读的途中
  攒出的快照经一条 `AsyncStream` 送回来，按顺序 publish。循环里原来那句
  `Task.isCancelled` 是死代码（这个 task 从来没人取消，挪到 GCD 线程上更是永远为 false），
  删掉了。
- `WaveformDetailCache.read`：同样拆成两段，async 的找音轨，加上同步的 `readTile`；
  `readTile` 经 `MediaReadQueue.run(on: .detail)` 跑。
- **为什么不是「限个流，但还在协作线程池里读」**：只要阻塞读取还在池子里，就是在赌
  「同时卡住的永远少于核数」。可核数随机器变，别处也可能在同一档卡住线程。挪出去之后，宽度就只关系到性能了。同一个实验挪到 `OperationQueue` 上，
  宽度从 1 到 64，43 个文件都能全部读完：宽度 1 用 0.92 秒，2 用 0.77 秒，3 以上约 0.7 秒。
  这里取 2。
- SDK 里 `AVAssetTrack` 没标 Sendable，交给读取线程时用 `nonisolated(unsafe)` 标明：它是
  只读的，交出去之后这边不再碰它。

长期约束写在 [阻塞的媒体读取](../architecture/blocking-media-reads.md)。

## 验证

- **真 App**：debug 构建，用 `SRTFLOW_SMOKE_PROJECT` 打开同一份工程的拷贝（原文件没动）。
  修之前，50 秒过去仍然全空、CPU 0%；修之后，一打开缩略图和波形就出来了，立体声拆成
  两条，视频块底部的波形带也在。按 8 下 ⌘= 放大到按帧显示，缩略图逐帧铺满，波形照常画。
- **独立二进制**（编的是生产源文件）：修后，8 个文件 0.31 秒读完，工程里全部 43 个 0.74 秒
  读完，无失败；原始采样块 8 个 0.22 秒回来，43 个 0.37 秒。
- **回归守卫** `scripts/check-waveform.sh` 第 7 节：同时读 `min(40, max(16, 2 × 核数))` 个
  文件，总览和原始采样块各一轮；看门狗跑在普通线程上，30 秒没读完就判红。反向验证：
  - 只撤掉总览那一半：`FAIL 同时读 16 个文件的波形（8 核），30 秒没读完…`，退出码 1；
  - 只撤掉原始采样块那一半：`FAIL 同时要 16 个文件的原始采样块（8 核），30 秒没读完…`，
    退出码 1；
  - 恢复后：36 checks, 0 failures。
- **扫描守卫** `checks/blocking-media-reads.sh`：`copyNextSampleBuffer` 写在 async 函数里就红。
  反向验证：两处都撤回，两处都被点名，退出码 1；去掉白名单，`AudioWindowReader.swift:87`
  被点名（签名跨了好几行也认得出）。
- **回归面**：全仓只有三处调 `copyNextSampleBuffer`。这次修的两处已经挪走。第三处是字幕
  生成的 `AudioWindowReader`，它严格一个窗口一个窗口地读，同一时刻最多卡住一条线程，
  凑不满；记为守卫的白名单，理由写在守卫里。
- `scripts/check-all.sh` 全绿（通过 34 项，失败 0 项）。

## 查的过程（值得记的两件事）

1. **「一个都不出来」，第一反应是 Canvas 画错了**：两样东西当天都改成了按
   `clipBoundingRect` 只画可见的那一段。但截图里缩略图条的深色底是画出来了的，说明
   绘制那一步走到了，缺的是数据。顺着数据打日志，才看到「开始读，却从不读完」。
2. **Rosetta 终端里看不到线程栈**：`sample <pid>` 刷一屏 `failed to get thread state`，
   call graph 是空的；`lldb -p` 报 `debugserver is x86_64 binary running in translation`。
   改用 `arch -arm64 /usr/bin/sample <pid> 1` 立刻拿到完整的栈。在那之前，是靠「心跳」
   定的性：普通线程每秒往各个 QoS 各派一个 Task，哪一档不响，就是哪一档死了。这个办法
   不需要调试器，已经写进 [GUI 冒烟流程](../testing/gui-smoke-testing.md)。

## 教训 / 防回归

1. **会卡住线程的调用，不许放进 async 函数**：`copyNextSampleBuffer`、等信号量、同步 IO
   都算。Swift 并发的线程池是按「没有人阻塞」设计的，堵住的线程不补。阻塞读取的数量
   一旦随数据增长（每个文件一个），迟早会凑满核数。长期约束见
   [阻塞的媒体读取](../architecture/blocking-media-reads.md)。
2. **回归场景要覆盖「很多个一起来」**。原来的波形自检读完一个文件再读下一个，永远凑不满
   线程池，所以一直是绿的；而真实的「打开工程」是几十个文件一起到。这和
   [2026-08-12 渐入开头爆音](2026-08-12-audio-fade-in-pop.md) 是同一类盲区：测试场景全落在
   最省事的默认值上。
3. **可能死锁的自检必须带看门狗**，而且看门狗不能跑在会被饿死的那个线程池里。否则守卫
   不会变红，只会挂住。
4. 两个症状（缩略图、波形）同时出现时，先找它们**共用的东西**（这里是同一档 QoS 的
   线程），而不是分头修两处。
