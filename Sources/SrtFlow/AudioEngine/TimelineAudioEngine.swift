import AVFoundation
import Foundation
import Synchronization

// MARK: - 时间线的声音引擎：图、时钟锚点、实时播放与离线渲染
//
// 管什么：一个 AVAudioEngine，每条轨一个 AVAudioSourceNode（渲染块在 AudioTrackRenderer），各轨的喂样
// （AudioTrackFeeder），总推子在 mainMixer；播放头的锚点（`PlaybackAnchor`：引擎的采样时间 ↔ 时间线的帧），
// 实时的 play / pause / seek，和离线的整段渲染（manual rendering，成片和自检用同一条路）。
// 不管什么：配置怎么从时间线算（AudioEngineConfig）；和视频对表、喂 PlayerClock（PR1b，VideoEditProject 那边接）。
//
// 时钟：渲染块拿到的时间戳是引擎的采样时间，**所有轨同一拍拿到同一个数**，各自按锚点换成时间线的帧 ——
// 不用谁先谁后的问题。seek = 发布一个新锚点 + 让各轨的喂样从新位置重读；暂停 = 锚点标成不播（渲染块出静音，
// 图不停）；所以 seek 和开播都只是改几个数，不拆任何东西（2026-10-01 探针：22 轨 9 ms，一个 IO 缓冲）。
// 方案：docs/plans/2026-10-01-audio-engine.md。

/// 播放头的锚点：引擎采样时间 `sampleTime` 那一刻，时间线在第 `position` 帧；`playing` 为 false 时位置钉住。
final class PlaybackAnchor: @unchecked Sendable {
    let position: Int64
    let sampleTime: Int64
    let playing: Bool
    init(position: Int64, sampleTime: Int64, playing: Bool) {
        self.position = position
        self.sampleTime = sampleTime
        self.playing = playing
    }
}

final class TimelineAudioEngine {
    static let sampleRate = AudioSegmentReader.engineRate
    static let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!

    enum Mode { case realtime, offline }
    struct RenderError: Error { let status: AVAudioEngineManualRenderingStatus }

    let mode: Mode
    let engine = AVAudioEngine()
    private(set) var config: AudioEngineConfig
    /// 渲染块里环里没有数据、只能当静音的帧数（累计）。冒烟和自检看它。
    var underrunFrames: Int { underruns.frames.load(ordering: .relaxed) }
    /// `Atomic` 不能拷贝、不能被闭包按值捕获，渲染块里要累加就得经一个引用。
    private final class UnderrunCounter: @unchecked Sendable {
        let frames = Atomic<Int>(0)
    }
    private let underruns = UnderrunCounter()
    private let anchor = AudioPublished<PlaybackAnchor>()
    private struct TrackUnit {
        let feeder: AudioTrackFeeder
        let renderer: AudioTrackRenderer
        let node: AVAudioSourceNode
    }
    private var units: [TrackUnit] = []

    init(config: AudioEngineConfig, mode: Mode) throws {
        self.mode = mode
        self.config = config
        if mode == .offline {
            try engine.enableManualRenderingMode(.offline, format: Self.format, maximumFrameCount: 4096)
        }
        anchor.publish(PlaybackAnchor(position: 0, sampleTime: 0, playing: false))
        for track in config.tracks { attach(track) }
        engine.mainMixerNode.outputVolume = config.master
    }

