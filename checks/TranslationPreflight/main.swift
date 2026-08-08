import Foundation

// TranslationPreflight（翻译配对预检）的自检。编译方式见
// scripts/check-translation-preflight.sh。
//
// 背景（docs/bugfixes/2026-08-09-subtitle-translate-after-same-language.md）：
// 「生成后顺便翻译」曾拿一个源语言未知时自动预选、且从未露面的目标语言
// 去配对 —— 英语系统上生成英文字幕就是 en→en，系统只回一句通用的
// 「Unable to Translate」，还因为无物可下载而永远不弹下载确认。
// 预检的合同：同语种在提交前就要被认出来（minimal/maximal/带区域全等价），
// 简繁必须视为两个方向。

var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL [line \(line)] \(message)")
    }
}

func same(_ a: String, _ b: String) -> Bool {
    TranslationPreflight.isSameTranslationLanguage(
        Locale.Language(identifier: a), Locale.Language(identifier: b)
    )
}

// 1. 事故本尊：源是 minimal 的 "en"，目标是自动预选的 maximal "en-Latn-US"。
check(same("en", "en-Latn-US"), "en 与 en-Latn-US 必须判为同语种（2026-08-09 事故路径）")

// 2. 各种书写形态等价。
check(same("en-US", "en"), "en-US 与 en 同语种")
check(same("zh", "zh-Hans-CN"), "zh 与 zh-Hans-CN 同语种")
check(same("en-GB", "en-US"), "区域差异不构成可翻译的区别")

// 3. 真正不同的方向不许误伤。
check(!same("zh-Hans", "zh-Hant"), "简繁是两个翻译方向")
check(!same("en", "zh-Hans"), "en 与 zh-Hans 不同语种")
check(!same("yue", "zh"), "粤语与普通话是不同语言码")

// 4. 错误文案用的语言名永不为空。
check(
    !TranslationPreflight.displayName(of: Locale.Language(identifier: "zh-Hans")).isEmpty,
    "displayName 永不为空"
)

if failures == 0 {
    print("All \(checks) checks passed.")
} else {
    print("\(failures) of \(checks) checks FAILED.")
    exit(1)
}
