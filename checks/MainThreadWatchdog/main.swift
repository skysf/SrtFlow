import Foundation

// 主线程心跳看门狗的自检。编译方式见 scripts/check-main-thread-watchdog.sh。
//
// 合同（docs/testing/main-thread-stalls.md）：主线程没卡不许误报；卡过阈值记一次，时长对、
// context 对、栈里有卡住的那个函数；日志文件里有同样的内容；stop 之后不再记；挂起主线程期间抓栈线程
// 不许分配 / 释放内存（第 6 组）、主线程不停分配内存时连续抓栈不许卡死（第 7 组）—— 约束见
// docs/architecture/main-thread-stack-capture.md。

// 逐行刷新：第 7 组卡死时判卡死的线程用 _exit 退出，不刷缓冲区，前面几组的输出不能丢在里面。
setvbuf(stdout, nil, _IOLBF, 0)

var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL [line \(line)] \(message)")
    }
}

/// 让主线程的运行循环转一会儿（心跳块是投到主队列上的，主循环不转它落不了地）。
func pump(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

/// 主线程忙等这么久。`@inline(never)` + public：它要作为一个有名字的帧留在栈里，看门狗抓到的栈里得找得到它。
@inline(never)
public func stallTheMainThread(milliseconds: Double) {
    let start = ProcessInfo.processInfo.systemUptime
    var sink = 0.0
    while ProcessInfo.processInfo.systemUptime - start < milliseconds / 1000 {
        sink += (sink + 1).squareRoot()
    }
    if sink < 0 { print(sink) }
}

let logDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("watchdog-check-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
defer { try? FileManager.default.removeItem(at: logDirectory) }

// 阈值给 150 ms、卡给 400 / 300 ms：CI 的虚拟机上线程醒来能晚几十毫秒（#117 首跑：250 ms 的忙等量成 199 ms），
// 阈值和卡的长度都要留出这个余量；App 里的阈值仍是 60 ms。
let watchdog = MainThreadWatchdog(interval: 0.01, threshold: 0.15, logDirectory: logDirectory)
watchdog.contextProvider = { "ctx=check" }
let reported = OSAllocatedUnfairLockCounter()
watchdog.onStall = { _ in reported.increment() }
watchdog.start()

// 1. 没卡的时候不许误报（主循环空转半秒，心跳每 10 ms 一拍）。
pump(0.5)
check(watchdog.recentStalls.isEmpty, "主线程没卡时不许误报：记了 \(watchdog.recentStalls.count) 次")

// 2. 忙等 400 ms：记一次，时长、context、栈都要对。
stallTheMainThread(milliseconds: 400)
pump(0.3)
let busy = watchdog.recentStalls
check(busy.count == 1, "忙等 400 ms 该记一次，记了 \(busy.count) 次")
if let stall = busy.first {
    check(stall.duration >= 0.2 && stall.duration < 1.5, "时长该在 0.2–1.5 秒之间（心跳可能晚发几十毫秒）：\(stall.duration)")
    check(stall.context == "ctx=check", "context 该是 contextProvider 给的：\(stall.context)")
    check(stall.stack.contains { $0.contains("stallTheMainThread") },
          "栈里要有卡住的那个函数（从最里层起前 8 层）：\(stall.stack.prefix(8))")
    check(abs(stall.startedAt.timeIntervalSinceNow) < 2, "startedAt 该是刚才：\(stall.startedAt)")
}
check(reported.value == busy.count, "onStall 每次卡顿调一次：\(reported.value) vs \(busy.count)")

// 3. 睡 300 ms（不是忙等）也算卡：主线程不响应就是不响应。
Thread.sleep(forTimeInterval: 0.3)
pump(0.3)
check(watchdog.recentStalls.count == 2, "睡 300 ms 也该记一次：共 \(watchdog.recentStalls.count) 次")

// 4. 日志文件：同样的内容在文件里。
let logFile = logDirectory.appendingPathComponent(MainThreadWatchdog.logFileName)
let log = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
check(!log.isEmpty, "日志文件该写出来了：\(logFile.path)")
check(log.contains("stallTheMainThread"), "日志里要有栈")
check(log.contains("ctx=check"), "日志里要有 context")
check(log.components(separatedBy: "卡了 ").count - 1 == 2, "日志里该有两条记录")

// 4b. 旁注：不是卡顿的事也记进同一份日志（一行、带时刻、「注：」开头），不算卡顿。
watchdog.note("note=check 播放中 seek → 12.345 s")
let withNote = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
check(withNote.contains("  注：note=check 播放中 seek → 12.345 s"), "旁注该原样写进日志、带「注：」前缀")
check(withNote.components(separatedBy: "卡了 ").count - 1 == 2, "旁注不算卡顿：仍是两条卡顿记录")
check(watchdog.recentStalls.count == 2, "旁注不进 recentStalls")

// 5. stop 之后不再记。
watchdog.stop()
pump(0.1)
stallTheMainThread(milliseconds: 300)
pump(0.2)
check(watchdog.recentStalls.count == 2, "stop 之后不该再记：共 \(watchdog.recentStalls.count) 次")

// 6. 挂起主线程抓栈的那几十微秒里，抓栈线程一次都不许分配 / 释放内存（确定性：malloc_logger 钩子逐次数，
//    NoAllocationWhileSuspended.swift；约束见 docs/architecture/main-thread-stack-capture.md）。
checkNoAllocationWhileSuspended(captures: 300)

// 7. 端到端：主线程不停分配内存的同时连续抓栈，不许卡死（CaptureUnderMallocChurn.swift）。
checkCaptureUnderMallocChurn(seconds: 2)

print(failures == 0 ? "✓ main-thread-watchdog：\(checks) 项全部通过" : "✗ main-thread-watchdog：\(failures)/\(checks) 项失败")
exit(failures == 0 ? 0 : 1)

/// 看门狗线程上数次数，主线程上读。
final class OSAllocatedUnfairLockCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
