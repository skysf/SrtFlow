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
// 安全边界：
// - 只在主线程自己的栈范围里读内存（`pthread_get_stackaddr_np` / `pthread_get_stacksize_np`）：帧指针
//   出了范围、没对齐、不往高处走就停 —— 坏指针不会让看门狗线程崩掉。
// - 主线程只挂起走栈那几十微秒；符号化（dladdr、demangle）在恢复之后做。
// - 走栈不调任何可能拿锁的东西（只读内存、thread_get_state），主线程正握着什么锁都无所谓。

struct MainThreadStackCapture: Sendable {
    private let thread: thread_act_t
    private let stackTop: UInt
    private let stackBottom: UInt

    /// **必须在主线程上建**：记的是「当前线程」的端口和栈范围。
    init() {
        precondition(Thread.isMainThread, "MainThreadStackCapture 要在主线程上建")
        thread = mach_thread_self()
        let top = UInt(bitPattern: pthread_get_stackaddr_np(pthread_self()))
        stackTop = top
        stackBottom = top - UInt(pthread_get_stacksize_np(pthread_self()))
    }

    /// 主线程此刻的返回地址，从最里层起。抓不到（别的架构、挂起失败）就是空。
    func capture(maxDepth: Int = 48) -> [UInt] {
        #if arch(arm64)
        guard thread_suspend(thread) == KERN_SUCCESS else { return [] }
        defer { thread_resume(thread) }
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(thread, ARM_THREAD_STATE64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return [] }
        var addresses = [UInt(state.__pc), UInt(state.__lr)]
        var frame = UInt(state.__fp)
        while addresses.count < maxDepth, isInsideStack(frame) {
            let next = UnsafePointer<UInt>(bitPattern: frame)!.pointee
            let returnAddress = UnsafePointer<UInt>(bitPattern: frame + 8)!.pointee
            guard returnAddress != 0 else { break }
            addresses.append(returnAddress)
            guard next > frame else { break }  // 帧指针只许往高处走，不然是坏链
            frame = next
        }
        return addresses
        #else
        return []
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
