import Foundation
import SrtFlowKokoro

// MARK: - 用本机的 Kokoro 读一句旁白
//
// 管什么：模型只在 `MediaReadQueue.voice` 这一条队列上加载、推理（CoreML 的推理卡线程，不进协作线程池；模型不同时跑两次）；
// 一句旁白先按句切（KokoroVoicePieces），token 超了或者声音超 5 秒就再切，一段段读完按字的时刻裁好拼起来
// （KokoroVoiceAssembly），过一道音量存成 .m4a（AIAudioFileWriter），词的时间走和 macOS 配音同一条路（AIVoiceWords）。
// 闲置两分钟卸掉模型（它常驻 300 多 MB）。
// 不管什么：模型下没下、在哪（KokoroVoicePack）、挑哪个音色（AIVoiceChoice）。

@MainActor
final class KokoroVoiceSpeech {
    static let shared = KokoroVoiceSpeech()

    /// 闲置多久卸掉模型。
    static let idleUnload: Duration = .seconds(120)

    private let box = KokoroEngineBox()
    private var unloadTask: Task<Void, Never>?

    private init() {}

    /// 装好的模型里有哪些音色（看 voices 文件夹，不用加载模型）。
    nonisolated static func voiceNames(in directory: URL) -> [String] {
        let folder = directory.appendingPathComponent("voices", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    func speak(_ text: String, language: String, voice: String, speed: Double, to url: URL) async throws -> AISpeechSynthesis.Output {
        guard KokoroVoicePack.shared.isInstalled else {
            throw AIToolError("SrtFlow's voices are not downloaded yet. Call add_voiceover with download_voices=true first.")
        }
        unloadTask?.cancel()
        let directory = KokoroVoicePack.directory
        let box = self.box
        let rendered = await MediaReadQueue.run(on: MediaReadQueue.voice) {
            Result { try box.withEngine(loadingFrom: directory) { engine in
                try Self.render(text, language: language, voice: voice, speed: speed, engine: engine)
            } }
        }
        scheduleUnload()
        let (raw, markers) = try rendered.get()
        let rate = Double(KokoroEngine.sampleRate)
        let samples = try AIAudioFileWriter.writeVoiceover(raw, sampleRate: rate, to: url)
        let words = AIVoiceWords.words(text: text, markers: markers, samples: samples, sampleRate: rate)
        return AISpeechSynthesis.Output(url: url, duration: Double(samples.count) / rate, words: words)
    }

    /// 删模型之前先把它从内存里放掉。
    func unload() {
        unloadTask?.cancel()
        let box = self.box
        MediaReadQueue.voice.addOperation { box.unload() }
    }

    private func scheduleUnload() {
        unloadTask?.cancel()
        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: Self.idleUnload)
            guard !Task.isCancelled else { return }
            self?.unload()
        }
    }

    /// 在模型那条队列上：切段、读、读不下再切、拼起来。
    nonisolated private static func render(_ text: String, language: String, voice: String, speed: Double,
                                           engine: KokoroEngine) throws -> ([Float], [AIVoiceWords.Marker]) {
        let utf16 = Array(text.utf16)
        var pending = KokoroVoicePieces.sentences(text)
        var spoken: [KokoroVoiceAssembly.SpokenPiece] = []
        var rounds = 0
        while !pending.isEmpty {
            rounds += 1
            guard rounds < 1_000 else { throw AIToolError("This line could not be split into parts SrtFlow's voice can read.") }
            let piece = pending.removeFirst()
            let pieceText = String(decoding: utf16[piece.range], as: UTF16.self)
            var tokens = KokoroUnits.tokens(for: pieceText, language: language, phonemizer: engine.phonemizer)
            guard !tokens.units.isEmpty else { continue }
            if tokens.ids.count > KokoroEngine.maxTokens {
                if let parts = KokoroVoicePieces.split(piece, in: text) {
                    pending.insert(contentsOf: parts, at: 0)
                    continue
                }
                // 一个词就超了（极少见）：截断，截掉的那几个字不出字幕。
                tokens.ids = Array(tokens.ids.prefix(KokoroEngine.maxTokens - 1)) + [engine.phonemizer.eosId]
                tokens.units = tokens.units.filter { $0.tokenRange.upperBound < tokens.ids.count }
            }
            let output = try engine.synthesize(tokens: tokens.ids, voice: voice, speed: Float(speed))
            if output.truncated, let parts = KokoroVoicePieces.split(piece, in: text) {
                pending.insert(contentsOf: parts, at: 0)
                continue
            }
            spoken.append(.init(range: piece.range, samples: output.samples, frames: output.frames,
                                units: tokens.units, pauseAfter: piece.pauseAfter))
        }
        let assembled = KokoroVoiceAssembly.assemble(spoken, sampleRate: KokoroEngine.sampleRate,
                                                     samplesPerFrame: KokoroEngine.samplesPerFrame)
        guard !assembled.samples.isEmpty else { throw AIToolError("There is nothing to say in this line.") }
        return assembled
    }
}

/// 模型只在 `MediaReadQueue.voice` 上碰（那条队列一次只跑一件事），所以不加锁。
private final class KokoroEngineBox: @unchecked Sendable {
    private var engine: KokoroEngine?

    func withEngine<T>(loadingFrom directory: URL, _ body: (KokoroEngine) throws -> T) throws -> T {
        if engine == nil { engine = try KokoroEngine.load(from: directory) }
        guard let engine else { throw AIToolError("SrtFlow's voice model could not be loaded.") }
        return try body(engine)
    }

    func unload() { engine = nil }
}
