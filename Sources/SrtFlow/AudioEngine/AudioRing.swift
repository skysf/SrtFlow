import Foundation
import Synchronization

// MARK: - 一段声音的环：喂样线程写、渲染块读，中间不加锁
//
// 管什么：两声道 float 的环形缓冲，按**时间线的帧**定位 —— 环里的每一帧都知道自己是时间线的第几帧，渲染块按
// 位置来取，不是「下一帧」。单写者（AudioTrackFeeder 的线程）单读者（渲染块）。
// 不管什么：读文件、增益（读者自己乘）。
//
// seek 的做法：写者不碰读者的下标（那是读者的），只是记一个「从这儿起是新一轮」的标记（`epoch` + 新一轮从环的
// 哪个下标、时间线的哪一帧开始），然后接着往后写；读者下一拍看到 epoch 变了，自己把读下标跳到标记处。
// 写者在读者跳过去之前写不进多少（空间按旧下标算），最多等一拍。两个下标、标记都是原子的，渲染块里不分配、不加锁。

final class AudioRing: @unchecked Sendable {
    let capacity: Int
    let left: UnsafeMutablePointer<Float>
    let right: UnsafeMutablePointer<Float>
    /// 写到第几帧（累计，不取模）。
    private let head = Atomic<Int>(0)
    /// 读到第几帧（累计）。只有读者写它。
    private let tail = Atomic<Int>(0)
    /// 新一轮的编号；写者每 seek 一次 +1。
    private let epoch = Atomic<Int>(0)
    /// 新一轮从累计下标的哪儿开始、对应时间线的哪一帧。写者先写这两个再 +epoch（release），读者读到新 epoch 后再读它们（acquire）。
    private let epochIndex = Atomic<Int>(0)
    private let epochPosition = Atomic<Int64>(0)
    /// 读者记住的那一轮。
    private var readerEpoch = 0
    /// 读者此刻读下标对应的时间线帧。
    private var readerPosition: Int64 = 0

    init(capacity: Int) {
        self.capacity = capacity
        left = .allocate(capacity: capacity)
        right = .allocate(capacity: capacity)
        left.initialize(repeating: 0, count: capacity)
        right.initialize(repeating: 0, count: capacity)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    // MARK: 写者

    /// 还能写多少帧（按读者此刻的下标算）。
    var space: Int { capacity - (head.load(ordering: .acquiring) - tail.load(ordering: .acquiring)) }

    /// 开新一轮：接下来写的第一帧是时间线的 `position` 帧。
    func beginEpoch(position: Int64) {
        epochIndex.store(head.load(ordering: .relaxed), ordering: .relaxed)
        epochPosition.store(position, ordering: .relaxed)
        epoch.wrappingAdd(1, ordering: .releasing)
    }

    /// 写 `frames` 帧：`body` 收到的是（左、右、这一截的帧数、这一截在环里的偏移是否接着上一截）—— 环绕时分两截调。
    /// 调用方保证 `frames ≤ space`。
    func write(frames: Int, _ body: (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>, Int) -> Void) {
        var written = 0
        var index = head.load(ordering: .relaxed)
        while written < frames {
            let slot = index % capacity
            let count = min(frames - written, capacity - slot)
            body(left + slot, right + slot, count)
            written += count
            index += count
        }
        head.store(index, ordering: .releasing)
    }

    // MARK: 读者（渲染块）

    /// 读者此刻在时间线的第几帧（读下标对应的位置）。先处理新一轮的标记。
    func readerPositionNow() -> Int64 {
        syncEpoch()
        return readerPosition
    }

    private func syncEpoch() {
        let current = epoch.load(ordering: .acquiring)
        guard current != readerEpoch else { return }
        readerEpoch = current
        tail.store(epochIndex.load(ordering: .relaxed), ordering: .releasing)
        readerPosition = epochPosition.load(ordering: .relaxed)
    }

    /// 把时间线 `[position, position + frames)` 这一段读进 `outLeft` / `outRight`（**累加**，不清零）。
    /// 环里领先于 `position` 的先丢掉；环里还没有的（落后 / 欠载）当静音。返回真读到的帧数。
    @discardableResult
    func accumulate(position: Int64, frames: Int, into outLeft: UnsafeMutablePointer<Float>,
                    _ outRight: UnsafeMutablePointer<Float>) -> Int {
        syncEpoch()
        var available = head.load(ordering: .acquiring) - tail.load(ordering: .relaxed)
        var index = tail.load(ordering: .relaxed)
        // 环里的头比要的位置早：丢掉中间那一截。
        if readerPosition < position {
            let skip = Int(min(Int64(available), position - readerPosition))
            index += skip
            available -= skip
            readerPosition += Int64(skip)
        }
        // 环里的头比要的位置晚：前面那一截没有数据，留着静音。
        let lead = Int(min(Int64(frames), max(0, readerPosition - position)))
        var out = lead
        var got = 0
        while out < frames, available > 0 {
            let slot = index % capacity
            let count = min(frames - out, min(available, capacity - slot))
            for i in 0..<count {
                outLeft[out + i] += left[slot + i]
                outRight[out + i] += right[slot + i]
            }
            out += count
            index += count
            available -= count
            got += count
        }
        readerPosition += Int64(got)
        tail.store(index, ordering: .releasing)
        return got
    }
}
