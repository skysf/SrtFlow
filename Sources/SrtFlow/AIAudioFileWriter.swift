import AVFoundation
import Foundation

// MARK: - 一串采样写成 .m4a
//
// 管什么：配音做出来的声音（单声道 Float32）存成 AAC 的 .m4a，采样率照原样（macOS 的声音约 22.05 kHz，Kokoro 24 kHz）。
// macOS 配音（AISpeechSynthesis）和本机模型配音（KokoroVoiceSpeech）共用这一份，文件格式只有一处说了算。
// 不管什么：文件放哪、叫什么（AIVoiceoverTool）。

enum AIAudioFileWriter {
    static func writeM4A(samples: [Float], sampleRate: Double, to url: URL) throws {
        guard !samples.isEmpty, sampleRate > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            throw AIToolError("The voiceover came out empty.")
        }
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
    }
}
