import Foundation
import Translation

// TranslationPreflight（翻译配对预检）+ TranslationConfigurationVendor
//（翻译任务的 configuration 换代）的自检。编译方式见
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

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String, line: Int = #line) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL [line \(line)] \(message): got \(actual), expected \(expected)")
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

// 5. configuration 换代：每次任务发的配置必须与之前**任何一份**都不相等。
//
// 回归（2026-08-09）：`TranslationSession.Configuration` 是带 version 的值类型，
// `==` 把 version 一起比。每个任务各自 `Configuration(source:target:)` 新建的话，
// 两次同样语言的任务拿到的配置完全相等 → SwiftUI 的 `.translationTask` 判定
// 「没变化」→ action 不重跑 → run(session:) 永远收不到 session →
// continuation 永久悬挂，面板停在 0/N。用户实测：第一次翻译 127 条正常，
// 紧接着第二次同样 en→zh 就卡死。
do {
    let en = Locale.Language(identifier: "en")
    let zh = Locale.Language(identifier: "zh")
    let ja = Locale.Language(identifier: "ja")

    // 先钉住 Apple 的语义本身（这是本修复所依赖的外部事实）：
    // 新建两份同语言配置是**相等**的，invalidate 之后才不相等。
    let a = TranslationSession.Configuration(source: en, target: zh)
    let b = TranslationSession.Configuration(source: en, target: zh)
    check(a == b, "外部事实：新建两份同语言 Configuration 是相等的（所以必须换代）")
    var bumped = a
    bumped.invalidate()
    check(a != bumped, "外部事实：invalidate() 之后不再相等")
    check(bumped.source == en && bumped.target == zh, "invalidate() 保留语言")

    // 发放器的硬不变量：连发若干次（含语言来回切换）两两都不相等。
    var vendor = TranslationConfigurationVendor()
    let sequence: [(Locale.Language, Locale.Language)] = [
        (en, zh), (en, zh), (en, zh), (en, ja), (en, zh), (en, zh)
    ]
    let issued = sequence.map { vendor.next(source: $0.0, target: $0.1) }
    var allDistinct = true
    for i in issued.indices {
        for j in issued.indices where j > i {
            if issued[i] == issued[j] { allDistinct = false }
        }
    }
    check(allDistinct, "发放器：任意两次发出的配置都不相等（含 A→B→A 来回切）")
    check(
        issued[0] != issued[1] && issued[1] != issued[2],
        "发放器：同一对语言连发也必须每次换代（本回归的判别用例）"
    )
    checkEqual(issued[3].target, ja, "发放器：换语言后目标语言要跟着变")
    checkEqual(issued[4].target, zh, "发放器：换回来之后目标语言仍然正确")
    checkEqual(issued[0].source, en, "发放器：源语言要保住")
}

if failures == 0 {
    print("All \(checks) checks passed.")
} else {
    print("\(failures) of \(checks) checks FAILED.")
    exit(1)
}
