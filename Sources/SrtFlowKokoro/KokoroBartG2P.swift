// SrtFlowKokoro —— 从 speech-swift（https://github.com/soniqo/speech-swift，Apache License 2.0，Copyright 2025 Ivan Digital）
// 的 KokoroTTS 模块搬过来的代码，为 SrtFlow 改过。授权全文与署名见 Sources/SrtFlow/Resources/THIRD-PARTY-NOTICES.md（随 App 分发）。
// 这个文件：英语词典里查不到的词，用一个小的 BART 模型（CoreML）按拼写猜读音。改动：从 KokoroPhonemizer 里拆出来成了
// 自己的类型（原文件 704 行，超过仓库 600 行的上限，docs/architecture/coding-standards.md）；函数体原样。

import CoreML
import Foundation

final class KokoroBartG2P {
    /// CoreML G2P encoder model.
    private var g2pEncoder: MLModel?

    /// CoreML G2P decoder model.
    private var g2pDecoder: MLModel?

    /// G2P vocabulary mappings.
    private var graphemeToId: [String: Int] = [:]
    private var idToPhoneme: [Int: String] = [:]
    private var g2pBosId: Int = 1
    private var g2pEosId: Int = 2
    private var g2pPadId: Int = 0

    /// Load separate G2P encoder + decoder CoreML models.
    func load(encoderURL: URL, decoderURL: URL, vocabURL: URL) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly
        g2pEncoder = try MLModel(contentsOf: encoderURL, configuration: config)
        g2pDecoder = try MLModel(contentsOf: decoderURL, configuration: config)

        // Load G2P vocabulary
        if FileManager.default.fileExists(atPath: vocabURL.path) {
            let data = try Data(contentsOf: vocabURL)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let g2id = json["grapheme_to_id"] as? [String: Int] {
                    graphemeToId = g2id
                }
                if let id2p = json["id_to_phoneme"] as? [String: String] {
                    idToPhoneme = Dictionary(uniqueKeysWithValues: id2p.compactMap { k, v in
                        Int(k).map { ($0, v) }
                    })
                }
                g2pBosId = (json["bos_token_id"] as? Int) ?? 1
                g2pEosId = (json["eos_token_id"] as? Int) ?? 2
                g2pPadId = (json["pad_token_id"] as? Int) ?? 0
            }
        }
    }

    // MARK: - BART G2P Neural Fallback

    /// Use the CoreML BART encoder-decoder to phonemize an OOV word.
    func phonemize(_ word: String) -> String? {
        guard let encoder = g2pEncoder, let decoder = g2pDecoder else { return nil }
        guard !graphemeToId.isEmpty else { return nil }

        // Encode graphemes
        var inputIds: [Int32] = [Int32(g2pBosId)]
        for char in word {
            let s = String(char)
            if let id = graphemeToId[s] {
                inputIds.append(Int32(id))
            } else if let id = graphemeToId[s.lowercased()] {
                inputIds.append(Int32(id))
            } else {
                inputIds.append(Int32(graphemeToId["<unk>"] ?? 3))
            }
        }
        inputIds.append(Int32(g2pEosId))

        let seqLen = inputIds.count
        guard seqLen <= 64 else { return nil }

        do {
            // Run encoder
            let encInput = try MLMultiArray(shape: [1, seqLen as NSNumber], dataType: .int32)
            let encPtr = encInput.dataPointer.assumingMemoryBound(to: Int32.self)
            for i in 0..<seqLen { encPtr[i] = inputIds[i] }

            let encFeatures = try MLDictionaryFeatureProvider(dictionary: [
                "input_ids": MLFeatureValue(multiArray: encInput),
            ])
            let encOutput = try encoder.prediction(from: encFeatures)
            guard let hiddenStates = encOutput.featureValue(for: "encoder_hidden_states")?.multiArrayValue else {
                return nil
            }

            // Autoregressive decoding
            var decoderIds: [Int32] = [Int32(g2pBosId)]
            let maxDecLen = 64

            for step in 0..<maxDecLen {
                let decLen = decoderIds.count

                let decInput = try MLMultiArray(shape: [1, decLen as NSNumber], dataType: .int32)
                let decPtr = decInput.dataPointer.assumingMemoryBound(to: Int32.self)
                for i in 0..<decLen { decPtr[i] = decoderIds[i] }

                let posIds = try MLMultiArray(shape: [1, decLen as NSNumber], dataType: .int32)
                let posPtr = posIds.dataPointer.assumingMemoryBound(to: Int32.self)
                for i in 0..<decLen { posPtr[i] = Int32(i) }

                let mask = try MLMultiArray(shape: [1, decLen as NSNumber, decLen as NSNumber], dataType: .float32)
                let maskPtr = mask.dataPointer.assumingMemoryBound(to: Float.self)
                for i in 0..<decLen {
                    for j in 0..<decLen {
                        maskPtr[i * decLen + j] = (j <= i) ? 0.0 : -Float.greatestFiniteMagnitude
                    }
                }

                let decFeatures = try MLDictionaryFeatureProvider(dictionary: [
                    "decoder_input_ids": MLFeatureValue(multiArray: decInput),
                    "encoder_hidden_states": MLFeatureValue(multiArray: hiddenStates),
                    "position_ids": MLFeatureValue(multiArray: posIds),
                    "causal_mask": MLFeatureValue(multiArray: mask),
                ])

                let decOutput = try decoder.prediction(from: decFeatures)
                guard let logits = decOutput.featureValue(for: "logits")?.multiArrayValue else {
                    break
                }

                // Greedy: take argmax of last position
                let vocabSize = logits.shape.last!.intValue
                let lastOffset = step * vocabSize
                var maxId = 0
                var maxVal: Float = -.infinity
                if logits.dataType == .float16 {
                    let lPtr = logits.dataPointer.assumingMemoryBound(to: Float16.self)
                    for v in 0..<vocabSize {
                        let val = Float(lPtr[lastOffset + v])
                        if val > maxVal { maxVal = val; maxId = v }
                    }
                } else {
                    let lPtr = logits.dataPointer.assumingMemoryBound(to: Float.self)
                    for v in 0..<vocabSize {
                        let val = lPtr[lastOffset + v]
                        if val > maxVal { maxVal = val; maxId = v }
                    }
                }

                if maxId == g2pEosId { break }
                decoderIds.append(Int32(maxId))
            }

            // Convert IDs to phonemes
            var result = ""
            for id in decoderIds.dropFirst() { // skip BOS
                let intId = Int(id)
                if intId != g2pPadId && intId != g2pBosId && intId != g2pEosId,
                   let phoneme = idToPhoneme[intId] {
                    result += phoneme
                }
            }
            return result.isEmpty ? nil : result
        } catch {
            return nil
        }
    }
}
