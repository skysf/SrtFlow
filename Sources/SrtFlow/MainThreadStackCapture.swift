import Darwin
import Foundation

// MARK: - 从别的线程抓主线程的调用栈：主线程卡住的那一刻它在做什么
//
// 管什么：主线程启动时记下自己的 mach 端口和栈的范围；之后任何线程都能调 `capture()`：把主线程挂起、
// 读它的寄存器、沿帧指针（x29）把返回地址一层层走出来、再恢复主线程；`symbolicate` 把地址换成
// 「函数名 + 偏移 (映像)」。
// 不管什么：什么时候抓、抓到了记在哪 —— 那是 MainThreadWatchdog 的事。
//
// 为什么自己走栈：`Thread.callStackSymbols` 只能看自己这条线程；想知道主线程此刻卡在哪，只能从外面
// 挂起它看。进程外的 `sample` 挂不上这个 App（2026-10-01 实测，见 docs/testing/main-thread-stalls.md）。
// 只在 arm64 上做（App 只发 arm64）；别的架构 `capture()` 返回空，看门狗照常记时长。
//
// 安全边界（硬约束和由来见 docs/architecture/main-thread-stack-capture.md）：
// - 只在主线程自己的栈范围里读内存（`pthread_get_stackaddr_np` / `pthread_get_stacksize_np`）：帧指针
//   出了范围、没对齐、不往高处走就停 —— 坏指针不会让看门狗线程崩掉。
// - **挂起到恢复之间只做系统调用和裸内存读写**：不分配内存、不拿锁、不打日志、不碰要现场取类型元数据的
//   类型。主线程被挂起的那一刻可能正握着分配器的锁，挂起方再去要同一把锁就永远等下去，主线程也永远
//   不会被恢复：原来这里在挂起期间建 `[UInt]`、`append` 扩容，2026-10-06 南极工程导出两次卡死、只能强制
//   退出（docs/bugfixes/2026-10-06-watchdog-capture-deadlocks-main-thread.md）。所以要用的内存在挂起前
//   分配好，寄存器按 init 里算好的偏移裸读，地址在恢复之后才拷成数组；挂起和恢复只在 `walkWhileSuspended`。
// - 主线程只挂起走栈那几十微秒；符号化（dladdr、demangle）在恢复之后做。

struct MainThreadStackCapture: Sendable {
    private let thread: thread_act_t
    private let stackTop: UInt
    private let stackBottom: UInt
    /// 线程状态（`arm_thread_state64_t`）有多少字节、fp / lr / pc 在第几个字节。在 init 里（主线程上、什么都
    /// 没挂起时）算好：挂起期间只按偏移裸读，不碰这个导入的 C 类型 —— 没优化的构建里碰它可能要现场取元数据。
    private let stateByteCount: Int
    private let fpOffset: Int
    private let lrOffset: Int
    private let pcOffset: Int

    /// **必须在主线程上建**：记的是「当前线程」的端口和栈范围。
    init() {
        precondition(Thread.isMainThread, "MainThreadStackCapture 要在主线程上建")
        thread = mach_thread_self()
        let top = UInt(bitPattern: pthread_get_stackaddr_np(pthread_self()))
        stackTop = top
        stackBottom = top - UInt(pthread_get_stacksize_np(pthread_self()))
        #if arch(arm64)
        stateByteCount = MemoryLayout<arm_thread_state64_t>.size
        fpOffset = MemoryLayout<arm_thread_state64_t>.offset(of: \.__fp)!
        lrOffset = MemoryLayout<arm_thread_state64_t>.offset(of: \.__lr)!
        pcOffset = MemoryLayout<arm_thread_state64_t>.offset(of: \.__pc)!
        #else
        stateByteCount = 0
        fpOffset = 0
        lrOffset = 0
        pcOffset = 0
        #endif
    }

