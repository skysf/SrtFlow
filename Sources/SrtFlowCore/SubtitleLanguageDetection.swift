import Foundation

// 源语言自动检测的评分裁决（docs/bugfixes/2026-08-09-subtitle-translate-after-same-language.md）。
//
// macOS 26 的 SpeechTranscriber 必须显式指定语言，系统没有音频语言识别 ——
// 所以「自动检测」是：探针窗口分别用候选语言的模型转写，这里做纯打分与裁决。
// 2026-08-09 实测（合成英文语音）：正确模型词置信度 ≈0.91–1.00，错误模型
// （zh_CN 转英文音频）产出烂词且 ≈0.44–0.74。阈值只兜「候选里根本没有正确
// 语言」的场景，不参与候选之间的排序。全部纯函数，SrtFlowCoreChecks 有用例。

public enum SubtitleLanguageDetection {

    /// 一个候选语言的探针转写结果。
    public struct Candidate: Hashable, Sendable {
        public var localeIdentifier: String
        public var words: [TimedWord]

        public init(localeIdentifier: String, words: [TimedWord]) {
            self.localeIdentifier = localeIdentifier
            self.words = words
        }
    }

    public struct Verdict: Hashable, Sendable {
        public var localeIdentifier: String
        public var score: Double

        public init(localeIdentifier: String, score: Double) {
            self.localeIdentifier = localeIdentifier
            self.score = score
        }
    }

    /// 全候选都低于它 → 判定失败，让用户手选（产品参数，实测后调）。
    public static let minimumConfidence = 0.45
    /// 词数低于它的候选先排除（噪声上偶发一两个高置信词不算数）；
    /// 全部低于时退回全体比较 —— 短素材不能因此永远检测不了。
    public static let minimumWordCount = 3

    /// 词时长加权的平均置信度。无置信度的词按中性 0.5 计；空词流 = 0。
    /// 权重下限 0.05s：零时长词不许把自己除没了。
    public static func score(of words: [TimedWord]) -> Double {
        guard !words.isEmpty else { return 0 }
        var weightedSum = 0.0
        var totalWeight = 0.0
        for word in words {
            let weight = max(word.end - word.start, 0.05)
            weightedSum += (word.confidence ?? 0.5) * weight
            totalWeight += weight
        }
        return totalWeight > 0 ? weightedSum / totalWeight : 0
    }

    /// 最高分且过门槛的候选；并列取先到者（调用方按优先级排列候选：
    /// 素材元数据 → 系统首选 → 其余已装）。全不过门槛返回 nil。
    public static func pick(_ candidates: [Candidate]) -> Verdict? {
        let eligible = candidates.filter { $0.words.count >= minimumWordCount }
        let pool = eligible.isEmpty ? candidates : eligible
        var best: Verdict?
        for candidate in pool {
            let value = score(of: candidate.words)
            guard value >= minimumConfidence else { continue }
            if value > (best?.score ?? -1) {
                best = Verdict(localeIdentifier: candidate.localeIdentifier, score: value)
            }
        }
        return best
    }
}
