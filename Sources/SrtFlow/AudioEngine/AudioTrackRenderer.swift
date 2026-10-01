import Foundation
import Synchronization

// MARK: - 一条轨的渲染块：从各条流的环里取这一拍、乘增益、相加
//
// 管什么：实时线程上的那一小段活 —— 此刻活着的每条流，把 `[position, position + frames)` 这一截从环里取出来，
// 乘上段自己的增益（音量 × 渐变 × 曲线，`GainTable.Sampler`）和轨道推子，累加进输出。
// 不管什么：读文件、开关流（AudioTrackFeeder）；总推子（mainMixer）。
//
// **实时安全**：不分配、不加锁、不碰 Swift 的 Dictionary / String。草稿缓冲预分配；流的列表经 AudioPublished
// 无锁地取；增益按 64 帧一块在两端取值、块内线性插值（线性斜坡上和逐采样一样准）。

final class AudioTrackRenderer: @unchecked Sendable {
    static let maxFrames = 8192
    private static let gainBlock = 64

    private let published: AudioPublished<StreamSet>
    /// 轨道推子（线性）。主线程改，渲染块每拍读。
    let fader: Atomic<Float>
    private let scratchLeft: UnsafeMutablePointer<Float>
    private let scratchRight: UnsafeMutablePointer<Float>

    init(feeder: AudioTrackFeeder, fader: Float) {
        published = feeder.published
        self.fader = Atomic(fader)
        scratchLeft = .allocate(capacity: Self.maxFrames)
        scratchRight = .allocate(capacity: Self.maxFrames)
    }

    deinit {
        scratchLeft.deallocate()
        scratchRight.deallocate()
    }

    /// 把这一拍混进 `outLeft` / `outRight`（调用方已清零）。返回环里没有、只能当静音的帧数（欠载）。
    func render(position: Int64, frames: Int, into outLeft: UnsafeMutablePointer<Float>,
                _ outRight: UnsafeMutablePointer<Float>) -> Int {
        guard frames <= Self.maxFrames, let set = published.load() else { return 0 }
        let fader = fader.load(ordering: .relaxed)
        var missing = 0
        for stream in set.streams {
            let from = max(position, stream.startFrame)
            let to = min(position + Int64(frames), stream.endFrame)
            guard to > from else { continue }
            let count = Int(to - from)
            let offset = Int(from - position)
            scratchLeft.update(repeating: 0, count: count)
            scratchRight.update(repeating: 0, count: count)
            let got = stream.ring.accumulate(position: from, frames: count, into: scratchLeft, scratchRight)
            missing += count - got
            let gain = stream.gain.load()?.sampler ?? stream.segment.gain
            mix(gain, fader: fader, from: from, count: count, into: outLeft + offset, outRight + offset)
        }
        return missing
    }

    private func mix(_ gain: GainTable.Sampler, fader: Float, from: Int64, count: Int,
                     into outLeft: UnsafeMutablePointer<Float>, _ outRight: UnsafeMutablePointer<Float>) {
        let rate = AudioSegmentReader.engineRate
        let t0 = Double(from) / rate
        var index = 0
        var gainA = gain.gain(at: t0) * fader
        while index < count {
            let block = min(Self.gainBlock, count - index)
            let gainB = gain.gain(at: t0 + Double(index + block) / rate) * fader
            let step = (gainB - gainA) / Float(block)
            var g = gainA
            for k in 0..<block {
                outLeft[index + k] += scratchLeft[index + k] * g
                outRight[index + k] += scratchRight[index + k] * g
                g += step
            }
            gainA = gainB
            index += block
        }
    }
}
