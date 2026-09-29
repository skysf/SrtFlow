import AVFoundation
import Foundation

// MARK: - 一句配音写成 .m4a
//
// 管什么：配音做出来的声音（单声道 Float32）先过一道音量（AIVoiceLevel：说话部分拉到同一个响度、峰值封顶 −1 dBFS），
// 再存成 AAC 的 .m4a，采样率照原样（macOS 的声音约 22.05 kHz，Kokoro 24 kHz）；返回真正写进去的那一份采样 ——
// 词的时间（AIVoiceWords 量静音）按它算，和听到的一致。
// macOS 配音（AISpeechSynthesis）和本机模型配音（KokoroVoiceSpeech）共用这一份：音量和文件格式都只有一处说了算，
// 以后再加一种声音也绕不过去（2026-09-28 Kokoro 的 am_fenrir 峰值超过满幅、没过这一道就写进文件，一声声爆音，
// docs/bugfixes/2026-09-28-kokoro-voiceover-clipping.md）。
// 不管什么：文件放哪、叫什么（AIVoiceoverTool）。

enum AIAudioFileWriter {
    static func writeVoiceover(_ raw: [Float], sampleRate: Double, to url: URL) throws -> [Float] {
        guard !raw.isEmpty, sampleRate > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            throw AIToolError("The voiceover came out empty.")
        }
        let samples = AIVoiceLevel.normalized(raw, sampleRate: sampleRate)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let chunk = Int(sampleRate)
            var start = 0
            while start < samples.count {
                let count = min(chunk, samples.count - start)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                      let channel = buffer.floatChannelData?[0] else { break }
                buffer.frameLength = AVAudioFrameCount(count)
                samples.withUnsafeBufferPointer { source in
                    channel.update(from: source.baseAddress! + start, count: count)
                }
                try file.write(from: buffer)
                start += count
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw AIToolError("SrtFlow could not write the voiceover file \(url.lastPathComponent): \(error.localizedDescription)")
        }
        return samples
    }
}
