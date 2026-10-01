import AVFoundation
import Foundation

// MARK: - 变速段的读取：保音调地拉伸（AVAudioUnitTimePitch 离线跑）
//
// 管什么：一个素材文件、一个倍速；按「素材第几秒起、要多少输出帧」给出**拉伸之后**的 48 kHz 采样，音调不变。
// 内部是一个离线（manual rendering）的小 AVAudioEngine：AVAudioPlayerNode → AVAudioUnitTimePitch(rate) → 混音器，
// 随机定位时停下重排、把单元的延迟先渲掉（对齐到要的那一帧），顺序读就接着渲。
// 不管什么：这些帧落在时间线的哪里（AudioTrackFeeder）、增益、场景（渲染块）。
//
// 和成片同一种做法：成片（PR3）也从这里读变速段。以前的「当成采样率 × speed 重采样」会变调。
// **只在喂样线程上用**（离线引擎不是线程安全的）。

final class AudioTimeStretchReader {
    static let engineRate = AudioSegmentReader.engineRate

    let channels: Int
    private let file: AVAudioFile
    private let fileRate: Double
    private let speed: Double
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let pitch = AVAudioUnitTimePitch()
    private let output: AVAudioPCMBuffer
    /// 顺序读时下一次该从素材的第几帧起（差两帧以内算接着读）。
    private var nextSourceFrame: AVAudioFramePosition = -1
    /// 这一轮排进去的段还剩多少素材帧没渲出来（按倍速折成输出帧就是还能给多少）。
    private var remainingSource: Double = 0

    init?(url: URL, speed: Double) {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        self.file = file
        self.speed = max(0.05, speed)
        fileRate = file.processingFormat.sampleRate
        channels = file.processingFormat.channelCount == 1 ? 1 : 2
        guard let outFormat = AVAudioFormat(standardFormatWithSampleRate: Self.engineRate, channels: AVAudioChannelCount(channels)),
              let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 8192) else { return nil }
        self.output = output
        pitch.rate = Float(self.speed)
        engine.attach(player)
        engine.attach(pitch)
        engine.connect(player, to: pitch, format: file.processingFormat)
        engine.connect(pitch, to: engine.mainMixerNode, format: outFormat)
        do {
            try engine.enableManualRenderingMode(.offline, format: outFormat, maximumFrameCount: 8192)
            try engine.start()
        } catch {
            return nil
        }
    }

    deinit { engine.stop() }

    /// 读素材 `sourceSeconds` 起、拉伸之后的 `frames` 帧（引擎采样率）。素材到头了就少给，返回真读到的帧数。
    func read(sourceSeconds: Double, frames: Int, into left: UnsafeMutablePointer<Float>,
              _ right: UnsafeMutablePointer<Float>) -> Int {
        let wanted = min(frames, Int(output.frameCapacity))
        guard wanted > 0 else { return 0 }
        let sourceFrame = AVAudioFramePosition((sourceSeconds * fileRate).rounded(.down))
        guard sourceFrame >= 0, sourceFrame < file.length else { return 0 }
        // 第一次读（还没排过）或者跳读（差两帧以上）都重排；素材从第 0 帧起的段第一次读时 |0 − (−1)| 只差 1，不能拿差值判。
        if nextSourceFrame < 0 || abs(sourceFrame - nextSourceFrame) > 2 { restart(at: sourceFrame) }
        // 还能给多少输出帧：剩下的素材帧 ÷ 倍速，换成引擎采样率。
        let available = Int((remainingSource / speed * Self.engineRate / fileRate).rounded(.down))
        let count = min(wanted, available)
        guard count > 0 else { return 0 }
        guard render(count) else { return 0 }
        let got = Int(output.frameLength)
        copy(got, into: left, right)
        let consumed = Double(got) / Self.engineRate * speed * fileRate
        remainingSource -= consumed
        nextSourceFrame += AVAudioFramePosition(consumed.rounded())
        return got
    }

    /// 从素材的某一帧起重新排：停下、复位单元、排上剩下的整段、把单元的延迟先渲掉。
    private func restart(at sourceFrame: AVAudioFramePosition) {
        player.stop()
        pitch.reset()
        let remaining = AVAudioFrameCount(max(0, file.length - sourceFrame))
        remainingSource = Double(remaining)
        nextSourceFrame = sourceFrame
        guard remaining > 0 else { return }
        player.scheduleSegment(file, startingFrame: sourceFrame, frameCount: remaining, at: nil)
        player.play()
        let latency = Int((Double(pitch.latency) * Self.engineRate).rounded())
        var left = latency
        while left > 0 {
            let chunk = min(left, Int(output.frameCapacity))
            guard render(chunk) else { break }
            left -= Int(output.frameLength)
        }
    }

    private func render(_ frames: Int) -> Bool {
        output.frameLength = 0
        guard let status = try? engine.renderOffline(AVAudioFrameCount(frames), to: output) else { return false }
        return status == .success
    }

    private func copy(_ frames: Int, into left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>) {
        guard frames > 0, let data = output.floatChannelData else { return }
        left.update(from: data[0], count: frames)
        if channels == 2 { right.update(from: data[1], count: frames) }
    }
}
