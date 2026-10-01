import AVFoundation
import Foundation

// MARK: - 按段读素材：从原件里读出引擎格式（48 kHz float，1 或 2 声道）的采样
//
// 管什么：打开一个素材文件，按「素材第几秒起、要多少帧」读出来，顺手把采样率换成 48 kHz。单声道给一路，
// 立体声给两路，更多声道只取前两路。
// 不管什么：这些帧落在时间线的哪里（AudioTrackFeeder）、增益（渲染块）。
//
// 不缓存：直接读 mp3 / aac / wav 原件就够快 —— 2026-10-01 探针，22 条轨边解码边预读、seek 9 ms
// （docs/plans/2026-10-01-audio-engine.md 第三节）。mp3 的精确定位 AVAudioFile 自己做。
//
// 变速（`speed ≠ 1`）交给 AudioTimeStretchReader（AVAudioUnitTimePitch 离线拉伸，音调不变；2026-10-01 PR2c）；
// 这里只管原速的段：直读或者重采样到 48 kHz。
//
// **只在喂样线程上用**（AVAudioFile 不是线程安全的）；随机定位时转换器先 reset，所以每次跳读的头几毫秒
// 重采样器要重新起步 —— 这就是 seek 之后第一拍可能短几十个采样的原因，在环里当静音。

final class AudioSegmentReader {
    static let engineRate = 48_000.0

    /// 读出来几路（1 = 单声道给一路，渲染块自己复制到两边）。
    let channels: Int
    private let file: AVAudioFile
    private let fileRate: Double
    private let speed: Double
    /// nil = 素材本来就是 48 kHz、不变速，直接读。
    private let converter: AVAudioConverter?
    private let fileBuffer: AVAudioPCMBuffer
    /// 和 fileBuffer 同样的数据、但格式标成「采样率 × speed」：转换器只认这个输入格式。
    private let virtualBuffer: AVAudioPCMBuffer?
    private let outputBuffer: AVAudioPCMBuffer
    /// 上一次读完停在素材的第几帧：接着读就不 reset 转换器。
    private var nextSourceFrame: AVAudioFramePosition = -1
    private static let chunk: AVAudioFrameCount = 8192
    /// 变速段：保音调的拉伸读取器接管一切。
    private let stretch: AudioTimeStretchReader?

    init?(url: URL, speed: Double) {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        self.file = file
        self.speed = max(0.05, speed)
        let inFormat = file.processingFormat
        fileRate = inFormat.sampleRate
        channels = inFormat.channelCount == 1 ? 1 : 2
        if abs(self.speed - 1) > 0.001 {
            guard let stretch = AudioTimeStretchReader(url: url, speed: self.speed) else { return nil }
            self.stretch = stretch
        } else {
            stretch = nil
        }
        guard let outFormat = AVAudioFormat(standardFormatWithSampleRate: Self.engineRate, channels: AVAudioChannelCount(channels)),
              let fileBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: Self.chunk * 4),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: Self.chunk * 4)
        else { return nil }
        self.fileBuffer = fileBuffer
        self.outputBuffer = outputBuffer
        let virtualRate = fileRate   // 变速段不走这里（stretch 接管），所以不再乘倍速
        if abs(virtualRate - Self.engineRate) < 0.5, inFormat.channelCount == outFormat.channelCount {
            converter = nil
            virtualBuffer = nil
        } else {
            guard let virtualFormat = AVAudioFormat(standardFormatWithSampleRate: virtualRate, channels: inFormat.channelCount),
                  let virtualBuffer = AVAudioPCMBuffer(pcmFormat: virtualFormat, frameCapacity: Self.chunk * 4),
                  let converter = AVAudioConverter(from: virtualFormat, to: outFormat)
            else { return nil }
            converter.primeMethod = .none
            self.converter = converter
            self.virtualBuffer = virtualBuffer
        }
    }

    /// 素材里有多少秒。
    var sourceDuration: Double { Double(file.length) / fileRate }

    /// 读素材 `sourceSeconds` 起的 `frames` 帧（引擎采样率）到 `left` / `right`（单声道时 `right` 不碰）。
    /// 素材到头了就少给，返回真读到的帧数；没读到的那一截调用方当静音。
    func read(sourceSeconds: Double, frames: Int, into left: UnsafeMutablePointer<Float>,
              _ right: UnsafeMutablePointer<Float>) -> Int {
        if let stretch { return stretch.read(sourceSeconds: sourceSeconds, frames: frames, into: left, right) }
        let wanted = min(frames, Int(Self.chunk * 4))
        guard wanted > 0 else { return 0 }
        let sourceFrame = AVAudioFramePosition((sourceSeconds * fileRate).rounded(.down))
        guard sourceFrame < file.length, sourceFrame >= 0 else { return 0 }
        if sourceFrame != nextSourceFrame {
            file.framePosition = sourceFrame
            converter?.reset()
        }
        guard let converter, let virtualBuffer else {
            // 直读：格式已经是引擎的。
            fileBuffer.frameLength = 0
            guard (try? file.read(into: fileBuffer, frameCount: AVAudioFrameCount(wanted))) != nil else { return 0 }
            let got = Int(fileBuffer.frameLength)
            nextSourceFrame = sourceFrame + AVAudioFramePosition(got)
            copy(fileBuffer, frames: got, into: left, right)
            return got
        }
        // 重采样：按比例多读一点输入，转换器吐出多少算多少。
        let ratio = fileRate / Self.engineRate
        let inputWanted = min(Int(Self.chunk * 4), Int((Double(wanted) * ratio).rounded(.up)) + 64)
        fileBuffer.frameLength = 0
        guard (try? file.read(into: fileBuffer, frameCount: AVAudioFrameCount(inputWanted))) != nil else { return 0 }
        let inputGot = Int(fileBuffer.frameLength)
        guard inputGot > 0 else { return 0 }
        nextSourceFrame = sourceFrame + AVAudioFramePosition(inputGot)
        // 数据原样、只换格式标签（采样率 × speed）。
        virtualBuffer.frameLength = AVAudioFrameCount(inputGot)
        for channel in 0..<Int(fileBuffer.format.channelCount) {
            virtualBuffer.floatChannelData![channel].update(from: fileBuffer.floatChannelData![channel], count: inputGot)
        }
        outputBuffer.frameLength = 0
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return virtualBuffer
        }
        guard status != .error else { return 0 }
        let got = min(wanted, Int(outputBuffer.frameLength))
        copy(outputBuffer, frames: got, into: left, right)
        return got
    }

    private func copy(_ buffer: AVAudioPCMBuffer, frames: Int, into left: UnsafeMutablePointer<Float>,
                      _ right: UnsafeMutablePointer<Float>) {
        guard frames > 0, let data = buffer.floatChannelData else { return }
        left.update(from: data[0], count: frames)
        if channels == 2 {
            right.update(from: data[min(1, Int(buffer.format.channelCount) - 1)], count: frames)
        }
    }
}
