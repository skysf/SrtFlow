import AVFoundation
import os

// MARK: - 一条合成音轨上的声音场景：在 tap 里按段路由、乘增益、跑效果、让余音散完
//
// 挂了场景的合成音轨**不再让 AVFoundation 乘段的音量**：2026-09-24 探针发现空档里 AVFoundation 一直
// 沿用空档开头那一刻的音量，余音会被下一段的钉点压掉或放大。所以这种轨上 AVFoundation 只放总推子
// （常数），段自己的增益（音量 / 曲线 × 渐变）在这里、**效果之前**乘，轨道推子在**效果之后**乘 ——
// 于是人声淡出时余音照常散完，拉推子连余音一起变小（docs/plans/2026-09-24-sound-scenes.md 拍过的板）。
//
// 每段一条效果链（`SceneChain`），各自的余音各自散：一段结束之后它的链继续吃静音、吐余音，直到余音
// 那么长的时间过去；紧跟着的下一段照常进它自己的链，两边加在一起。没挂场景的段在这里只乘增益。
//
// 预览和成片是同一份：预览在播放器的 tap 里跑，成片离线读同一份合成时也跑它（ExportAudioMixdown）。
// 合同见 docs/architecture/sound-scenes.md。

/// 一条挂了场景的合成音轨，tap 要知道的全部（换 mix 时在主线程算好）。
struct SceneTrackConfig: Sendable {
    struct Span: Sendable {
        var clipID: UUID
        /// 这段在合成里的时间（秒，和插段同一个 1/600 秒刻度，边界上一个采样都不差）。
        var start: Double
        var end: Double
        var scene: SoundScene?
        /// 场景输出乘多少才和原声一样响（`SceneLoudness`）。
        var compensation: Float
    }

    /// 按 `start` 排好。
    var spans: [Span]
    /// 段自己的增益（音量 / 曲线 × 渐变），效果之前乘；不含推子。
    var gains: GainTable.Sampler
    /// 轨道推子，效果之后乘。
    var post: Float

    static let empty = SceneTrackConfig(spans: [], gains: GainTable.Sampler(points: []), post: 1)

    /// 这条合成音轨上的段；一段场景都没挂就返回 nil（这条轨照旧走 AVFoundation 的音量斜坡）。
    static func spans(on lane: AudioMixPlan.Lane, in state: TimelineState) -> [Span]? {
        let spans = lane.clipIDs.compactMap { id -> Span? in
            guard let clip = state.clip(with: id) else { return nil }
            return Span(
                clipID: id,
                start: CMTime(seconds: max(0, clip.timelineStart), preferredTimescale: 600).seconds,
                end: CMTime(seconds: max(0, clip.timelineEnd), preferredTimescale: 600).seconds,
                scene: clip.soundScene,
                compensation: clip.soundScene.map(SceneLoudness.compensation(for:)) ?? 1
            )
        }
        guard spans.contains(where: { $0.scene != nil }) else { return nil }
        return spans.sorted { $0.start < $1.start }
    }
}

/// tap 背后的场景渲染器：一条合成音轨一个，跟着 tap 活（换 mix 只换配置，效果链留着）。
final class SceneTrackRenderer: @unchecked Sendable {
    private struct Shared {
        var config = SceneTrackConfig.empty
        var chains: [UUID: SceneChain] = [:]
        var tails: [UUID: Double] = [:]
        var format: AudioStreamBasicDescription?
        var maxFrames = 0
        /// 换下来的链留到渲染器释放时才放：音频线程可能正拿着上一份配置在渲染。
        var retired: [SceneChain] = []
    }

    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    // 下面这些只在音频线程上碰（prepare 之后）。
    private var gains: [Float] = []
    private var mix: [[Float]] = []
    private var expectedStart: Double?

    /// 主线程：换 mix 时交新的配置。格式已经知道的话，新挂场景 / 换了种类的段当场建链。
    func configure(_ config: SceneTrackConfig) {
        let (format, maxFrames, existing) = shared.withLock { ($0.format, $0.maxFrames, $0.chains) }
        let built = Self.chains(for: config, reusing: existing, format: format, maxFrames: maxFrames)
        shared.withLock { state in
            state.retired += state.chains.values.filter { old in !built.chains.values.contains { $0 === old } }
            state.chains = built.chains
            state.tails = built.tails
            state.config = config
        }
    }

    /// tap 的 prepare：知道处理格式了（采样率、声道数随素材），链按这个格式建。
    func prepare(format: AudioStreamBasicDescription, maxFrames: Int) {
        let (config, existing, old, oldMax) = shared.withLock { ($0.config, $0.chains, $0.format, $0.maxFrames) }
        let same = old.map {
            $0.mSampleRate == format.mSampleRate && $0.mChannelsPerFrame == format.mChannelsPerFrame
        } ?? false
        let built = Self.chains(
            for: config, reusing: same && oldMax >= maxFrames ? existing : [:],
            format: format, maxFrames: max(maxFrames, oldMax)
        )
        shared.withLock { state in
            state.retired += state.chains.values.filter { old in !built.chains.values.contains { $0 === old } }
            state.chains = built.chains
            state.tails = built.tails
            state.format = format
            state.maxFrames = max(maxFrames, oldMax)
        }
        let capacity = max(maxFrames, oldMax)
        gains = Array(repeating: 1, count: capacity)
        mix = Array(repeating: Array(repeating: 0, count: capacity), count: max(1, Int(format.mChannelsPerFrame)))
        expectedStart = nil
    }

