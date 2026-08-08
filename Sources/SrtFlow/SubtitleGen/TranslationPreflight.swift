import Foundation

// 翻译前的语言配对预检（docs/bugfixes/2026-08-09-subtitle-translate-after-same-language.md）。
//
// 系统 Translation 框架对配对错误只给一句通用的「Unable to Translate」
// （NSError code 恒为 1，分不出原因），所以「目标语言 = 源语言」这类
// 完全可预判的失败必须在提交前拦下来，换成能行动的文案。
// 纯函数、只依赖 Foundation —— checks/TranslationPreflight 直接编译本文件做守卫。

enum TranslationPreflight {

    /// 两个语言在翻译意义上是否同一种：比较 maximal 化后的语言码 + 文字系统。
    /// en ≍ en-Latn-US ≍ en-US；zh ≍ zh-Hans-CN；zh-Hans ≠ zh-Hant（简繁是
    /// 两个翻译方向）；区域差异（en-GB vs en-US）不构成可翻译的区别。
    static func isSameTranslationLanguage(_ a: Locale.Language, _ b: Locale.Language) -> Bool {
        let maximalA = Locale.Language(identifier: a.maximalIdentifier)
        let maximalB = Locale.Language(identifier: b.maximalIdentifier)
        guard let codeA = maximalA.languageCode?.identifier,
              let codeB = maximalB.languageCode?.identifier else {
            return false
        }
        return codeA == codeB
            && maximalA.script?.identifier == maximalB.script?.identifier
    }

    /// 给错误文案用的语言名（当前界面语言下的本地化名，查不到退回标识符）。
    static func displayName(of language: Locale.Language) -> String {
        let identifier = language.minimalIdentifier
        return Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}
