import Foundation

// MARK: - 电平表按位置累加的环形缓冲
//
// 管什么：一条电平表的采样环 —— 各条合成音轨「听到的」采样按**绝对位置**加进来，界面在播放头处取峰值。
// 不管什么：采样从哪来、乘什么增益（`AudioMeterEngine` / `TapContext`，VideoEditAudioMeter.swift）。
// 2026-09-26 从 VideoEditAudioMeter.swift 拆出来：纯值、不依赖 AVFoundation，自检能单独编它。

/// 一条电平表的采样环：各条合成轨的「听到的」采样按**绝对位置**加进来（主轨的 A/B
/// 两条合成轨、总表的所有轨）。每 256 帧一块，块上记着「这块现在装的是哪个位置、
/// 什么时候写的」—— 位置对不上或者写得太久之前（上一遍播放留下的）就先清零再加。
final class SampleRing {
    static let rate = 48_000.0
    static let blockFrames = 256

    let capacity: Int
    private var left: [Float]
    private var right: [Float]
    private var blockIndex: [Int64]
    private var blockStamp: [UInt64]

    init(capacity: Int = 1 << 16) {
        self.capacity = capacity
        left = Array(repeating: 0, count: capacity)
        right = Array(repeating: 0, count: capacity)
        let blocks = capacity / Self.blockFrames
        blockIndex = Array(repeating: -1, count: blocks)
        blockStamp = Array(repeating: 0, count: blocks)
    }

    /// 同一块被同一遍播放的各条轨写，前后相差十来毫秒；隔得比这个久就是上一遍留下的。
    private static let staleNanos: UInt64 = 100_000_000

    /// 把一个采样加到位置 `position` 上（`now` 是写入时刻，纳秒）。
    ///
    /// **0 之前的位置直接丢掉**：tap 的时间可以比 0 早一点（播放中精确跳回 0 —— Return / Home ——
    /// 之后，头一拍的时间是负的），而负数取余还是负数，拿它当下标当场越界崩溃（2026-09-26 案例
    /// docs/bugfixes/2026-09-26-meter-crash-on-go-to-start.md）。0 之前没有时间线，界面也从来不读那里。
    func add(position: Int64, left l: Float, right r: Float, now: UInt64) {
        guard position >= 0 else { return }
        let block = position / Int64(Self.blockFrames)
        let slot = Int(block % Int64(blockIndex.count))
        if blockIndex[slot] != block || now &- blockStamp[slot] > Self.staleNanos {
            let base = slot * Self.blockFrames
            for index in base..<(base + Self.blockFrames) {
                left[index] = 0
                right[index] = 0
            }
            blockIndex[slot] = block
        }
        blockStamp[slot] = now
        let index = Int(position % Int64(capacity))
        left[index] += l
        right[index] += r
    }

    /// `[from, to)` 这些位置上的峰值（两个声道）。没写过的块算 0。
    func peak(from: Int64, to: Int64) -> (left: Float, right: Float) {
        var l: Float = 0
        var r: Float = 0
        var position = max(0, from)
        while position < to {
            let block = position / Int64(Self.blockFrames)
            let slot = Int(block % Int64(blockIndex.count))
            let blockEnd = min(to, (block + 1) * Int64(Self.blockFrames))
            if blockIndex[slot] == block {
                for p in position..<blockEnd {
                    let index = Int(p % Int64(capacity))
                    l = max(l, abs(left[index]))
                    r = max(r, abs(right[index]))
                }
            }
            position = blockEnd
        }
        return (l, r)
    }
}
