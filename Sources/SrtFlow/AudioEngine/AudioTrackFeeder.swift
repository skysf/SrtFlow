import Foundation
import Synchronization

// MARK: - 一条轨的喂样：按时间线把该出声的段读进各自的环，走在播放头前面
//
// 管什么：这条轨此刻和接下来一秒里会出声的段（`SegmentStream`：段 + 它自己的环 + 它自己的读取器）、每条流的
// 写游标；seek 时每条流的环开新一轮、从新位置重读；把「此刻活着的那几条流」发布给渲染块（AudioPublished）。
// 一段一条流而不是一条轨一条环：主轨转场处前后两段相叠、各自的增益不同，渲染块要分别乘。
// 不管什么：增益、混音（AudioTrackRenderer）；时钟（TimelineAudioEngine）。
//
// 线程：实时播放时自己一条普通 `Thread`（阻塞读不进 Swift 并发池，docs/architecture/blocking-media-reads.md），
// 每 50 ms 或被叫醒（seek、渲染块说环快空了）跑一遍 `service(at:)`；离线渲染时调用方在自己的线程上直接调
// `service`，渲染块随后在同一条线程上取 —— 单写者单读者仍然成立。

/// 一段正在喂的声音。
final class SegmentStream: @unchecked Sendable {
    let segment: AudioEngineConfig.Segment
    let startFrame: Int64
    let endFrame: Int64
    let ring: AudioRing
    let reader: AudioSegmentReader
    /// 下一帧写到时间线的哪一帧（只有喂样线程碰）。
    var writePosition: Int64
    /// 素材读到头了：后面只补静音。
    var exhausted = false

    init?(segment: AudioEngineConfig.Segment, rate: Double, ringFrames: Int, from position: Int64) {
        guard let reader = AudioSegmentReader(url: segment.url, speed: segment.speed) else { return nil }
        self.segment = segment
        self.reader = reader
        startFrame = Int64((segment.start * rate).rounded())
        endFrame = Int64((segment.end * rate).rounded())
        ring = AudioRing(capacity: ringFrames)
        writePosition = max(startFrame, position)
        ring.beginEpoch(position: writePosition)
    }
}

/// 发布给渲染块的「此刻活着的流」（AudioPublished 要一个引用类型）。
final class StreamSet: @unchecked Sendable {
    let streams: [SegmentStream]
    init(_ streams: [SegmentStream]) { self.streams = streams }
}

final class AudioTrackFeeder: @unchecked Sendable {
    static let rate = AudioSegmentReader.engineRate
    /// 每条流的环：半秒。
    static let ringFrames = 24_000
    /// 提前一秒把段的流开起来（开文件、重采样器起步都在这一秒里做完）。
    static let lookaheadFrames: Int64 = 48_000
    /// 一次读多少帧。
    static let chunkFrames = 4096

    let track: AudioEngineConfig.Track
    let published = AudioPublished<StreamSet>(StreamSet([]))
    private var streams: [SegmentStream] = []
    private let seekRequest = Atomic<Int64>(-1)
    private let wake = DispatchSemaphore(value: 0)
    private let running = Atomic<Bool>(false)
    private var thread: Thread?
    private let scratchLeft: UnsafeMutablePointer<Float>
    private let scratchRight: UnsafeMutablePointer<Float>

    init(track: AudioEngineConfig.Track) {
        self.track = track
        scratchLeft = .allocate(capacity: Self.chunkFrames)
        scratchRight = .allocate(capacity: Self.chunkFrames)
    }

    deinit {
        scratchLeft.deallocate()
        scratchRight.deallocate()
    }

    // MARK: 实时：自己的线程

    /// `playhead` 给出此刻播放头在时间线的第几帧（引擎的时钟），每一遍都问一次。
    func start(playhead: @escaping @Sendable () -> Int64) {
        guard !running.exchange(true, ordering: .acquiringAndReleasing) else { return }
        let thread = Thread { [self] in
            while running.load(ordering: .acquiring) {
                service(at: playhead())
                _ = wake.wait(timeout: .now() + .milliseconds(50))
            }
        }
        thread.name = "AudioTrackFeeder \(track.name)"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    func stop() {
        running.store(false, ordering: .releasing)
        wake.signal()
    }

    /// 播放头跳到时间线的第 `frame` 帧：各流从那儿重读（下一遍 `service` 处理）。
    func seek(toFrame frame: Int64) {
        seekRequest.store(frame, ordering: .releasing)
        wake.signal()
    }

    /// 渲染块发现环快空了就叫一声（不阻塞）。
    func poke() { wake.signal() }

    // MARK: 一遍

    /// 处理 seek、按播放头开关流、把每条流的环填满。离线渲染每拍调一次。
    func service(at playheadNow: Int64) {
        var playhead = playheadNow
        let requested = seekRequest.exchange(-1, ordering: .acquiringAndReleasing)
        if requested >= 0 {
            playhead = requested
            for stream in streams {
                stream.writePosition = max(stream.startFrame, playhead)
                stream.exhausted = false
                stream.ring.beginEpoch(position: stream.writePosition)
            }
        }
        var changed = false
        // 已经过去的流关掉（留 0.1 秒余量：渲染块可能还在读它的末尾）。
        let dead = streams.filter { $0.endFrame <= playhead - 4800 }
        if !dead.isEmpty {
            streams.removeAll { stream in dead.contains { $0 === stream } }
            changed = true
        }
        // 接下来一秒里会响的段开流。
        for segment in track.segments
        where !streams.contains(where: { $0.segment.clipID == segment.clipID }) {
            let start = Int64((segment.start * Self.rate).rounded())
            let end = Int64((segment.end * Self.rate).rounded())
            guard start < playhead + Self.lookaheadFrames, end > playhead else { continue }
            guard let stream = SegmentStream(segment: segment, rate: Self.rate, ringFrames: Self.ringFrames, from: playhead)
            else { continue }
            streams.append(stream)
            changed = true
        }
        if changed { published.publish(StreamSet(streams)) }
        for stream in streams { fill(stream) }
    }

    /// 把一条流的环填到满（或者填到段尾）。
    private func fill(_ stream: SegmentStream) {
        while true {
            let remaining = Int(stream.endFrame - stream.writePosition)
            guard remaining > 0 else { return }
            let space = stream.ring.space
            guard space >= Self.chunkFrames || space >= remaining else { return }
            let wanted = min(Self.chunkFrames, remaining, space)
            var got = 0
            if !stream.exhausted {
                let sourceSeconds = stream.segment.sourceStart
                    + Double(stream.writePosition - stream.startFrame) / Self.rate * stream.segment.speed
                got = stream.reader.read(sourceSeconds: sourceSeconds, frames: wanted, into: scratchLeft, scratchRight)
                if got == 0 { stream.exhausted = true }
            }
            if stream.exhausted {
                scratchLeft.update(repeating: 0, count: wanted)
                scratchRight.update(repeating: 0, count: wanted)
                got = wanted
            } else if stream.reader.channels == 1 {
                scratchRight.update(from: scratchLeft, count: got)
            }
            var copied = 0
            stream.ring.write(frames: got) { left, right, count in
                left.update(from: scratchLeft + copied, count: count)
                right.update(from: scratchRight + copied, count: count)
                copied += count
            }
            stream.writePosition += Int64(got)
        }
    }
}
