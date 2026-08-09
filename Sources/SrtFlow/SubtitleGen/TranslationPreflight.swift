import Foundation
import SrtFlowCore

// 翻译前的语言配对预检（docs/bugfixes/2026-08-09-subtitle-translate-after-same-language.md）。
//
// 系统 Translation 框架对配对错误只给一句通用的「Unable to Translate」
// （NSError code 恒为 1，分不出原因），所以「目标语言 = 源语言」这类
// 完全可预判的失败必须在提交前拦下来，换成能行动的文案。
// 纯函数 —— checks/TranslationPreflight 直接编译本文件做守卫。

enum TranslationPreflight {

    /// 两个语言在翻译意义上是否同一种：比较 maximal 化后的语言码 + 文字系统。
    /// en ≍ en-Latn-US ≍ en-US；zh ≍ zh-Hans-CN；zh-Hans ≠ zh-Hant（简繁是
    /// 两个翻译方向）；区域差异（en-GB vs en-US）不构成可翻译的区别。
    ///
    /// 判据本体在 `SubtitleLanguageDetection.languageKey(of:)` —— 自动检测的
    /// 候选去重用的是同一份实现。**别在这里复制一套**：两边分叉就会出现
    /// 「检测当成两种语言、翻译当成一种」的撕裂（AGENTS「复用优先」）。
    static func isSameTranslationLanguage(_ a: Locale.Language, _ b: Locale.Language) -> Bool {
        guard let keyA = SubtitleLanguageDetection.languageKey(of: a),
              let keyB = SubtitleLanguageDetection.languageKey(of: b) else {
            return false
        }
        return keyA == keyB
    }

    /// 给错误文案用的语言名（当前界面语言下的本地化名，查不到退回标识符）。
    static func displayName(of language: Locale.Language) -> String {
        let identifier = language.minimalIdentifier
        return Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}
