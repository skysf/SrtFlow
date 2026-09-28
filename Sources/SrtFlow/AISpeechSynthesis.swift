import AVFoundation
import Foundation
import SrtFlowCore

// MARK: - 用这台 Mac 的声音读一句（macOS 配音，方案第 43 条）
//
// 管什么：`AVSpeechSynthesizer.write` 把一句话读成 PCM（不出声），存成 .m4a（AIAudioFileWriter，和本机模型配音同一份）；读的时候每个词报一个标记，
// 换成带时间的词（AIVoiceWords），字幕按它对上，不用再转写。以及列出这台 Mac 装了哪些声音。
// 不管什么：挑哪个声音（AIVoiceChoice）、文件放哪 / 放上时间线（AIVoiceoverTool）。
//
// 2026-09-28 探针定下的口径（docs/architecture/ai-control-mcp.md 第四节第 34 条）：
// - 词的标记**只从代理方法** `speechSynthesizer(_:willSpeak:utterance:)` 来；`write(_:toBufferCallback:toMarkerCallback:)`
//   的那个回调在 macOS 26 上一次都没叫过。
// - 标记的 `byteSampleOffset` 是字节：除以每帧字节数（单声道 Float32 = 4）就是第几帧，和声音对得上。
// - 缓冲、标记、didFinish 都在主线程上来；标记全在最后那个空缓冲之前；空缓冲会来两次，didFinish 在它后面 —— 按 didFinish 收。

@MainActor
final class AISpeechSynthesis: NSObject, AVSpeechSynthesizerDelegate {
    struct Output {
        var url: URL
        var duration: Double
        /// 文件里的秒。
        var words: [TimedWord]
    }

    /// 这台 Mac 装的声音（抄成 AIVoiceChoice 认的样子）。
    static func installedVoices() -> [AIVoiceChoice.Voice] {
        AVSpeechSynthesisVoice.speechVoices().map { voice in
            let quality: Int
            switch voice.quality {
            case .premium: quality = 3
            case .enhanced: quality = 2
            default: quality = 1
            }
            let gender: AIVoiceChoice.Voice.Gender
            switch voice.gender {
            case .female: gender = .female
            case .male: gender = .male
            default: gender = .unspecified
            }
            return AIVoiceChoice.Voice(
                identifier: voice.identifier, name: voice.name, language: voice.language, gender: gender, quality: quality,
                isNovelty: voice.voiceTraits.contains(.isNoveltyVoice), isPersonal: voice.voiceTraits.contains(.isPersonalVoice)
            )
        }
    }

    /// 读一句、写到 `url`（.m4a）。`speed` 1 = 正常语速。
    static func speak(_ text: String, choice: AIVoiceChoice, speed: Double, to url: URL) async throws -> Output {
        let synthesis = AISpeechSynthesis()
        return try await synthesis.run(text, choice: choice, speed: speed, to: url)
    }

    // MARK: 一次合成

    private let synthesizer = AVSpeechSynthesizer()
    private var buffers: [AVAudioPCMBuffer] = []
    private var markers: [AIVoiceWords.Marker] = []
    private var bytesPerFrame = 4
    private var continuation: CheckedContinuation<Void, Error>?

    private func run(_ text: String, choice: AIVoiceChoice, speed: Double, to url: URL) async throws -> Output {
        guard case .system(let chosen) = choice.engine, let voice = AVSpeechSynthesisVoice(identifier: chosen.identifier) else {
            throw AIToolError("The voice \(choice.name) is no longer installed on this Mac.")
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        // rate 和实际语速不是线性的，按实测的表换（AIVoiceChoice.utteranceRate）。
        utterance.rate = Float(AIVoiceChoice.utteranceRate(forSpeed: speed))
        utterance.pitchMultiplier = Float(min(max(choice.pitch, 0.5), 2))
        synthesizer.delegate = self
        // 看门狗：声音出了问题、一直不来 didFinish 的话，调用不能一直挂着（大约十倍于读完要的时间）。
        let limit = 20 + Double(text.count) * 0.6
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            synthesizer.write(utterance) { [weak self] buffer in
                // 缓冲在回调返回之后可能被复用：先抄一份再交给主 actor（在主线程上来时就地处理，顺序不乱）。
                guard let copy = Self.copy(buffer) else { return }
                Self.onMain { self?.receive(copy) }
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(limit))
                self?.finish(AIToolError("Speaking the line took too long; the voice may be broken. Try another voice."))
            }
        }
        guard let format = buffers.first?.format, format.sampleRate > 0 else {
            throw AIToolError("The voice \(choice.name) produced no sound for this line.")
        }
        let samples = monoSamples()
        try AIAudioFileWriter.writeM4A(samples: samples, sampleRate: format.sampleRate, to: url)
        let words = AIVoiceWords.words(text: text, markers: markers, samples: samples, sampleRate: format.sampleRate)
        return Output(url: url, duration: Double(samples.count) / format.sampleRate, words: words)
    }

    private func receive(_ pcm: AVAudioPCMBuffer) {
        bytesPerFrame = max(1, Int(pcm.format.streamDescription.pointee.mBytesPerFrame))
        buffers.append(pcm)
    }

    /// 非空的 PCM 缓冲抄一份；空的（「读完了」那个）和别的类型不要。
    nonisolated private static func copy(_ buffer: AVAudioBuffer) -> AVAudioPCMBuffer? {
        guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: pcm.format, frameCapacity: pcm.frameLength) else { return nil }
        copy.frameLength = pcm.frameLength
        let source = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, target) {
            guard let fromData = from.mData, let toData = to.mData else { continue }
            memcpy(toData, fromData, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }

    /// 回调在主线程上来就地处理（探针：都是），别的线程上来就排到主线程（先进先出，顺序不乱）。
    nonisolated private static func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated(body) }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeak marker: AVSpeechSynthesisMarker,
                                       utterance: AVSpeechUtterance) {
        guard marker.mark == .word else { return }
        let range = marker.textRange
        let offset = marker.byteSampleOffset
        Self.onMain { [weak self] in
            guard let self else { return }
            markers.append(.init(location: range.location, length: range.length, frame: offset / bytesPerFrame))
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Self.onMain { [weak self] in self?.finish(nil) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Self.onMain { [weak self] in self?.finish(AIToolError("Speaking the line was cancelled.")) }
    }

    private func finish(_ error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    /// 第一个声道的全部采样（量静音用）。
    private func monoSamples() -> [Float] {
        var samples: [Float] = []
        samples.reserveCapacity(buffers.reduce(0) { $0 + Int($1.frameLength) })
        for buffer in buffers {
            if let channel = buffer.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            } else if let channel = buffer.int16ChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)).map { Float($0) / 32768 })
            }
        }
        return samples
    }
}
