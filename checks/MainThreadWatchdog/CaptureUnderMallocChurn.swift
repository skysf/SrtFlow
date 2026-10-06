import Darwin
import Foundation
import Synchronization

// 第 6 组：主线程一边不停分配 / 释放内存，另一条线程一边连续抓它的栈 —— 抓栈不许卡死。
//
// 由来（docs/bugfixes/2026-10-06-watchdog-capture-deadlocks-main-thread.md）：抓栈要先挂起主线程。挂起期间挂起方
// 只要分配一次内存，碰上主线程被挂起时正握着分配器的锁，挂起方就永远等那把锁，主线程也永远不会被恢复。
// 原来的写法在挂起期间建 `[UInt]`：南极工程导出两次卡死、只能强制退出；同样的压力下本机 6 轮都在 1 秒内卡死。
// 约束本身见 docs/architecture/main-thread-stack-capture.md。
//
// 为什么靠量、不做成每次必现：分配器的快路径不加锁。2026-10-06 探针：主线程用 zone 的 `force_lock` 或
// `_malloc_fork_prepare` 握住全部分配器的锁 300 ms，优化构建里别的线程照样分配得出来，挡不住。所以这里让主线程
// 分配各种大小（大块常走加锁的慢路径）外加 Swift 数组扩容，抓栈线程每秒挂起它成千上万次。
//
// 卡死时分配器的锁在被挂起的主线程手里：判卡死的线程只用原子量、write(2) 和 _exit，自己一次都不分配。

/// 抓栈线程、判卡死的线程和主线程之间的计数，全是原子量：读写都不分配。
final class CaptureChurnState: Sendable {
    let captures = Atomic<Int>(0)
    let deepest = Atomic<Int>(0)
    let stop = Atomic<Bool>(false)
    let capturerExited = Atomic<Bool>(false)
    let finished = Atomic<Bool>(false)
}

/// **在主线程上调**：`seconds` 秒里主线程不停分配 / 释放，同时另一条线程不停 `capture()`；卡死就当场报红退出。
func checkCaptureUnderMallocChurn(seconds: Double) {
    let capture = MainThreadStackCapture()
    let state = CaptureChurnState()
    startDeadlockMonitor(state, limit: 5)
    let capturer = Thread {
        while !state.stop.load(ordering: .acquiring) {
            let depth = capture.capture().count
            if depth > state.deepest.load(ordering: .relaxed) { state.deepest.store(depth, ordering: .relaxed) }
            _ = state.captures.wrappingAdd(1, ordering: .relaxed)
        }
        state.capturerExited.store(true, ordering: .releasing)
    }
    capturer.start()
    churnAllocations(for: seconds)
    state.stop.store(true, ordering: .releasing)
    while !state.capturerExited.load(ordering: .acquiring) { usleep(1_000) }
    state.finished.store(true, ordering: .releasing)

    let captures = state.captures.load(ordering: .relaxed)
    let deepest = state.deepest.load(ordering: .relaxed)
    print("  第 6 组：主线程不停分配内存的 \(seconds) 秒里抓栈 \(captures) 次，最深 \(deepest) 层，没有卡死")
    check(captures >= 1_000, "主线程狂分配内存的 \(seconds) 秒里该抓到上千次栈（不然这一组没压到）：\(captures) 次")
    check(deepest >= 3, "抓到的栈该有好几层：最深 \(deepest) 层")
}

private func uptime() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }

/// 判卡死：抓栈计数 `limit` 秒不涨就报红退出。**一次都不分配**：分配器的锁可能在被挂起的主线程手里。
private func startDeadlockMonitor(_ state: CaptureChurnState, limit: Double) {
    let monitor = Thread {
        var last = -1
        var lastChange = uptime()
        while !state.finished.load(ordering: .acquiring) {
            usleep(100_000)
            let count = state.captures.load(ordering: .relaxed)
            if count != last {
                last = count
                lastChange = uptime()
            } else if uptime() - lastChange > limit {
                let message: StaticString = "✗ main-thread-watchdog：挂起主线程抓栈卡死了 —— 挂起期间分配了内存或拿了锁？见 docs/architecture/main-thread-stack-capture.md\n"
                _ = write(2, message.utf8Start, message.utf8CodeUnitCount)
                _exit(1)
            }
        }
    }
    monitor.start()
}

/// 主线程在这里不停分配 / 释放：十几字节到一兆多（大块常走分配器加锁的慢路径），外加 Swift 数组扩容。
@inline(never)
private func churnAllocations(for seconds: Double) {
    let sizes = [16, 48, 112, 400, 1_500, 6_000, 24_000, 100_000, 400_000, 1_200_000]
    var pool = [UnsafeMutableRawPointer?](repeating: nil, count: 48)
    var x: UInt64 = 0x9E37_79B9_7F4A_7C15
    var sink = 0
    let start = uptime()
    while uptime() - start < seconds {
        x ^= x << 13
        x ^= x >> 7
        x ^= x << 17
        let slot = Int(x % UInt64(pool.count))
        let size = sizes[Int((x >> 8) % UInt64(sizes.count))]
        free(pool[slot])
        let block = malloc(size)!
        memset(block, 1, min(size, 8_192))
        pool[slot] = block
        var array = [Int]()
        array.reserveCapacity(Int((x >> 20) % 200))
        sink &+= array.capacity
    }
    pool.forEach { free($0) }
    if sink < 0 { print(sink) }
}
