// SrtFlowKokoro —— 从 speech-swift（https://github.com/soniqo/speech-swift，Apache License 2.0，Copyright 2025 Ivan Digital）
// 的 KokoroTTS 模块搬过来的代码，为 SrtFlow 改过。授权全文与署名见 Sources/SrtFlow/Resources/THIRD-PARTY-NOTICES.md（随 App 分发）。
// 这个文件：从一个本地目录加载 Kokoro（词表、词典、BART、音色、主模型），跑一次模型拿到声音和**每个 token 的时长**。
// 改动（原 KokoroTTS.swift）：不从 Hugging Face 下载（模型由 App 从我们自己的 R2 下好放进目录）；`synthesize` 收的是
// 已经切好的 token（KokoroUnits 按字 / 词切，才知道每个字占哪几个 token），回的是原始声音 + 时长，不在这里裁尾巴
// —— 裁在哪由 App 那一层按最后一个字的结束时刻定（原来按能量猜，裁不干净逗号后面冒出来的那一截杂音）。

import CoreML
import Foundation

public final class KokoroEngine {
    /// 输出采样率。
    public static let sampleRate = 24_000
    /// 模型给的时长一格 = 600 个采样（25 毫秒）。2026-09-28 实测：各 token 的时长加起来 × 600 正好是声音的长度。
    public static let samplesPerFrame = 600
    /// 一次最多多少个 token（含开头结尾两个）。
    public static let maxTokens = 128

    public let phonemizer: KokoroPhonemizer
    private let network: KokoroNetwork
    private let config = KokoroConfig.default
    private let voiceEmbeddings: [String: [Float]]

    /// 模型里有的音色名（af_heart、zf_xiaoyi……）。
    public var voices: [String] { voiceEmbeddings.keys.sorted() }

    private init(phonemizer: KokoroPhonemizer, network: KokoroNetwork, voiceEmbeddings: [String: [Float]]) {
        self.phonemizer = phonemizer
        self.network = network
        self.voiceEmbeddings = voiceEmbeddings
    }

    /// 从模型目录加载。几秒钟；第一次推理还要等神经网络引擎编译（M1 上约 10 秒），调用方在后台线程上做。
    public static func load(from directory: URL, computeUnits: MLComputeUnits = .all) throws -> KokoroEngine {
        let vocabURL = directory.appendingPathComponent("vocab_index.json")
        guard FileManager.default.fileExists(atPath: vocabURL.path) else {
            throw KokoroError.modelMissing("vocab_index.json not found")
        }
        let phonemizer = try KokoroPhonemizer.loadVocab(from: vocabURL)
        try phonemizer.loadDictionaries(from: directory)
        let encoder = directory.appendingPathComponent("G2PEncoder.mlmodelc", isDirectory: true)
        let decoder = directory.appendingPathComponent("G2PDecoder.mlmodelc", isDirectory: true)
        if FileManager.default.fileExists(atPath: encoder.path), FileManager.default.fileExists(atPath: decoder.path) {
            try phonemizer.loadG2PModels(encoderURL: encoder, decoderURL: decoder,
                                         vocabURL: directory.appendingPathComponent("g2p_vocab.json"))
        }
        var embeddings: [String: [Float]] = [:]
        let voicesDirectory = directory.appendingPathComponent("voices", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: voicesDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            if let embedding = try? loadVoiceEmbedding(from: file, styleDim: KokoroConfig.default.styleDim), !embedding.isEmpty {
                embeddings[file.deletingPathExtension().lastPathComponent] = embedding
            }
        }
        guard !embeddings.isEmpty else { throw KokoroError.modelMissing("no voices found") }
        let network = try KokoroNetwork(directory: directory, computeUnits: computeUnits)
        return KokoroEngine(phonemizer: phonemizer, network: network, voiceEmbeddings: embeddings)
    }

    /// 一次推理的结果。
    public struct Output {
        /// 声音（24 kHz 单声道），没裁过。
        public var samples: [Float]
        /// 每个 token 的时长（格，一格 600 个采样），和传进来的 token 一一对应（第 0 个是开头的那个 token）。
        public var frames: [Int]
        /// 声音被 5 秒的窗截断了（时长加起来比输出的采样多）：这一段要切短了再读。
        public var truncated: Bool
    }

    /// 读一串 token（开头结尾那两个也在里面，KokoroUnits 给的就是这样）。`speed` 1 = 正常。
    public func synthesize(tokens: [Int], voice: String, speed: Float) throws -> Output {
        guard let style = voiceEmbeddings[voice] else { throw KokoroError.unknownVoice(voice) }
        guard tokens.count <= Self.maxTokens else { throw KokoroError.inference("more than \(Self.maxTokens) tokens") }
        let padded = phonemizer.pad(tokens, to: Self.maxTokens)
        let inputIds = try makeArray(shape: [1, Self.maxTokens], int32: padded.map { Int32($0) })
        let mask = try makeArray(shape: [1, Self.maxTokens], int32: (0..<Self.maxTokens).map { Int32($0 < tokens.count ? 1 : 0) })
        let refS = try makeArray(shape: [1, config.styleDim], float: style)
        let speedArray = try makeArray(shape: [1], float: [speed])
        let result = try network.predictE2E(inputIds: inputIds, attentionMask: mask, refS: refS, speed: speedArray)
        let valid = min(result.audioLengthSamples, result.audio.count)
        var samples = [Float](repeating: 0, count: max(valid, 0))
        if valid > 0 {
            if result.audio.dataType == .float16 {
                let pointer = result.audio.dataPointer.bindMemory(to: Float16.self, capacity: valid)
                for index in 0..<valid { samples[index] = Float(pointer[index]) }
            } else {
                let pointer = result.audio.dataPointer.bindMemory(to: Float.self, capacity: valid)
                for index in 0..<valid { samples[index] = pointer[index] }
            }
        }
        let frames = (0..<tokens.count).map { index in
            index < result.predDur.count ? max(0, Int(result.predDur[index].floatValue.rounded())) : 0
        }
        let needed = frames.reduce(0, +) * Self.samplesPerFrame
        return Output(samples: samples, frames: frames, truncated: needed > result.audio.count)
    }

    // MARK: - 小工具

    private func makeArray(shape: [Int], int32 values: [Int32]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map { $0 as NSNumber }, dataType: .int32)
        let pointer = array.dataPointer.assumingMemoryBound(to: Int32.self)
        for index in values.indices { pointer[index] = values[index] }
        return array
    }

    private func makeArray(shape: [Int], float values: [Float]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map { $0 as NSNumber }, dataType: .float32)
        let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
        for index in values.indices { pointer[index] = values[index] }
        return array
    }

    /// 音色文件：`{"embedding": [...]}`，取前 styleDim 个。
    private static func loadVoiceEmbedding(from url: URL, styleDim: Int) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let embedding = json["embedding"] as? [Double] else { return [] }
        return embedding.prefix(styleDim).map { Float($0) }
    }
}
