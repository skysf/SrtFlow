import AVFoundation
import Foundation

// MARK: - AI 做出来的声音写成 .m4a：配音（单声道）和合成音效（立体声）
//
// 管什么：配音做出来的声音（单声道 Float32）先过一道音量（AIVoiceLevel：说话部分拉到同一个响度、峰值封顶 −1 dBFS），
// 再存成 AAC 的 .m4a，采样率照原样（macOS 的声音约 22.05 kHz，Kokoro 24 kHz）；返回真正写进去的那一份采样 ——
// 词的时间（AIVoiceWords 量静音）按它算，和听到的一致。合成音效（SoundEffectSynth，48 kHz 立体声，音量在合成器里已经封过顶）
// 也从这里写，AAC 160 kbps。
// macOS 配音（AISpeechSynthesis）、本机模型配音（KokoroVoiceSpeech）和音效（AISoundEffectTool）共用这一份：音量和文件格式都只有
// 一处说了算，以后再加一种声音也绕不过去（2026-09-28 Kokoro 的 am_fenrir 峰值超过满幅、没过这一道就写进文件，一声声爆音，
// docs/bugfixes/2026-09-28-kokoro-voiceover-clipping.md）。
// 不管什么：文件放哪、叫什么（AIVoiceoverTool / AISoundEffectTool）。

enum AIAudioFileWriter {
    static func writeVoiceover(_ raw: [Float], sampleRate: Double, to url: URL) throws -> [Float] {
        guard !raw.isEmpty, sampleRate > 0 else { throw AIToolError("The voiceover came out empty.") }
        let samples = AIVoiceLevel.normalized(raw, sampleRate: sampleRate)
        try write([samples], sampleRate: sampleRate, bitRate: 64_000, to: url, what: "voiceover")
        return samples
    }

    /// 合成音效：两条声道，音量不再动（合成器已经峰值 −1 dBFS、响度封顶）。
    static func writeSoundEffect(_ channels: [[Float]], sampleRate: Double, to url: URL) throws {
        guard channels.count == 2, !channels[0].isEmpty, channels[0].count == channels[1].count, sampleRate > 0 else {
            throw AIToolError("The sound effect came out empty.")
        }
        try write(channels, sampleRate: sampleRate, bitRate: 160_000, to: url, what: "sound effect")
    }

    /// AAC 的 .m4a，一秒一块写；写坏了把半个文件删掉。
    private static func write(_ channels: [[Float]], sampleRate: Double, bitRate: Int, to url: URL, what: String) throws {
        let count = AVAudioChannelCount(channels.count)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: count, interleaved: false) else {
            throw AIToolError("The \(what) came out empty.")
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(count),
            AVEncoderBitRateKey: bitRate
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let chunk = Int(sampleRate)
            let total = channels[0].count
            var start = 0
            while start < total {
                let frames = min(chunk, total - start)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                      let data = buffer.floatChannelData else { break }
                buffer.frameLength = AVAudioFrameCount(frames)
                for (index, channel) in channels.enumerated() {
                    channel.withUnsafeBufferPointer { source in
                        data[index].update(from: source.baseAddress! + start, count: frames)
                    }
                }
                try file.write(from: buffer)
                start += frames
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw AIToolError("SrtFlow could not write the \(what) file \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
