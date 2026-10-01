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
    /// 轨道头的电平表（nil = 不量）。每条轨的渲染块按拍把峰值写进自己的无锁槽（MeterSlot），总表从混音器的出口取
    /// （实时是 mainMixer 上的 tap，离线是渲出来的那一块）；槽登记进电平表，界面照旧按键读、照旧做回落和红灯
    /// （docs/architecture/audio-engine.md 第三节）。
    let meters: AudioMeterEngine?
    private let masterSlot = MeterSlot()
    /// 渲染块里环里没有数据、只能当静音的帧数（累计）。冒烟和自检看它。
    var underrunFrames: Int { renderClock.underruns.load(ordering: .relaxed) }

    /// 引擎的时钟：渲染线程每拍写、别处读。**采样时间只从渲染块的时间戳来**（节点的 48 kHz 域）——
    /// `outputNode.lastRenderTime` 是声卡自己的采样率（这台机器 44.1 kHz），拿它算位置播放头会以 0.92 倍速走
    /// （2026-10-01 冒烟：欠载 51k 帧、视频对表 60 次）。`Atomic` 不能拷贝、不能被闭包按值捕获，所以收在一个引用里。
    private final class RenderClock: @unchecked Sendable {
        /// 最近一拍的采样时间（这一拍第一帧的）。
        let sampleTime = Atomic<Int64>(0)
        /// 最近一拍对应的 host 时间（这一拍第一帧出声卡的时刻；离线渲染时是 0）。
        let hostTime = Atomic<UInt64>(0)
        /// 最近一拍多少帧：开播 / seek 时锚点要钉在**下一拍**上，差这么多。
        let quantum = Atomic<Int>(0)
        let underruns = Atomic<Int>(0)
    }
    private let renderClock = RenderClock()
    /// 一直挂着的静音节点：没有一条轨出声的时间线也要有人每拍更新时钟。
    private var clockNode: AVAudioSourceNode?
    private var running = false
    /// 试听让路时压的那一份（线性），乘在总推子上。
    private var duckGain: Float = 1
    private let anchor = AudioPublished<PlaybackAnchor>()
    private struct TrackUnit {
        let feeder: AudioTrackFeeder
        let renderer: AudioTrackRenderer
        let node: AVAudioSourceNode
    }
    private var units: [TrackUnit] = []

    init(config: AudioEngineConfig, mode: Mode, meters: AudioMeterEngine? = nil) throws {
        self.mode = mode
        self.config = config
        self.meters = meters
        if mode == .offline {
            try engine.enableManualRenderingMode(.offline, format: Self.format, maximumFrameCount: 4096)
        }
        anchor.publish(PlaybackAnchor(position: 0, sampleTime: 0, playing: false))
        attachClockNode()
        for track in config.tracks { attach(track) }
        engine.mainMixerNode.outputVolume = config.master
        registerMeterSlots()
        if mode == .realtime, meters != nil {
            // 总表：混音器出口的那一拍（含总推子）。tap 在引擎自己的线程上拿到拷贝，不进渲染线程。
            let slot = masterSlot
            engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
                guard let data = buffer.floatChannelData, buffer.format.channelCount >= 1 else { return }
                let right = data[min(1, Int(buffer.format.channelCount) - 1)]
                slot.offer(frames: Int(buffer.frameLength), left: data[0], right: right)
            }
        }
    }

    /// 每条轨的槽 + 总表的槽，整批登记（换配置时重来）。
    private func registerMeterSlots() {
        guard let meters else { return }
        var slots: [MeterKey: MeterSlot] = [.master: masterSlot]
        for (unit, track) in zip(units, config.tracks) { slots[track.meterKey] = unit.renderer.meterSlot }
        meters.registerSlots(slots)
    }

    /// 静音的节点，只负责把每一拍的时间戳记进 `renderClock`。
    private func attachClockNode() {
        let clock = renderClock
        let node = AVAudioSourceNode(format: Self.format) { isSilence, timestamp, frameCount, outputData -> OSStatus in
            Self.tick(clock, timestamp: timestamp, frames: Int(frameCount))
            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            for buffer in buffers { buffer.mData?.assumingMemoryBound(to: Float.self).update(repeating: 0, count: Int(frameCount)) }
            isSilence.pointee = true
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: Self.format)
        clockNode = node
    }

    private static func tick(_ clock: RenderClock, timestamp: UnsafePointer<AudioTimeStamp>, frames: Int) {
        let stamp = timestamp.pointee
        clock.sampleTime.store(Int64(stamp.mSampleTime), ordering: .relaxed)
        clock.hostTime.store(stamp.mHostTime, ordering: .relaxed)
        clock.quantum.store(frames, ordering: .relaxed)
    }

    private func attach(_ track: AudioEngineConfig.Track) {
        let feeder = AudioTrackFeeder(track: track)
        let renderer = AudioTrackRenderer(feeder: feeder, fader: track.fader)
        let anchor = self.anchor
        let clock = renderClock
        let node = AVAudioSourceNode(format: Self.format) { _, timestamp, frameCount, outputData -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            let frames = Int(frameCount)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            left.update(repeating: 0, count: frames)
            right.update(repeating: 0, count: frames)
            Self.tick(clock, timestamp: timestamp, frames: frames)
            guard let anchor = anchor.load(), anchor.playing else { return noErr }
            let position = anchor.position + (Int64(timestamp.pointee.mSampleTime) - anchor.sampleTime)
            let missing = renderer.render(position: position, frames: frames, into: left, right)
            if missing > 0 {
                clock.underruns.wrappingAdd(missing, ordering: .relaxed)
                feeder.poke()
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: Self.format)
        units.append(TrackUnit(feeder: feeder, renderer: renderer, node: node))
    }

    // MARK: 离线：整段渲染

    /// 把时间线从 0 渲到 `duration` 秒，按拍交给 `consumer`（交错的立体声 f32、这一拍的帧数）；`consumer` 回 false 就停
    /// （导出被取消）。成片和自检走这里；喂样在这条线程上同步做。
    func renderOffline(duration: Double, consumer: (UnsafeBufferPointer<Float>, Int) -> Bool) throws {
        precondition(mode == .offline, "renderOffline 只在离线模式下用")
        let total = Int64((duration * Self.sampleRate).rounded())
        guard let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: engine.manualRenderingMaximumFrameCount)
        else { return }
        try engine.start()
        defer { engine.stop() }
        // 离线：渲染块的时间戳从 manualRenderingSampleTime 起，锚点钉在它上面。
        anchor.publish(PlaybackAnchor(position: 0, sampleTime: Int64(engine.manualRenderingSampleTime), playing: true))
        var interleaved = [Float](repeating: 0, count: Int(buffer.frameCapacity) * 2)
        var position: Int64 = 0
        while position < total {
            let frames = Int(min(Int64(buffer.frameCapacity), total - position))
            for unit in units { unit.feeder.service(at: position) }
            let status = try engine.renderOffline(AVAudioFrameCount(frames), to: buffer)
            guard status == .success, let data = buffer.floatChannelData else { throw RenderError(status: status) }
            let got = Int(buffer.frameLength)
            masterSlot.offer(frames: got, left: data[0], right: data[1])
            for index in 0..<got {
                interleaved[2 * index] = data[0][index]
                interleaved[2 * index + 1] = data[1][index]
            }
            let keepGoing = interleaved.withUnsafeBufferPointer { consumer(UnsafeBufferPointer(rebasing: $0[0..<(got * 2)]), got) }
            guard keepGoing else { return }
            position += Int64(got)
        }
    }

    // MARK: 换配置

    /// 整份配置换掉（预览重建之后）：轨的结构可能变了，节点和喂样重来；播放头和播放状态不变。
    /// 结构没变（同样的轨、同样的段）就只换增益，流不重开。
    func replace(config new: AudioEngineConfig) {
        if Self.sameStructure(config, new) {
            updateGains(config: new)
            return
        }
        config = new
        for unit in units {
            unit.feeder.stop()
            engine.detach(unit.node)
        }
        units.removeAll()
        for track in new.tracks { attach(track) }
        engine.mainMixerNode.outputVolume = new.master * duckGain * (muted ? 0 : 1)
        registerMeterSlots()
        if running { startFeeders() }
    }

    /// 只换增益（拖推子 / 曲线、改音量）：按段对上的换采样器，轨道推子、总推子直接换。结构不同就退到 `replace`。
    func updateGains(config new: AudioEngineConfig) {
        guard Self.sameStructure(config, new) else {
            replace(config: new)
            return
        }
        config = new
        for (unit, track) in zip(units, new.tracks) {
            unit.renderer.fader.store(track.fader, ordering: .relaxed)
            unit.feeder.update(Dictionary(track.segments.map { ($0.clipID, SegmentUpdate($0)) }, uniquingKeysWith: { first, _ in first }))
        }
        engine.mainMixerNode.outputVolume = new.master * duckGain * (muted ? 0 : 1)
    }

    /// 试听让路：总推子再乘这么多（1 = 不让）。
    func duck(_ gain: Float) {
        duckGain = gain
        engine.mainMixerNode.outputVolume = config.master * gain * (muted ? 0 : 1)
    }

    /// 整个引擎静音（冒烟用）：总推子照常算，输出不出声卡。
    private var muted = false
    func mute() {
        muted = true
        engine.mainMixerNode.outputVolume = 0
    }

    /// 同样的轨、同样的段，而且每段有没有场景也一样（流开的时候就定了有没有效果链；加上 / 去掉场景要重开流）。
    private static func sameStructure(_ a: AudioEngineConfig, _ b: AudioEngineConfig) -> Bool {
        guard a.tracks.count == b.tracks.count else { return false }
        return zip(a.tracks, b.tracks).allSatisfy { x, y in
            x.name == y.name && x.segments.map(\.clipID) == y.segments.map(\.clipID)
                && x.segments.map { $0.scene != nil } == y.segments.map { $0.scene != nil }
        }
    }

    // MARK: 实时：播放头只是几个数

    /// 起图、起各轨的喂样线程；一开始停在 0。
    func start() throws {
        precondition(mode == .realtime)
        try engine.start()
        running = true
        startFeeders()
    }

    func stop() {
        running = false
        for unit in units { unit.feeder.stop() }
        engine.stop()
    }

    private func startFeeders() {
        for unit in units {
            unit.feeder.start { [weak self] in
                guard let self else { return 0 }
                return Self.position(of: anchor.load(), at: currentSampleTime)
            }
        }
    }

    var isPlaying: Bool { anchor.load()?.playing ?? false }

    /// 此刻播放头在时间线的第几秒：最近一拍的位置，再按 host 时间补上这一拍已经过去的那一截；停着就是锚点。
    var playhead: Double {
        guard let anchor = anchor.load() else { return 0 }
        guard anchor.playing else { return Double(anchor.position) / Self.sampleRate }
        var position = Double(Self.position(of: anchor, at: currentSampleTime))
        let host = renderClock.hostTime.load(ordering: .relaxed)
        if host > 0 {
            let elapsed = AVAudioTime.seconds(forHostTime: mach_absolute_time()) - AVAudioTime.seconds(forHostTime: host)
            let quantum = Double(renderClock.quantum.load(ordering: .relaxed)) / Self.sampleRate
            position += min(max(0, elapsed), quantum * 2) * Self.sampleRate
        }
        return position / Self.sampleRate
    }

    /// 从 `seconds` 起播（锚点钉在下一拍上，第一拍就是这儿的声音）。
    func play(from seconds: Double) {
        let frame = Int64((max(0, seconds) * Self.sampleRate).rounded())
        anchor.publish(PlaybackAnchor(position: frame, sampleTime: nextQuantumSampleTime, playing: true))
        for unit in units { unit.feeder.seek(toFrame: frame) }
    }

    /// 从锚点停着的地方接着播。
    func resume() {
        let position = anchor.load()?.position ?? 0
        anchor.publish(PlaybackAnchor(position: position, sampleTime: nextQuantumSampleTime, playing: true))
    }

    func pause() {
        let now = currentSampleTime
        let position = Self.position(of: anchor.load(), at: now)
        anchor.publish(PlaybackAnchor(position: position, sampleTime: now, playing: false))
    }

    func seek(to seconds: Double) {
        let frame = Int64((max(0, seconds) * Self.sampleRate).rounded())
        let playing = anchor.load()?.playing ?? false
        anchor.publish(PlaybackAnchor(position: frame, sampleTime: nextQuantumSampleTime, playing: playing))
        for unit in units { unit.feeder.seek(toFrame: frame) }
    }

    /// 最近一拍的采样时间（渲染块记的，节点的 48 kHz 域）。
    private var currentSampleTime: Int64 { renderClock.sampleTime.load(ordering: .relaxed) }

    /// 下一拍的采样时间：最近一拍的起点加上它的长度。
    private var nextQuantumSampleTime: Int64 {
        currentSampleTime + Int64(renderClock.quantum.load(ordering: .relaxed))
    }

    private static func position(of anchor: PlaybackAnchor?, at sampleTime: Int64) -> Int64 {
        guard let anchor else { return 0 }
        guard anchor.playing else { return anchor.position }
        return anchor.position + max(0, sampleTime - anchor.sampleTime)
    }
}

/// `PlayerClock` 通过这个协议驱动引擎（AudioEngine/PlaybackAudioSource.swift）。
extension TimelineAudioEngine: PlaybackAudioSource {}
