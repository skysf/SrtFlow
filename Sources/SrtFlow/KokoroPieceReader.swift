import Foundation
import SrtFlowKokoro

// MARK: - 让 Kokoro 读一段（在模型那条队列上）
//
// 管什么：一段字 → 读好的一段声音（KokoroVoiceAssembly.SpokenPiece）。按 KokoroVoicePadding 的几种垫法依次试：
// 垫一句（太短的一段单独读会炸）→ 读 → 只留这一段自己的 token（单位、切口不越过垫的那句开口处）→ 炸了换下一种；
// 都炸就用峰值最小的那次。这一段自己就超过 128 个 token、或者读出来超过 5 秒（截断）时交回调用方再切（`tooLong`）。
// 非数字的采样当静音。
// 不管什么：怎么切段（KokoroVoicePieces）、怎么拼（KokoroVoiceAssembly）、模型加载和队列（KokoroVoiceSpeech）。

enum KokoroPieceReader {
    enum Outcome {
        case spoken(KokoroVoiceAssembly.SpokenPiece)
        /// 读不下：这一段要再切。
        case tooLong
        /// 没有能读的字。
        case empty
    }

    /// 只在 `MediaReadQueue.voice` 上调（模型不同时跑两次）。`force`：切不开了，截断着也要读出来（极少见：一个词就超了）。
    static func read(
        _ piece: KokoroVoicePieces.Piece, of text: String, language: String, voice: String, speed: Float,
        engine: KokoroEngine, force: Bool = false
    ) throws -> Outcome {
        let utf16 = Array(text.utf16)
        let own = String(decoding: utf16[piece.range], as: UTF16.self)
        let ownLength = own.utf16.count
        let ownTokens = KokoroUnits.tokens(for: own, language: language, phonemizer: engine.phonemizer)
        guard !ownTokens.units.isEmpty else { return .empty }
        if ownTokens.ids.count > KokoroEngine.maxTokens, !force { return .tooLong }
        var best: (piece: KokoroVoiceAssembly.SpokenPiece, peak: Float)?
        for tail in KokoroVoicePadding.attempts(ownTokens: ownTokens.ids.count, language: language) {
            var tokens = KokoroUnits.tokens(for: own + (tail ?? ""), language: language, phonemizer: engine.phonemizer)
            if tokens.ids.count > KokoroEngine.maxTokens {
                guard tail == nil else { continue }          // 垫上就超了：换下一种（下一种短一点，或者不垫）
                tokens.ids = Array(tokens.ids.prefix(KokoroEngine.maxTokens - 1)) + [engine.phonemizer.eosId]
            }
            let ownUnits = tokens.units.filter { $0.textRange.upperBound <= ownLength && $0.tokenRange.upperBound < tokens.ids.count }
            guard let last = ownUnits.last else { continue }
            let output = try engine.synthesize(tokens: tokens.ids, voice: voice, speed: speed)
            var cumulative = [0]
            for frames in output.frames { cumulative.append(cumulative[cumulative.count - 1] + frames) }
            func sample(atToken index: Int) -> Int { cumulative[min(index, cumulative.count - 1)] * KokoroEngine.samplesPerFrame }
            let ownEnd = sample(atToken: last.tokenRange.upperBound)
            if ownEnd > output.samples.count, !force { return .tooLong }
            // 炸没炸看原样的输出（非数字也算炸），留下来的那份把非数字当静音。
            let region = output.samples[
                min(output.samples.count, sample(atToken: ownUnits[0].tokenRange.lowerBound))..<min(output.samples.count, ownEnd)
            ]
            let samples = output.samples.map { $0.isFinite ? $0 : 0 }
            // 垫的那句从哪儿开口：切口不许越过它。
            let padStart = tokens.units.first { $0.textRange.lowerBound >= ownLength }.map { sample(atToken: $0.tokenRange.lowerBound) }
            let spoken = KokoroVoiceAssembly.SpokenPiece(
                range: piece.range, samples: samples, frames: output.frames, units: ownUnits,
                pauseAfter: piece.pauseAfter, speechLimit: padStart
            )
            let peak = KokoroVoicePadding.peak(region)
            if !KokoroVoicePadding.exploded(region) { return .spoken(spoken) }
            if best == nil || peak < best!.peak { best = (spoken, peak) }
        }
        return best.map { .spoken($0.piece) } ?? .empty
    }
}