    private static func chains(
        for config: SceneTrackConfig, reusing existing: [UUID: SceneChain],
        format: AudioStreamBasicDescription?, maxFrames: Int
    ) -> (chains: [UUID: SceneChain], tails: [UUID: Double]) {
        guard let format, maxFrames > 0 else { return ([:], [:]) }
        var chains: [UUID: SceneChain] = [:]
        var tails: [UUID: Double] = [:]
        for span in config.spans {
            guard let scene = span.scene else { continue }
            let reused = existing[span.clipID].flatMap { $0.kind == scene.kind ? $0 : nil }
            guard let chain = reused ?? SceneChain(kind: scene.kind, format: format, maxFrames: maxFrames) else {
                continue
            }
            chain.apply(scene)
            chains[span.clipID] = chain
            tails[span.clipID] = chain.tailSeconds
        }
        return (chains, tails)
    }

    /// 音频线程：一次 tap 回调，原地把 `buffers` 换成这条轨此刻该出的声音（乘过轨道推子）。
    /// `start` 为 nil = 这一拍时间无效（开播第一拍、暂停 / seek 之后的空转）：输出静音、不碰效果链 ——
    /// 空转时也跑效果链的话，余音会被耗掉。
    func process(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int, start: Double?) {
        let snapshot = shared.withLock { $0 }
        guard let format = snapshot.format, frames > 0, frames <= gains.count else { return }
        let channels = min(buffers.count, mix.count)
        guard let start else {
            for index in 0..<buffers.count { buffers[index].mData?.initializeMemory(as: Float.self, repeating: 0, count: frames) }
            return
        }
        let rate = format.mSampleRate
        // 时间跳了（seek、从头播）：旧的余音不许拖进新位置。
        if let expected = expectedStart, abs(start - expected) > 0.01 {
            snapshot.chains.values.forEach { $0.reset() }
        }
        expectedStart = start + Double(frames) / rate
        fillGains(snapshot.config.gains, start: start, rate: rate, frames: frames)
        for channel in 0..<channels {
            mix[channel].withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        }

        let end = start + Double(frames) / rate
        for span in snapshot.config.spans where span.start < end {
            let tail = span.scene == nil ? 0 : (snapshot.tails[span.clipID] ?? 0)
            guard span.end + tail > start else { continue }
            let first = max(0, min(frames, Int(((span.start - start) * rate).rounded(.up))))
            let last = max(0, min(frames, Int(((span.end - start) * rate).rounded(.up))))
            if let scene = span.scene, let chain = snapshot.chains[span.clipID] {
                render(scene, chain: chain, compensation: span.compensation, buffers: buffers,
                       channels: channels, frames: frames, range: first..<last)
            } else {
                for channel in 0..<channels {
                    let source = buffers[channel].mData!.assumingMemoryBound(to: Float.self)
                    for index in first..<last { mix[channel][index] += source[index] * gains[index] }
                }
            }
        }

        let post = snapshot.config.post
        for channel in 0..<buffers.count {
            let target = buffers[channel].mData!.assumingMemoryBound(to: Float.self)
            let from = min(channel, channels - 1)
            for index in 0..<frames { target[index] = mix[from][index] * post }
        }
    }

    /// 一段挂了场景的声音：段内的原声（乘过段增益）进链，段外进静音（余音就是这么散出来的）。
    /// 原声那一份（1 − 强度）在渲染**之前**加进混音 —— 串了两个单元的链会把输入那一块写掉。
    private func render(
        _ scene: SoundScene, chain: SceneChain, compensation: Float,
        buffers: UnsafeMutableAudioBufferListPointer, channels: Int, frames: Int, range: Range<Int>
    ) {
        let dry = Float(1 - scene.amount)
        for channel in 0..<chain.input.channels {
            let input = chain.input.channel(channel)
            let source = buffers[min(channel, buffers.count - 1)].mData!.assumingMemoryBound(to: Float.self)
            for index in 0..<frames {
                input[index] = range.contains(index) ? source[index] * gains[index] : 0
            }
            if channel < channels {
                for index in range { mix[channel][index] += dry * input[index] }
            }
        }
        guard let output = chain.render(frames: frames) else {
            // 链没渲染出来：这一块把「湿」的那一份也换成原声，不许凭空少一截声音。
            for channel in 0..<channels {
                let source = buffers[channel].mData!.assumingMemoryBound(to: Float.self)
                for index in range { mix[channel][index] += Float(scene.amount) * source[index] * gains[index] }
            }
            return
        }
        let wet = Float(scene.amount) * compensation
        for channel in 0..<channels {
            let rendered = output.channel(channel)
            for index in 0..<frames { mix[channel][index] += wet * rendered[index] }
        }
    }

    /// 每个采样的段增益：32 帧一小段线性插值（同电平表的做法，斜坡是平滑的）。
    private func fillGains(_ sampler: GainTable.Sampler, start: Double, rate: Double, frames: Int) {
        let step = 32
        var index = 0
        while index < frames {
            let end = min(frames, index + step)
            let g0 = sampler.gain(at: start + Double(index) / rate)
            let g1 = sampler.gain(at: start + Double(end) / rate)
            for i in index..<end {
                gains[i] = g0 + (g1 - g0) * Float(i - index) / Float(end - index)
            }
            index = end
        }
    }
}
