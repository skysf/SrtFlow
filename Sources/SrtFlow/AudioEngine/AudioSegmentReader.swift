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
    /// 下一次接着读会产出引擎格式的第几帧（素材时间 × 48 kHz）；-1 = 还没读过 / 刚跳读过。
    /// 比「素材第几帧」靠谱：重采样时输入和输出不成整数比，按输出算才知道这一次是不是上一次的延续。
    private var nextOutputFrame: Int64 = -1
    /// 引擎格式（48 kHz float，1 或 2 声道）：重采样时每次按要多少帧现开一个正好那么大的输出缓冲。
    private let outFormat: AVAudioFormat
    /// 素材读到头了（转换器已经收到 endOfStream，再要就是 0 帧；跳读会 reset 重来）。
    private var ended = false
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
              let fileBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: Self.chunk * 4)
        else { return nil }
        self.fileBuffer = fileBuffer
        self.outFormat = outFormat
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
        // 是不是上一次的延续：按引擎格式的帧号比，差一帧以内算接上（位置是浮点算出来的）。
        let target = Int64((sourceSeconds * Self.engineRate).rounded())
        let continuing = nextOutputFrame >= 0 && abs(target - nextOutputFrame) <= 1
        if !continuing {
            let sourceFrame = AVAudioFramePosition((sourceSeconds * fileRate).rounded(.down))
            guard sourceFrame < file.length, sourceFrame >= 0 else { return 0 }
            file.framePosition = sourceFrame
            converter?.reset()
            ended = false
            nextOutputFrame = target
        }
        guard let converter, let virtualBuffer else {
            // 直读：格式已经是引擎的。
            fileBuffer.frameLength = 0
            guard (try? file.read(into: fileBuffer, frameCount: AVAudioFrameCount(wanted))) != nil else { return 0 }
            let got = Int(fileBuffer.frameLength)
            copy(fileBuffer, frames: got, into: left, right)
            nextOutputFrame += Int64(got)
            return got
        }
        // 重采样：输出缓冲正好 `wanted` 帧，转换器要多少输入就从文件里现读多少（拉式）——
        // 它永远不会「输入先断了」。推式（一次塞一块、不够就说 noDataNow）的话，每次调用的最后几十帧是
        // 在没有后面的采样时算出来的、是错的：2026-10-01 之前这几十帧被扔掉但转换器每块被 reset（块头一个
        // 毛刺），改成留着下次先给之后毛刺照样在块头（探针：块头误差 −22 dB、块中间逐位相同）。拉式之后逐位相同。
        guard !ended, let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(wanted)) else { return 0 }
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { [self] requested, outStatus in
            if ended {
                outStatus.pointee = .endOfStream
                return nil
            }
            fileBuffer.frameLength = 0
            let toRead = min(AVAudioFrameCount(requested), fileBuffer.frameCapacity)
            guard toRead > 0, (try? file.read(into: fileBuffer, frameCount: toRead)) != nil, fileBuffer.frameLength > 0 else {
                ended = true
                outStatus.pointee = .endOfStream
                return nil
            }
            // 数据原样、只换格式标签。
            virtualBuffer.frameLength = fileBuffer.frameLength
            for channel in 0..<Int(fileBuffer.format.channelCount) {
                virtualBuffer.floatChannelData![channel].update(from: fileBuffer.floatChannelData![channel], count: Int(fileBuffer.frameLength))
            }
            outStatus.pointee = .haveData
            return virtualBuffer
        }
        guard status != .error else { return 0 }
        let got = min(wanted, Int(output.frameLength))
        copy(output, frames: got, into: left, right)
        nextOutputFrame += Int64(got)
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
