import Foundation
import SrtFlowCore

// 字幕源语言自动检测的评分裁决（SubtitleLanguageDetection）。
// 背景：docs/bugfixes/2026-08-09-subtitle-translate-after-same-language.md。
// 置信度数值取自 2026-08-09 真机实测：正确模型词置信度 ≈0.91–1.00，
// 错误模型（zh_CN 转英文音频）≈0.44–0.74。

func runLanguageDetectionChecks() {
    func words(_ entries: [(start: Double, end: Double, confidence: Double?)]) -> [TimedWord] {
        entries.enumerated().map { index, entry in
            TimedWord(text: "w\(index)", start: entry.start, end: entry.end, confidence: entry.confidence)
        }
    }

    // 打分：空词流 = 0（不许把「没词」当高置信）。
    checkEqual(SubtitleLanguageDetection.score(of: []), 0, "检测评分：空词流为 0")
    // 无置信度按中性 0.5 计。
    check(
        abs(SubtitleLanguageDetection.score(of: words([(0, 1, nil)])) - 0.5) < 1e-9,
        "检测评分：无置信度的词按 0.5 计"
    )
    // 词时长加权：2s@0.9 + 1s@0.3 → (0.9*2 + 0.3*1)/3 = 0.7，不是平均 0.6。
    check(
        abs(SubtitleLanguageDetection.score(of: words([(0, 2, 0.9), (2, 3, 0.3)])) - 0.7) < 1e-9,
        "检测评分：按词时长加权"
    )
    // 零时长词吃权重下限，不产生除零/NaN。
    let degenerate = SubtitleLanguageDetection.score(of: words([(1, 1, 0.8)]))
    check(abs(degenerate - 0.8) < 1e-9, "检测评分：零时长词按权重下限计")

    // 裁决：正确模型（高置信）胜出，与候选顺序无关。
    let english = SubtitleLanguageDetection.Candidate(
        localeIdentifier: "en_US",
        words: words([(0, 1, 0.95), (1, 2, 0.98), (2, 3, 0.91)])
    )
    let wrongModel = SubtitleLanguageDetection.Candidate(
        localeIdentifier: "zh_CN",
        words: words([(0, 1, 0.6), (1, 2, 0.5), (2, 3, 0.55)])
    )
    checkEqual(
        SubtitleLanguageDetection.pick([wrongModel, english])?.localeIdentifier, "en_US",
        "检测裁决：高置信候选胜出"
    )
    // 全部低于阈值 → nil（让用户手选，不硬猜）。
    let noise = SubtitleLanguageDetection.Candidate(
        localeIdentifier: "ja_JP",
        words: words([(0, 1, 0.2), (1, 2, 0.3), (2, 3, 0.25)])
    )
    check(
        SubtitleLanguageDetection.pick([noise]) == nil,
        "检测裁决：全候选低于阈值时判定失败"
    )
    // 并列取先到者 —— 调用方按优先级排列候选（元数据 → 系统首选 → 已装）。
    let tieA = SubtitleLanguageDetection.Candidate(
        localeIdentifier: "de_DE", words: words([(0, 1, 0.9), (1, 2, 0.9), (2, 3, 0.9)])
    )
    let tieB = SubtitleLanguageDetection.Candidate(
        localeIdentifier: "fr_FR", words: words([(0, 1, 0.9), (1, 2, 0.9), (2, 3, 0.9)])
    )
    checkEqual(
        SubtitleLanguageDetection.pick([tieA, tieB])?.localeIdentifier, "de_DE",
        "检测裁决：并列取优先级更高的候选"
    )
    // 词数不足的候选在有足数候选时被排除（噪声上一两个高置信词不算数）。
    let sparse = SubtitleLanguageDetection.Candidate(
        localeIdentifier: "ko_KR", words: words([(0, 1, 0.99), (1, 2, 0.99)])
    )
    let full = SubtitleLanguageDetection.Candidate(
        localeIdentifier: "en_GB", words: words([(0, 1, 0.8), (1, 2, 0.8), (2, 3, 0.8)])
    )
    checkEqual(
        SubtitleLanguageDetection.pick([sparse, full])?.localeIdentifier, "en_GB",
        "检测裁决：词数不足的候选让位于足数候选"
    )
    // 全部词数不足时退回全体比较 —— 短素材不能永远检测不了。
    checkEqual(
        SubtitleLanguageDetection.pick([sparse])?.localeIdentifier, "ko_KR",
        "检测裁决：全候选词数不足时退回全体比较"
    )
}