    private func attach(_ track: AudioEngineConfig.Track) {
        let feeder = AudioTrackFeeder(track: track)
        let renderer = AudioTrackRenderer(feeder: feeder, fader: track.fader)
        let anchor = self.anchor
        let underruns = self.underruns
        let node = AVAudioSourceNode(format: Self.format) { _, timestamp, frameCount, outputData -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            let frames = Int(frameCount)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            left.update(repeating: 0, count: frames)
            right.update(repeating: 0, count: frames)
            guard let anchor = anchor.load(), anchor.playing else { return noErr }
            let position = anchor.position + (Int64(timestamp.pointee.mSampleTime) - anchor.sampleTime)
            let missing = renderer.render(position: position, frames: frames, into: left, right)
            if missing > 0 {
                underruns.frames.wrappingAdd(missing, ordering: .relaxed)
                feeder.poke()
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: Self.format)
        units.append(TrackUnit(feeder: feeder, renderer: renderer, node: node))
    }

    // MARK: 离线：整段渲染

    /// 把时间线从 0 渲到 `duration` 秒，按拍交给 `consumer`（交错的立体声 f32、这一拍的帧数）。
    /// 成片和自检走这里；喂样在这条线程上同步做。
    func renderOffline(duration: Double, consumer: (UnsafeBufferPointer<Float>, Int) -> Void) throws {
        precondition(mode == .offline, "renderOffline 只在离线模式下用")
        let total = Int64((duration * Self.sampleRate).rounded())
        guard let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: engine.manualRenderingMaximumFrameCount)
        else { return }
        try engine.start()
        defer { engine.stop() }
        anchor.publish(PlaybackAnchor(position: 0, sampleTime: Int64(engine.manualRenderingSampleTime), playing: true))
        var interleaved = [Float](repeating: 0, count: Int(buffer.frameCapacity) * 2)
        var position: Int64 = 0
        while position < total {
            let frames = Int(min(Int64(buffer.frameCapacity), total - position))
            for unit in units { unit.feeder.service(at: position) }
            let status = try engine.renderOffline(AVAudioFrameCount(frames), to: buffer)
            guard status == .success, let data = buffer.floatChannelData else { throw RenderError(status: status) }
            let got = Int(buffer.frameLength)
            for index in 0..<got {
                interleaved[2 * index] = data[0][index]
                interleaved[2 * index + 1] = data[1][index]
            }
            interleaved.withUnsafeBufferPointer { consumer(UnsafeBufferPointer(rebasing: $0[0..<(got * 2)]), got) }
            position += Int64(got)
        }
    }

    // MARK: 实时：播放头只是几个数

    /// 起图、起各轨的喂样线程；一开始停在 0。
    func start() throws {
        precondition(mode == .realtime)
        try engine.start()
        for unit in units { unit.feeder.start { [anchor] in Self.position(of: anchor.load(), at: 0) } }
    }

    func stop() {
        for unit in units { unit.feeder.stop() }
        engine.stop()
    }

    /// 此刻播放头在时间线的第几秒（按引擎最近一拍的采样时间算；停着就是锚点）。
    var playhead: Double {
        Double(Self.position(of: anchor.load(), at: currentSampleTime)) / Self.sampleRate
    }

    func play(from seconds: Double? = nil) {
        let current = anchor.load()
        let frame = seconds.map { Int64(($0 * Self.sampleRate).rounded()) } ?? (current?.position ?? 0)
        anchor.publish(PlaybackAnchor(position: frame, sampleTime: currentSampleTime, playing: true))
        if seconds != nil { for unit in units { unit.feeder.seek(toFrame: frame) } }
    }

    func pause() {
        let now = currentSampleTime
        let position = Self.position(of: anchor.load(), at: now)
        anchor.publish(PlaybackAnchor(position: position, sampleTime: now, playing: false))
    }

    func seek(to seconds: Double) {
        let frame = Int64((max(0, seconds) * Self.sampleRate).rounded())
        let playing = anchor.load()?.playing ?? false
        anchor.publish(PlaybackAnchor(position: frame, sampleTime: currentSampleTime, playing: playing))
        for unit in units { unit.feeder.seek(toFrame: frame) }
    }

    private var currentSampleTime: Int64 {
        Int64(engine.outputNode.lastRenderTime?.sampleTime ?? 0)
    }

    private static func position(of anchor: PlaybackAnchor?, at sampleTime: Int64) -> Int64 {
        guard let anchor else { return 0 }
        guard anchor.playing else { return anchor.position }
        return anchor.position + max(0, sampleTime - anchor.sampleTime)
    }
}