    /// 主线程此刻的返回地址，从最里层起。抓不到（别的架构、挂起失败）就是空。
    func capture(maxDepth: Int = 48) -> [UInt] {
        #if arch(arm64)
        let capacity = max(maxDepth, 2)
        // 挂起之前把要用的内存全部备好（文件头「安全边界」第二条）。
        let frames = UnsafeMutablePointer<UInt>.allocate(capacity: capacity)
        defer { frames.deallocate() }
        let state = UnsafeMutableRawPointer.allocate(byteCount: stateByteCount, alignment: 16)
        defer { state.deallocate() }
        let count = walkWhileSuspended(state: state, frames: frames, capacity: capacity)
        // 主线程已经恢复，到这里才许分配。
        return Array(UnsafeBufferPointer(start: frames, count: count))
        #else
        return []
        #endif
    }

    /// 挂起主线程 → 读寄存器 → 沿帧指针把返回地址写进 `frames` → 恢复；返回写了几个。
    ///
    /// **挂起到恢复之间只做系统调用和裸内存读写**：`state`、`frames` 由调用方在挂起前分配好，这里不分配、不拿锁、
    /// 不打日志，往这段里加任何一行之前先读 docs/architecture/main-thread-stack-capture.md。
    private func walkWhileSuspended(state: UnsafeMutableRawPointer, frames: UnsafeMutablePointer<UInt>, capacity: Int) -> Int {
        #if arch(arm64)
        let words = state.bindMemory(to: natural_t.self, capacity: stateByteCount / MemoryLayout<natural_t>.size)
        var wordCount = mach_msg_type_number_t(stateByteCount / MemoryLayout<natural_t>.size)
        guard capacity >= 2, thread_suspend(thread) == KERN_SUCCESS else { return 0 }
        defer { thread_resume(thread) }
        guard thread_get_state(thread, ARM_THREAD_STATE64, words, &wordCount) == KERN_SUCCESS else { return 0 }
        frames[0] = UInt(state.load(fromByteOffset: pcOffset, as: UInt64.self))
        frames[1] = UInt(state.load(fromByteOffset: lrOffset, as: UInt64.self))
        var count = 2
        var frame = UInt(state.load(fromByteOffset: fpOffset, as: UInt64.self))
        while count < capacity, isInsideStack(frame) {
            let next = UnsafeRawPointer(bitPattern: frame)!.load(as: UInt.self)
            let returnAddress = UnsafeRawPointer(bitPattern: frame + 8)!.load(as: UInt.self)
            guard returnAddress != 0 else { break }
            frames[count] = returnAddress
            count += 1
            guard next > frame else { break }  // 帧指针只许往高处走，不然是坏链
            frame = next
        }
        return count
        #else
        return 0
        #endif
    }

    private func isInsideStack(_ frame: UInt) -> Bool {
        frame >= stackBottom && frame + 16 <= stackTop && frame & 0xF == 0
    }

    // MARK: 符号化

    /// 地址 → 「函数 + 偏移 (映像)」。Swift 的名字经运行时的 `swift_demangle` 还原；找不到符号就写地址。
    static func symbolicate(_ addresses: [UInt]) -> [String] {
        addresses.map { raw in
            let address = raw & 0x0000_7FFF_FFFF_FFFF  // 去掉指针签名位（arm64e 会带），不然 dladdr 认不出
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0, let symbol = info.dli_sname else {
                return String(format: "0x%lx", address)
            }
            let image = info.dli_fname.map { URL(fileURLWithPath: String(cString: $0)).lastPathComponent } ?? "?"
            let offset = address - UInt(bitPattern: info.dli_saddr)
            return "\(demangled(symbol)) + \(offset) (\(image))"
        }
    }

    private typealias Demangle = @convention(c) (
        UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32
    ) -> UnsafeMutablePointer<CChar>?

    private static let demangle: Demangle? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "swift_demangle") else { return nil }
        return unsafeBitCast(symbol, to: Demangle.self)
    }()

    private static func demangled(_ symbol: UnsafePointer<CChar>) -> String {
        if let demangle, let name = demangle(symbol, strlen(symbol), nil, nil, 0) {
            defer { free(name) }
            return String(cString: name)
        }
        return String(cString: symbol)
    }
}
