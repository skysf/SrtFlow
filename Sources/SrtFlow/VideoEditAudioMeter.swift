import AVFoundation
import MediaToolbox
import os

// MARK: - 电平表：轨道头推子里的电平条 + 总电平表 + 爆音红灯
//
// 2026-09-23 探针（docs/plans/2026-09-23-audio-mixing.md 第三节）定下的做法：
//
// 1. 每条合成音轨挂一个 `MTAudioProcessingTap`（PreEffects）。tap 拿到的是
//    **乘音量之前**的采样（两种 flag 都看不到 audioMix 的音量），所以增益由我们自己乘：
//    用的是**同一张** `GainTable`（makeAudioMix 往 AVFoundation 里铺的就是它）。
// 2. **tap 必须跟着合成活**：每次换 audioMix 就新建 tap 的话，播放会静默卡住约 0.6 秒；
//    复用同一个 tap 对象则完全平滑。所以 tap 按合成音轨缓存，换 mix 时挂回同一个，
//    只换它背后的增益表。
// 3. 两条轨的 tap 回调**不对齐**（时间网格差几百帧），总表只能按**绝对采样位置**把各轨
//    加起来 —— 同一条时间线轨的 A/B 两条合成轨（主轨）也一样按位置相加。
// 4. 实时播放时 tap 比播放头提前约 280ms 渲染：写进环形缓冲（按位置），界面在播放头处读。
// 5. 暂停后 tap 仍每 ~93ms 空转一次（时长 0）、开播后第一拍时间无效 —— 都按时长过滤掉。
//
// 合同见 docs/architecture/audio-mixer.md。

/// 电平表的身份：某条时间线轨（主轨 / 某条 lane），或者总输出。
enum MeterKey: Hashable, Sendable {
    case track(TimelineRowHeightKey)
    case master
}

// MARK: - 增益表（AVFoundation 那一串音量设定的同一份）

/// 一条合成音轨上的音量设定，按时间顺序。`makeAudioMix` 先把它记下来，再原样铺进
/// `AVMutableAudioMixInputParameters`（乘上总推子）—— 电平表拿的是同一份，
/// 所以表上看到的就是听到的。
struct GainTable: Sendable {
    struct Segment: Sendable {
        var start: CMTime
        var end: CMTime
        var from: Float
        var to: Float
    }

    private(set) var segments: [Segment] = []

    /// 从 `time` 起音量是 `value`（AVFoundation 的 `setVolume(_:at:)`）。
    mutating func set(_ value: Float, at time: CMTime) {
        segments.append(Segment(start: time, end: time, from: value, to: value))
    }

    /// 一段线性斜坡（AVFoundation 的 `setVolumeRamp`）。
    mutating func ramp(from: Float, to: Float, range: CMTimeRange) {
        segments.append(Segment(start: range.start, end: range.end, from: from, to: to))
    }

    /// 原样铺进 AVFoundation，每个值乘 `scale`（总推子）。
    func apply(to params: AVMutableAudioMixInputParameters, scale: Float) {
        for segment in segments {
            if CMTimeCompare(segment.end, segment.start) > 0 {
                params.setVolumeRamp(
                    fromStartVolume: segment.from * scale, toEndVolume: segment.to * scale,
                    timeRange: CMTimeRange(start: segment.start, end: segment.end)
                )
            } else {
                params.setVolume(segment.from * scale, at: segment.start)
            }
        }
    }

    /// 某一刻的音量（与 AVFoundation 的语义一致：斜坡里线性插值，斜坡之间保持上一个值，
    /// 第一个设定之前是默认的 1.0）。按秒存一份，免得音频线程里反复换算 CMTime。
    func sampler() -> Sampler {
        Sampler(points: segments.map {
            Sampler.Point(start: $0.start.seconds, end: $0.end.seconds, from: $0.from, to: $0.to)
        })
    }

    struct Sampler: Sendable {
        struct Point: Sendable {
            var start: Double
            var end: Double
            var from: Float
            var to: Float
        }
        let points: [Point]

        func gain(at time: Double) -> Float {
            guard let first = points.first, time >= first.start else { return 1 }
            var low = 0
            var high = points.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if points[mid].start <= time { low = mid } else { high = mid - 1 }
            }
            let point = points[low]
            guard time < point.end, point.end > point.start else { return point.to }
            let fraction = Float((time - point.start) / (point.end - point.start))
            return point.from + (point.to - point.from) * fraction
        }
    }
}

