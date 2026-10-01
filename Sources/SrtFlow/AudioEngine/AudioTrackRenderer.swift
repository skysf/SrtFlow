import Foundation
import Synchronization

// MARK: - 一条轨的渲染块：从各条流的环里取这一拍、乘增益、过场景、相加
//
// 管什么：实时线程上的那一小段活 —— 此刻活着的每条流，把 `[position, position + frames)` 这一截从环里取出来，
// 乘上段自己的增益（音量 × 渐变 × 曲线，`GainTable.Sampler`），挂了声音场景的再过效果链（段尾之后继续喂零、
// 余音散完；位置跳了就复位链），乘轨道推子，累加进输出。顺序和 tap 那条路一样：段增益 → 效果 → 推子
// （docs/architecture/sound-scenes.md）。
// 不管什么：读文件、开关流、建效果链（AudioTrackFeeder）；总推子（mainMixer）。
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
    /// 全是 1：这一拍写进电平表时「要补乘的增益」—— 渲染块出来的采样已经乘过段增益和推子（tap 那条路才要补）。
    let unitGains: UnsafeMutablePointer<Float>

    init(feeder: AudioTrackFeeder, fader: Float) {
        published = feeder.published
        self.fader = Atomic(fader)
        scratchLeft = .allocate(capacity: Self.maxFrames)
        scratchRight = .allocate(capacity: Self.maxFrames)
        unitGains = .allocate(capacity: Self.maxFrames)
        unitGains.initialize(repeating: 1, count: Self.maxFrames)
    }

    deinit {
        scratchLeft.deallocate()
        scratchRight.deallocate()
        unitGains.deallocate()
    }

    /// 把这一拍混进 `outLeft` / `outRight`（调用方已清零）。返回环里没有、只能当静音的帧数（欠载）。
    func render(position: Int64, frames: Int, into outLeft: UnsafeMutablePointer<Float>,
                _ outRight: UnsafeMutablePointer<Float>) -> Int {
        guard frames <= Self.maxFrames, let set = published.load() else { return 0 }
        let fader = fader.load(ordering: .relaxed)
        var missing = 0
        for stream in set.streams {
            let scene = stream.scene?.load()
            let tail = scene?.tailFrames ?? 0
            let from = max(position, stream.startFrame)
            let to = min(position + Int64(frames), stream.endFrame + tail)
            guard to > from else { continue }
            let count = Int(to - from)
            let offset = Int(from - position)
            // 段内的那一截从环里取；段尾之后（余音）是零。
            let audible = Int(max(0, min(to, stream.endFrame) - from))
            scratchLeft.update(repeating: 0, count: count)
            scratchRight.update(repeating: 0, count: count)
            if audible > 0 {
                let got = stream.ring.accumulate(position: from, frames: audible, into: scratchLeft, scratchRight)
                missing += audible - got
            }
            let gain = stream.gain.load()?.sampler ?? stream.segment.gain
            applyGain(gain, from: from, count: audible)
            if let scene {
                if stream.renderedUpTo != from { scene.chain.reset() }   // 位置跳了（seek、开播）：旧的余音不许拖进新位置
                stream.renderedUpTo = to
                mixScene(scene, fader: fader, count: count, into: outLeft + offset, outRight + offset)
            } else {
                for index in 0..<count {
                    outLeft[offset + index] += scratchLeft[index] * fader
                    outRight[offset + index] += scratchRight[index] * fader
                }
            }
        }
        return missing
    }

    /// 草稿里的 `count` 帧原地乘上段增益：64 帧一块在两端取值、块内线性插值。
    private func applyGain(_ gain: GainTable.Sampler, from: Int64, count: Int) {
        let rate = AudioSegmentReader.engineRate
        let t0 = Double(from) / rate
        var index = 0
        var gainA = gain.gain(at: t0)
        while index < count {
            let block = min(Self.gainBlock, count - index)
            let gainB = gain.gain(at: t0 + Double(index + block) / rate)
            let step = (gainB - gainA) / Float(block)
            var g = gainA
            for k in 0..<block {
                scratchLeft[index + k] *= g
                scratchRight[index + k] *= g
                g += step
            }
            gainA = gainB
            index += block
        }
    }

    /// 草稿（已乘段增益）过场景：原声那一份（1 − 强度）直接进、湿的那一份（强度 × 响度补偿）从链里出来；
    /// 链没渲出来就全给原声，不许凭空少一截声音。最后乘推子。和 `SceneTrackRenderer.render` 同一笔账。
    private func mixScene(_ box: SceneBox, fader: Float, count: Int,
                          into outLeft: UnsafeMutablePointer<Float>, _ outRight: UnsafeMutablePointer<Float>) {
        let chain = box.chain
        let dry = Float(1 - box.scene.amount) * fader
        let input = chain.input
        input.channel(0).update(from: scratchLeft, count: count)
        input.channel(1).update(from: scratchRight, count: count)
        for index in 0..<count {
            outLeft[index] += dry * scratchLeft[index]
            outRight[index] += dry * scratchRight[index]
        }
        guard let output = chain.render(frames: count) else {
            let wet = Float(box.scene.amount) * fader
            for index in 0..<count {
                outLeft[index] += wet * scratchLeft[index]
                outRight[index] += wet * scratchRight[index]
            }
            return
        }
        let wet = Float(box.scene.amount) * box.compensation * fader
        let left = output.channel(0), right = output.channel(1)
        for index in 0..<count {
            outLeft[index] += wet * left[index]
            outRight[index] += wet * right[index]
        }
    }
}
