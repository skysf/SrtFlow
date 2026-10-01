import Foundation
import os

// MARK: - 主线程心跳看门狗：主线程卡了多久、卡在哪，记成日志
//
// 管什么：一条后台线程每隔 `interval` 往主队列投一个心跳；心跳超过 `threshold` 还没落地，就在那一刻抓一份
// 主线程的调用栈（MainThreadStackCapture）；心跳落地后把「卡了多久、当时在做什么（`contextProvider`）、
// 卡在哪（栈）」记进 `recentStalls`、写进日志文件、发给 `onStall`。
// 不管什么：怎么修；界面；别的线程（只看主线程）；性能计数（那是 PerfCounters，而且卡顿次数不稳，
// 不能进 ratchet 的账）。
//
// 为什么要有它（2026-10-01）：用户在大工程里播放时按空格，播放 / 暂停图标偶尔慢半拍。探针量到
// AVPlayer 的 pause() / play() 本身 0 ms、rate 的 KVO 0–2 ms，所以慢的只能是主线程当时在忙别的；
// 主线程播放中平均只有 36–42% 忙，「偶尔」说明是零星的长卡顿 —— 平均值看不见，只能逐次抓。
// 合同和怎么读日志：docs/testing/main-thread-stalls.md。
//
// 开销：后台线程每 25 ms 醒一次；主线程每次只跑一个空块（读一个标志）。默认开着（正式版也开），
// `SRTFLOW_STALL_LOG=0` 关掉；阈值 `SRTFLOW_STALL_THRESHOLD_MS` 可改，默认 60 ms（24 fps 的一帧半）。

final class MainThreadWatchdog: @unchecked Sendable {
    /// 一次卡顿。
    struct Stall: Sendable {
        /// 心跳发出的那一刻（墙钟）：卡顿开始不会比它晚超过一个 `interval`。
        let startedAt: Date
        /// 心跳等了多久（秒）。
        let duration: TimeInterval
        /// 卡住那一拍主线程在做什么（`contextProvider`，心跳落地时在主线程上读）。
        let context: String
        /// 卡住时主线程的调用栈，从最里层起（抓不到就是空）。
        let stack: [String]

        var milliseconds: Int { Int((duration * 1000).rounded()) }
    }