// MARK: - 按位置累加的环形缓冲

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
    func add(position: Int64, left l: Float, right r: Float, now: UInt64) {
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

// MARK: - 读数

/// 一条电平表此刻该画成什么样（dB）。
struct MeterReading: Equatable, Sendable {
    var left: Double
    var right: Double
    /// 峰值保持的那一道（dB）。
    var hold: Double
    /// 这一遍播放里过过 0 dBFS（红灯；下一次开播自动熄）。
    var clipped: Bool

    static let silent = MeterReading(left: AudioGain.minimumDB, right: AudioGain.minimumDB,
                                     hold: AudioGain.minimumDB, clipped: false)
}

// MARK: - 引擎

/// 电平表的全部状态：每条合成音轨的 tap、每条表的采样环、每条表的显示状态。
/// 音频线程（tap 回调）写、主线程（界面）读，共用一把锁。
final class AudioMeterEngine: @unchecked Sendable {
    private struct State {
        var contexts: [Int32: TapContext] = [:]
        var taps: [Int32: MTAudioProcessingTap] = [:]
        var rings: [MeterKey: SampleRing] = [:]
        var display: [MeterKey: Display] = [:]
        var clipped: Set<MeterKey> = []
    }

    private struct Display {
        var level: (left: Double, right: Double) = (AudioGain.minimumDB, AudioGain.minimumDB)
        var hold = AudioGain.minimumDB
        var holdUntil = 0.0
        var updated = 0.0
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let ringCapacity: Int

    /// 显示的回落速度（dB/秒）和峰值保持多久（秒）。
    static let fallRate = 24.0
    static let holdSeconds = 1.5
    /// 界面在播放头前后读多长一窗（秒）。
    static let window = 0.05

    init(ringCapacity: Int = 1 << 16) {
        self.ringCapacity = ringCapacity
    }

    /// 换了一条新的合成（预览重建）：旧 tap 全部作废（它们挂在旧的 item 上），环也清掉。
    func beginComposition() {
        lock.withLock { state in
            state.contexts = [:]
            state.taps = [:]
            state.rings = [:]
            state.display = [:]
        }
    }

    /// 某条合成音轨的 tap：同一条合成里**复用同一个**（换 mix 时新建 tap 会让播放卡住），
    /// 只把它背后的增益表、归属和总推子换掉。
    func tap(trackID: Int32, key: MeterKey, table: GainTable, master: Float) -> MTAudioProcessingTap? {
        let sampler = table.sampler()
        return lock.withLock { state -> MTAudioProcessingTap? in
            if let context = state.contexts[trackID], let tap = state.taps[trackID] {
                context.configure(key: key, sampler: sampler, master: master)
                return tap
            }
            PerfCounters.event(.meterTapCreate)
            let context = TapContext(engine: self)
            context.configure(key: key, sampler: sampler, master: master)
            guard let tap = context.makeTap() else { return nil }
            state.contexts[trackID] = context
            state.taps[trackID] = tap
            return tap
        }
    }

    /// 开播时把上一遍的红灯熄掉（「这一遍播下来爆没爆」）。
    func clearClips() {
        lock.withLock { $0.clipped = [] }
    }

    /// 这条表的红灯亮着吗（停播时界面不再读电平，但红灯要留着）。
    func isClipped(_ key: MeterKey) -> Bool {
        lock.withLock { $0.clipped.contains(key) }
    }

    /// tap 回调里：把一段「听到的」采样按位置加进这条轨的环和总表的环。
    fileprivate func write(key: MeterKey, start: Int64, left: UnsafePointer<Float>, right: UnsafePointer<Float>?,
                           gains: UnsafePointer<Float>, master: Float, count: Int, positions: UnsafePointer<Int64>?) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.withLock { state in
            let capacity = ringCapacity
            let ring = state.rings[key] ?? { let made = SampleRing(capacity: capacity); state.rings[key] = made; return made }()
            let masterRing = state.rings[.master]
                ?? { let made = SampleRing(capacity: capacity); state.rings[.master] = made; return made }()
            for index in 0..<count {
                let l = left[index] * gains[index]
                let r = (right?[index] ?? left[index]) * gains[index]
                let position = positions?[index] ?? (start + Int64(index))
                ring.add(position: position, left: l, right: r, now: now)
                masterRing.add(position: position, left: l * master, right: r * master, now: now)
            }
        }
    }

    /// 界面在播放头 `time` 处读一条表：取最近 50ms 的峰值，按回落速度和峰值保持平滑；
    /// 过了 0 dBFS 就把红灯点上（一直亮到下一次开播）。
    func reading(for key: MeterKey, at time: Double, now: Double) -> MeterReading {
        let to = Int64((time * SampleRing.rate).rounded())
        let from = to - Int64(Self.window * SampleRing.rate)
        return lock.withLock { (state: inout State) -> MeterReading in
            let peak: (left: Float, right: Float) = state.rings[key]?.peak(from: from, to: to) ?? (0, 0)
            if max(peak.left, peak.right) > 1 { state.clipped.insert(key) }
            var display = state.display[key] ?? Display()
            let elapsed = display.updated > 0 ? max(0, now - display.updated) : 0
            let left = Self.smoothed(display.level.left, peak.left, elapsed: elapsed)
            let right = Self.smoothed(display.level.right, peak.right, elapsed: elapsed)
            display.level = (left, right)
            let top = max(left, right)
            if top >= display.hold || now > display.holdUntil {
                display.hold = top
                display.holdUntil = now + Self.holdSeconds
            }
            display.updated = now
            state.display[key] = display
            return MeterReading(left: left, right: right, hold: display.hold, clipped: state.clipped.contains(key))
        }
    }

    /// 起音立刻跟上，回落按 `fallRate` 慢慢掉（表不会一跳一跳地闪）。
    private static func smoothed(_ previous: Double, _ sample: Float, elapsed: Double) -> Double {
        let fresh = AudioGain.decibels(fromLinear: Double(sample))
        return max(fresh, max(AudioGain.minimumDB, previous - fallRate * elapsed))
    }

    /// 自检用：某条表在 `[from, to)`（秒）上的原始峰值（不经过回落平滑）。
    func rawPeak(for key: MeterKey, from: Double, to: Double) -> (left: Float, right: Float) {
        lock.withLock { state in
            state.rings[key]?.peak(from: Int64((from * SampleRing.rate).rounded()),
                                   to: Int64((to * SampleRing.rate).rounded())) ?? (0, 0)
        }
    }
}

// MARK: - tap

/// 一条合成音轨的 tap 背后的东西：归属（哪条表）、增益表、总推子、预分配的草稿缓冲。
/// 配置由主线程在换 mix 时写、音频线程在回调里读 —— 用它自己的一把锁（很短）。
final class TapContext: @unchecked Sendable {
    private struct Config {
        var key: MeterKey = .master
        var sampler = GainTable.Sampler(points: [])
        var master: Float = 1
    }

    private weak var engine: AudioMeterEngine?
    private let config = OSAllocatedUnfairLock(initialState: Config())
    fileprivate var sampleRate = SampleRing.rate
    fileprivate var gains: [Float] = []
    fileprivate var positions: [Int64] = []

    init(engine: AudioMeterEngine) {
        self.engine = engine
    }

    func configure(key: MeterKey, sampler: GainTable.Sampler, master: Float) {
        config.withLock { $0 = Config(key: key, sampler: sampler, master: master) }
    }

    func makeTap() -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(self).toOpaque(),
            init: meterTapInit,
            finalize: meterTapFinalize,
            prepare: meterTapPrepare,
            unprepare: meterTapUnprepare,
            process: meterTapProcess
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks,
            MTAudioProcessingTapCreationFlags(kMTAudioProcessingTapCreationFlag_PreEffects), &tap
        )
        return status == noErr ? tap : nil
    }

    fileprivate func prepare(maxFrames: Int, sampleRate: Double) {
        self.sampleRate = sampleRate > 0 ? sampleRate : SampleRing.rate
        gains = Array(repeating: 1, count: max(1, maxFrames))
        positions = Array(repeating: 0, count: max(1, maxFrames))
    }

    /// 一次回调：算出每个采样此刻的增益（按 32 帧一小段插值，斜坡是平滑的），
    /// 连同位置交给引擎累加。
    fileprivate func consume(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int, start: Double) {
        guard let engine, frames > 0 else { return }
        if gains.count < frames {
            gains = Array(repeating: 1, count: frames)
            positions = Array(repeating: 0, count: frames)
        }
        let settings = config.withLock { $0 }
        let rate = sampleRate
        let step = 32
        var index = 0
        while index < frames {
            let end = min(frames, index + step)
            let g0 = settings.sampler.gain(at: start + Double(index) / rate)
            let g1 = settings.sampler.gain(at: start + Double(end) / rate)
            for i in index..<end {
                gains[i] = g0 + (g1 - g0) * Float(i - index) / Float(end - index)
                positions[i] = Int64(((start + Double(i) / rate) * SampleRing.rate).rounded())
            }
            index = end
        }
        guard let first = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return }
        let second = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
        gains.withUnsafeBufferPointer { gainBuffer in
            positions.withUnsafeBufferPointer { positionBuffer in
                engine.write(
                    key: settings.key, start: positionBuffer[0],
                    left: UnsafePointer(first), right: second.map { UnsafePointer($0) },
                    gains: gainBuffer.baseAddress!, master: settings.master, count: frames,
                    positions: positionBuffer.baseAddress
                )
            }
        }
    }
}

// C 回调：clientInfo 里是 passRetained 的 TapContext，finalize 时释放。

private let meterTapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, storageOut in
    storageOut.pointee = clientInfo
}

private let meterTapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private let meterTapPrepare: MTAudioProcessingTapPrepareCallback = { tap, maxFrames, format in
    Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
        .prepare(maxFrames: Int(maxFrames), sampleRate: format.pointee.mSampleRate)
}

private let meterTapUnprepare: MTAudioProcessingTapUnprepareCallback = { _ in }

private let meterTapProcess: MTAudioProcessingTapProcessCallback = { tap, frames, _, bufferList, framesOut, flagsOut in
    var range = CMTimeRange()
    var got: CMItemCount = 0
    let status = MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, &range, &got)
    framesOut.pointee = got
    // 开播后第一拍时间无效、暂停后空转的回调时长为 0：都不是真在播的声音。
    guard status == noErr, got > 0, range.start.isValid, range.duration.isValid,
          range.duration.seconds > 0 else { return }
    Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
        .consume(UnsafeMutableAudioBufferListPointer(bufferList), frames: Int(got), start: range.start.seconds)
}
