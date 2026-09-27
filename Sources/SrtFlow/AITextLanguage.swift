import Foundation
import NaturalLanguage

// MARK: - 一段字幕是什么语言（按字判断）
//
// 管什么：用系统自带的 NaturalLanguage 判断一批句子的主要语言，给 AI 翻译用来定「原文是什么语言」。
// 纯函数，自检够得着（scripts/check-mcp.sh）。
// 不管什么：翻译要不要先下载语言（AITranslationReadiness）。
//
// 为什么要按字判断：AI 可能刚把原文整轨改写成另一种语言，工程里记的还是旧的（2026-09-27 实测：
// 原文改成了中文、记的还是英文，系统就按「英文→韩文」去翻中文字幕，
// docs/bugfixes/2026-09-27-ai-translation-stale-source-language.md）。

enum AITextLanguage {
    /// 全部句子一起判；太短、太杂判不出来就是 nil（调用方退回工程里记的）。返回 BCP-47 标签（en、zh-Hans、ko…）。
    static func dominant(in texts: [String]) -> String? {
        let text = texts.joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage, language != .undetermined,
              (recognizer.languageHypotheses(withMaximum: 1)[language] ?? 0) >= 0.5 else { return nil }
        return language.rawValue
    }
}
