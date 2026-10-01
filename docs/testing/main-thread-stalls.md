# 主线程卡顿日志：心跳看门狗

> 2026-10-01 起。用户在大工程（南极工程：42 段主轨、9 条音轨 64 段）里播放时按空格，播放 / 暂停图标
> 偶尔慢半拍。探针量到 `AVPlayer.pause()` / `play()` 本身 0 ms、rate 的 KVO 0–2 ms，所以慢的只能是
> 主线程当时在忙别的；真 App 播放 40 秒的采样里主线程平均只有 36–42% 忙 —— 「偶尔」说明是零星的长
> 卡顿，平均值看不见，只能逐次抓。进程外的 `sample` 挂不上这个 App（抓到的调用图是空的，同一会话里
> `sleep` 进程能抓；原因没追），所以 App 自己抓。

## 一、怎么工作

- `MainThreadWatchdog`（`Sources/SrtFlow/MainThreadWatchdog.swift`）：一条后台线程每 25 ms 往主队列投
  一个心跳；心跳超过阈值（默认 60 ms，24 fps 的一帧半）还没落地，就在那一刻从外面抓一份主线程的调用栈
  （`MainThreadStackCapture.swift`：挂起主线程、读寄存器、沿帧指针走、只在它自己的栈范围内读内存、
  几十微秒后恢复；符号化在恢复之后做）。心跳落地后记一次：卡了多久、当时在哪一栏 / 在不在播
  （`contextProvider`，在主线程上读）、栈。
- **默认开着，正式版也开**：开销是后台线程每 25 ms 醒一次、主线程每次只跑一个读标志的空块。
  `SRTFLOW_STALL_LOG=0` 关掉；`SRTFLOW_STALL_THRESHOLD_MS=100` 改阈值。
- 日志：`~/Library/Logs/SrtFlow/main-thread-stalls.log`，超过 1 MB 滚成 `.previous`。统一日志
  （Console.app）里 subsystem `com.srtflow.SrtFlow`、category `main-thread` 也有一行。
- 进程内冒烟（[GUI 冒烟流程](gui-smoke-testing.md)「四之六」）的结果 `<脚本>.out.json` 里多了
  `stalls`（每次卡顿的时刻、毫秒、context、前 12 层栈）；每个 `perf` 快照里多了 `stall:count` /
  `stall:maxMs`（自上次 `perfReset` 起）。
- **不进性能 ratchet 的账**：卡顿次数本来就不稳，`PerfCounters` 里没有它。

## 二、怎么读

```
2026-10-01 10:12:09.123  卡了 184 ms  section=videoEdit playing=true
    TrackMeterBars.draw(_:in:size:) + 120 (SrtFlow)
    closure #1 in TrackMeterBars.body.getter + 64 (SrtFlow)
    …
```

- 栈从最里层起。先找第一个带 `(SrtFlow)` 的帧 —— 那是我们自己的代码当时在做什么；上面全是系统帧时，
  看最外层那几个 `(SrtFlow)` 帧（谁叫进系统的）。
- 栈是**超过阈值那一刻**抓的一次快照。卡 500 ms 的一次只在第 60 ms 抓一次，后面 440 ms 在做什么不知道；
  想看后半段就把阈值调大（`SRTFLOW_STALL_THRESHOLD_MS=300`）再复现。
- 时刻是心跳发出的那一刻，卡顿真正开始不会比它晚超过 25 ms。

## 三、局限

- 只看主线程；别的线程卡住（解码、tap）它看不见，也不该看。
- 靠帧指针走栈：没有帧指针的帧（手写汇编、某些系统函数的叶子）会少一两层；只在 arm64 上抓栈，
  别的架构只记时长。
- 心跳落地才记：App 彻底死掉的那一次记不下来（那是崩溃报告的事）。

## 四、回归

`scripts/check-main-thread-watchdog.sh`（`scripts/check-all.sh` 第 3 组）：主循环空转半秒不许误报；
主线程忙等 250 ms 记一次，时长在 0.2–1 秒、context 是给的那句、栈里有 `stallTheMainThread`；
主线程睡 150 ms 也记；日志文件里有同样两条；`stop()` 之后再卡不记。

反向验证（2026-10-01）：把阈值临时改成 10 秒 → 红（忙等 250 ms 一次都没记到）；把 `capture()` 临时改成
返回空 → 红（栈里没有函数名、日志里没有栈）。恢复后转绿。
