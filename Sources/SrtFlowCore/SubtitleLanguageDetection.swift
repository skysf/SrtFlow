import Foundation

// 源语言自动检测的评分裁决（docs/bugfixes/2026-08-09-subtitle-translate-after-same-language.md
// 与复审 docs/bugfixes/2026-08-09-pr22-review-followups.md）。
//
// macOS 26 的 SpeechTranscriber 必须显式指定语言，系统没有音频语言识别 ——
// 所以「自动检测」是：探针窗口分别用候选语言的模型转写，这里做纯打分与裁决。
//
// **裁决是 fail-closed 的**：宁可返回 nil 让用户手选，也不许把一个错误语言
// 的模型判成成功 —— 那会整轨生成一份乱码字幕，比「检测不出来」糟得多。
// 全部纯函数，SrtFlowCoreChecks 有用例。

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

    /// 全候选都低于它 → 判定失败，让用户手选。
    ///
    /// **参数依据（2026-08-09 真机实测，合成英文语音 + macOS 26）：**
    /// - 正确模型（en 转英文音频）：词置信度 ≈0.91–1.00，加权分 ≈0.9+。
    /// - 错误模型（zh_CN 转英文音频）：产出烂词，词置信度 0.44–**0.74**。
    ///
    /// 所以判别区间是 (0.74, 0.91)。取 **0.80** —— 落在区间中段偏保守一侧，
    /// 离实测的错误模型上限留 0.06、离正确模型下限留 0.11 的余量。
    ///
    /// 初版取 0.45 是错的：那个值只兜「候选里根本没有正确语言」的极端场景，
    /// 而实测错误模型的分数（≈0.55）就在它之上 —— 只有一个错误候选时
    /// `pick` 会自信地返回它，整轨字幕按错误语言生成（PR#22 复审 P1）。
    /// **调低这个值前先回答：新值是否仍然高于实测的错误模型上限 0.74。**
    public static let minimumConfidence = 0.80

    /// 没带 confidence 的词按它计分。**必须严格小于 `minimumConfidence`** ——
    /// 「系统没给证据」不许被当成「证据表明是这个语言」。平台哪天整体不再
    /// 回报置信度时，全部候选一起跌到这个值 → 检测失败 → 引导手选，
    /// 这正是 fail-closed 想要的结局（SrtFlowCoreChecks 有一条断言钉住这个
    /// 不等式，防止以后有人把阈值调到 0.5 以下而悄悄恢复「无证据硬猜」）。
    public static let unknownConfidence = 0.5

    /// 词数低于它的候选先排除（噪声上偶发一两个高置信词不算数）；
    /// 全部低于时退回全体比较 —— 短素材不能因此永远检测不了。
    ///
    /// 注意这个回退**只放宽「谁有资格参赛」，绝不放宽置信度门槛**：短素材的
    /// 候选照样要 ≥ `minimumConfidence` 才能赢，够不着就还是 nil。
    public static let minimumWordCount = 3

    /// 词时长加权的平均置信度。无置信度的词按 `unknownConfidence` 计；
    /// 空词流 = 0。权重下限 0.05s：零时长词不许把自己除没了。
    public static func score(of words: [TimedWord]) -> Double {
        guard !words.isEmpty else { return 0 }
        var weightedSum = 0.0
        var totalWeight = 0.0
        for word in words {
            let weight = max(word.end - word.start, 0.05)
            weightedSum += (word.confidence ?? unknownConfidence) * weight
            totalWeight += weight
        }
        return totalWeight > 0 ? weightedSum / totalWeight : 0
    }

    // MARK: - 候选构造：同一语言只占一个名额

    /// 一个候选来源（还没去重、没截断）。
    public struct CandidateSource: Hashable, Sendable {
        public var localeIdentifier: String
        /// 只有素材元数据指名的语言允许触发模型下载。
        public var allowsDownload: Bool

        public init(localeIdentifier: String, allowsDownload: Bool) {
            self.localeIdentifier = localeIdentifier
            self.allowsDownload = allowsDownload
        }
    }

    /// 语言的比较键：maximal 化后的**语言码 + 文字系统**。
    ///
    /// en ≍ en-US ≍ en-SG ≍ en-Latn-US（地区差异不是区别）；
    /// zh-Hans ≠ zh-Hant（简繁是两种文字系统）；yue ≠ zh。
    ///
    /// 这条规则有两个消费者 —— 检测的候选去重和翻译的同语种预检
    /// （`TranslationPreflight.isSameTranslationLanguage` 委托到这里）。
    /// **两边必须是同一份实现**：分叉出第二套「算不算同一种语言」的判据，
    /// 迟早会出现「检测认为是两种、翻译认为是一种」的撕裂。
    ///
    /// - Returns: 连语言码都取不到时返回 nil（调用方按「无法比较」处理）。
    public static func languageKey(of language: Locale.Language) -> String? {
        let maximal = Locale.Language(identifier: language.maximalIdentifier)
        guard let code = maximal.languageCode?.identifier else { return nil }
        guard let script = maximal.script?.identifier else { return code }
        return "\(code)-\(script)"
    }

    /// 同上，入参是 locale 标识符（`en_US` 这种下划线形式也认）。
    public static func languageKey(ofLocaleIdentifier identifier: String) -> String? {
        languageKey(of: Locale(identifier: identifier).language)
    }

    /// 按优先级去重并截断到 `limit`。
    ///
    /// **去重按语言而不是按 locale 标识符**：`en_US` / `en_SG` / `en_IN` 是
    /// 同一种语言的三个地区变体，探针对它们的裁决结果在语言层面等价（变体间的
    /// 置信度差是噪声，2026-08-09 冒烟实测到过 en_US/en_SG 同时参赛）。按标识符
    /// 去重的话，它们会**吃光三个名额** —— 本机实测生产算法就取到过
    /// `["en_US", "zh_CN", "en_IN"]`：装了日语模型也永远探不到日语。
    ///
    /// 同一语言的多个变体只留优先级最高的那一个；`allowsDownload` 也跟着它
    /// （元数据指名的候选排在最前，所以下载许可不会被后面的变体稀释）。
    ///
    /// - Parameter sources: 已经按优先级排好序的来源（元数据 → 系统首选 →
    ///   其余已装）。**调用方要保证顺序是确定的** —— 截断意味着排在后面的
    ///   语言会被丢掉，顺序一抖动，结果就不可复现。
    public static func selectCandidates(
        _ sources: [CandidateSource], limit: Int = maximumCandidates
    ) -> [CandidateSource] {
        var seen = Set<String>()
        var result: [CandidateSource] = []
        for source in sources {
            guard result.count < limit else { break }
            // 键取不出来的（畸形标识符）退回用标识符本身，至少不会互相合并。
            let key = languageKey(ofLocaleIdentifier: source.localeIdentifier)
                ?? source.localeIdentifier
            guard seen.insert(key).inserted else { continue }
            result.append(source)
        }
        return result
    }

    /// 探针最多跑几个候选。每个候选都要真转写一遍 20s 音频，3 个是
    /// 「够分辨 + 仍在秒级」的产品参数。
    public static let maximumCandidates = 3

    /// 最高分且过门槛的候选；并列取先到者（调用方按优先级排列候选：
    /// 素材元数据 → 系统首选 → 其余已装）。
    ///
    /// **全不过门槛返回 nil，候选只有一个时也一样** —— 调用方必须把 nil
    /// 当成「检测失败，请用户手选」，不许退化成「就它了」。
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
