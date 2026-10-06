import Darwin
import Foundation

// 第 6 组：挂起主线程期间，抓栈的那条线程一次都不许分配或释放内存（确定性的守卫）。
//
// 由来（docs/bugfixes/2026-10-06-watchdog-capture-deadlocks-main-thread.md）：主线程被挂起的那一刻可能正握着分配器
// 的锁，挂起方这时再分配，就永远等那把锁、主线程永远不会被恢复。原来的写法在挂起期间建 `[UInt]`、`append`
// 扩容，南极工程导出两次卡死。约束本身见 docs/architecture/main-thread-stack-capture.md。
//
// 做法：把 libmalloc 的 `malloc_logger` 钩子（MallocStackLogging / Instruments 记分配用的那个全局函数指针）临时指向
// 这里的回调。抓栈线程每分配 / 释放一次，回调就问内核主线程此刻的挂起计数：挂起着还分配 = 违规。跟分配器的锁、
// 两条线程落在哪组核上都无关，每一次抓栈都查得到（只靠压力去撞，同样的原写法 10 轮里只撞上 5 轮，见第 7 组）。
//
// 回调自己也要守同样的规矩：不分配，也不碰导入的 C 结构类型 —— 没优化的构建里第一次碰它要现场取类型元数据，
// 会分配、会加锁（2026-10-06 探针：回调里用 `thread_basic_info` 类型 → 分配又进回调 → 递归加锁崩掉）。
// 所以缓冲区、偏移、线程号都在装钩子之前备好，回调里只做裸读写。

/// 钩子回调读写的全部状态。装钩子之前在主线程上写好（顺带把这些全局变量的懒初始化做掉），回调里只做裸读写。
enum SuspendedAllocationProbe {
    nonisolated(unsafe) static var watchedThread: UInt = 0
    nonisolated(unsafe) static var mainThread: thread_act_t = 0
    nonisolated(unsafe) static var info: UnsafeMutablePointer<integer_t>?
    nonisolated(unsafe) static var infoWordCount: mach_msg_type_number_t = 0
    nonisolated(unsafe) static var suspendCountOffset = 0
    nonisolated(unsafe) static var seen = 0
    nonisolated(unsafe) static var whileSuspended = 0

    typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    /// libmalloc 的 `malloc_logger`（`RTLD_DEFAULT` 里找）。找不到 = 这一组查不了，调用方必须报红，不许当通过。
    static func loggerSlot() -> UnsafeMutablePointer<Logger?>? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger")?.assumingMemoryBound(to: Logger?.self)
    }

    /// 每次分配 / 释放都会调到这里（所有线程）。只数被盯着的那条线程；**这里不许分配、不许碰导入的 C 结构类型**。
    static let logger: Logger = { type, _, _, _, _, _ in
        // MALLOC_LOG_TYPE_ALLOCATE = 2、MALLOC_LOG_TYPE_DEALLOCATE = 4：释放也要拿分配器的锁，一样算。
        guard type & 6 != 0, UInt(bitPattern: pthread_self()) == SuspendedAllocationProbe.watchedThread,
              let info = SuspendedAllocationProbe.info else { return }
        SuspendedAllocationProbe.seen += 1
        var words = SuspendedAllocationProbe.infoWordCount
        guard thread_info(SuspendedAllocationProbe.mainThread, thread_flavor_t(THREAD_BASIC_INFO), info, &words) == KERN_SUCCESS
        else { return }
        let suspendCount = UnsafeRawPointer(info).load(fromByteOffset: SuspendedAllocationProbe.suspendCountOffset, as: integer_t.self)
        if suspendCount > 0 { SuspendedAllocationProbe.whileSuspended += 1 }
    }
}

/// **在主线程上调**：另一条线程连抓 `captures` 次主线程的栈，钩子数它在主线程被挂起期间分配 / 释放了几次 —— 必须是 0。
func checkNoAllocationWhileSuspended(captures: Int) {
    guard let slot = SuspendedAllocationProbe.loggerSlot() else {
        check(false, "找不到 libmalloc 的 malloc_logger 钩子：第 6 组查不了，不许当通过 —— 换个办法数挂起期间的分配")
        return
    }
    let capture = MainThreadStackCapture()
    let wordCount = MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size
    let info = UnsafeMutablePointer<integer_t>.allocate(capacity: wordCount)
    defer { info.deallocate() }
    SuspendedAllocationProbe.mainThread = mach_thread_self()
    SuspendedAllocationProbe.info = info
    SuspendedAllocationProbe.infoWordCount = mach_msg_type_number_t(wordCount)
    SuspendedAllocationProbe.suspendCountOffset = MemoryLayout<thread_basic_info>.offset(of: \.suspend_count)!
    SuspendedAllocationProbe.seen = 0
    SuspendedAllocationProbe.whileSuspended = 0

    let ready = DispatchSemaphore(value: 0)
    let go = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    let capturer = Thread {
        SuspendedAllocationProbe.watchedThread = UInt(bitPattern: pthread_self())
        ready.signal()
        go.wait()
        for _ in 0..<captures { _ = capture.capture() }
        done.signal()
    }
    capturer.start()
    ready.wait()
    let previous = slot.pointee
    slot.pointee = SuspendedAllocationProbe.logger
    go.signal()
    done.wait()
    slot.pointee = previous
    SuspendedAllocationProbe.watchedThread = 0

    let seen = SuspendedAllocationProbe.seen
    let whileSuspended = SuspendedAllocationProbe.whileSuspended
    print("  第 6 组：\(captures) 次抓栈，抓栈线程分配 / 释放 \(seen) 次，其中主线程被挂起期间 \(whileSuspended) 次")
    check(seen > 0, "钩子该看到抓栈线程在挂起之外的分配（不然钩子没生效，这一组是空跑）：\(seen) 次")
    check(whileSuspended == 0,
          "主线程被挂起期间，抓栈线程分配 / 释放了 \(whileSuspended) 次内存：碰上主线程握着分配器的锁就永远卡死（docs/architecture/main-thread-stack-capture.md）")
}