    static let disableKey = "SRTFLOW_STALL_LOG"
    static let thresholdKey = "SRTFLOW_STALL_THRESHOLD_MS"
    static let logFileName = "main-thread-stalls.log"
    /// 日志放哪：`~/Library/Logs/SrtFlow/main-thread-stalls.log`。
    static var defaultLogDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/SrtFlow", isDirectory: true)
    }
    private static let logRotateBytes = 1 << 20
    private static let keepRecent = 200

    /// App 用的那一个：阈值可用环境变量改。
    static let shared: MainThreadWatchdog = {
        let env = ProcessInfo.processInfo.environment
        let threshold = env[thresholdKey].flatMap(Double.init).map { $0 / 1000 } ?? 0.06
        return MainThreadWatchdog(threshold: threshold)
    }()
    /// `SRTFLOW_STALL_LOG=0` 就不开。
    static var isDisabledByEnvironment: Bool { ProcessInfo.processInfo.environment[disableKey] == "0" }

    let interval: TimeInterval
    let threshold: TimeInterval
    /// nil = 不写文件（自检要写到临时目录，App 写到 `defaultLogDirectory`）。
    let logDirectory: URL?

    /// 卡住那一拍主线程在做什么（在哪一栏、在不在播）。**在主线程上调**，只有心跳超过阈值那一拍才调。
    var contextProvider: @Sendable () -> String {
        get { lock.withLock { $0.contextProvider } }
        set { lock.withLock { $0.contextProvider = newValue } }
    }
    /// 每记一次卡顿调一次（看门狗线程上）。
    var onStall: (@Sendable (Stall) -> Void)? {
        get { lock.withLock { $0.onStall } }
        set { lock.withLock { $0.onStall = newValue } }
    }
    /// 到此刻为止记下的卡顿（最多留最近 200 次）。
    var recentStalls: [Stall] { lock.withLock { $0.recent } }

    private struct State {
        var running = false
        /// 这一拍心跳已经超过阈值：主线程落地时据此才去读 context（平时的心跳只读这一个标志）。
        var flagged = false
        var landedContext = ""
        var recent: [Stall] = []
        var contextProvider: @Sendable () -> String = { "" }
        var onStall: (@Sendable (Stall) -> Void)?
    }
    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let logger = Logger(subsystem: "com.srtflow.SrtFlow", category: "main-thread")

    init(interval: TimeInterval = 0.025, threshold: TimeInterval = 0.06,
         logDirectory: URL? = MainThreadWatchdog.defaultLogDirectory) {
        self.interval = interval
        self.threshold = threshold
        self.logDirectory = logDirectory
    }

    /// **在主线程上调**（要记主线程的端口和栈范围）。已经在跑就什么都不做。
    func start() {
        let capture = MainThreadStackCapture()
        let shouldStart = lock.withLock { state -> Bool in
            if state.running { return false }
            state.running = true
            return true
        }
        guard shouldStart else { return }
        let thread = Thread { [self] in run(capture: capture) }
        thread.name = "MainThreadWatchdog"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// 当前这一拍心跳落地之后退出，之后不再记。
    func stop() { lock.withLock { $0.running = false } }

    private var isRunning: Bool { lock.withLock { $0.running } }

    // MARK: 看门狗线程

    private func run(capture: MainThreadStackCapture) {
        let landed = DispatchSemaphore(value: 0)
        while isRunning {
            let sentAt = ProcessInfo.processInfo.systemUptime
            lock.withLock { $0.flagged = false; $0.landedContext = "" }
            DispatchQueue.main.async { [self] in
                let flagged = lock.withLock { $0.flagged }
                let context = flagged ? contextProvider() : ""
                lock.withLock { $0.landedContext = context }
                landed.signal()
            }
            var addresses: [UInt] = []
            if landed.wait(timeout: .now() + threshold) == .timedOut {
                lock.withLock { $0.flagged = true }
                addresses = capture.capture()
                landed.wait()  // 等它真的落地，不管卡多久：每一拍心跳只等一次信号
            }
            let duration = ProcessInfo.processInfo.systemUptime - sentAt
            if duration > threshold {
                record(Stall(
                    startedAt: Date(timeIntervalSinceNow: -duration), duration: duration,
                    context: lock.withLock { $0.landedContext },
                    stack: MainThreadStackCapture.symbolicate(addresses)
                ))
            }
            Thread.sleep(forTimeInterval: interval)
        }
    }

    private func record(_ stall: Stall) {
        let callback = lock.withLock { state -> (@Sendable (Stall) -> Void)? in
            state.recent.append(stall)
            if state.recent.count > Self.keepRecent { state.recent.removeFirst(state.recent.count - Self.keepRecent) }
            return state.onStall
        }
        logger.notice("主线程卡了 \(stall.milliseconds) ms \(stall.context, privacy: .public)：\(stall.stack.first ?? "", privacy: .public)")
        appendToLog(stall)
        callback?(stall)
    }

    // MARK: 日志文件

    private func appendToLog(_ stall: Stall) {
        guard let logDirectory else { return }
        let file = logDirectory.appendingPathComponent(Self.logFileName)
        let manager = FileManager.default
        try? manager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        if let size = (try? manager.attributesOfItem(atPath: file.path))?[.size] as? Int, size > Self.logRotateBytes {
            let previous = logDirectory.appendingPathComponent(Self.logFileName + ".previous")
            try? manager.removeItem(at: previous)
            try? manager.moveItem(at: file, to: previous)
        }
        var text = "\(Self.timestamp.string(from: stall.startedAt))  卡了 \(stall.milliseconds) ms  \(stall.context)\n"
        for frame in stall.stack { text += "    \(frame)\n" }
        if !manager.fileExists(atPath: file.path) { manager.createFile(atPath: file.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
    }

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
}
