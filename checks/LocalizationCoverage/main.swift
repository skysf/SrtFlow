import Foundation

// **本地化覆盖自检**：源码里写死的界面文案，必须在 en 和 zh-Hans 两张表里都有。
// 编译方式见 scripts/check-localization-coverage.sh。
//
// 由来（docs/bugfixes/2026-08-12-instant-tooltip-first-show-far-off.md）：
// 查不到本地化键是**静默降级** —— 不报错、不崩，只是在中文界面里原样显示英文。
// 编译器和代码审查都发现不了，只有中文用户挨个点过去才看得见。2026-08-12 一次
// 就扫出 132 条从没进过表的文案。
//
// 为什么用 Swift 而不是 grep：调用点经常换行（`Label(\n    "…"`），文档注释里
// 又常写着示例代码。行扫描要么漏掉前者，要么把后者当真文案 —— 两种都会让守卫
// 变成摆设。

// MARK: - 要扫的调用点

/// 第一个实参是 `LocalizedStringKey`（或走 `L10n` 查表）的调用。
/// 加新的 SwiftUI 控件时记得往这里补，漏一个就是漏一类文案。
private let localizedCalls = [
    "Text", "L10n", "Label", "Button", "Toggle", "Picker", "TextField",
    "Section", "Stepper", "Menu", "Link", "LocalizedStringKey",
    "instantHelp", "confirmationDialog",
]
/// 以点开头的修饰符（`.alert("…")`、`.navigationTitle("…")`）。
private let localizedModifiers = ["alert", "navigationTitle"]

/// **明确豁免**：这些字面量在任何语言下都长一样。往这里加东西之前，先能说出
/// 「它为什么不需要翻译」—— 说不出来就是该翻。
private let exempt: Set<String> = [
    "",             // Picker 的空标签（标题由外面画）
    "%", "°", "s",  // 检查器里的单位
    "X", "Y",       // 坐标轴标签
    "|",            // 时间线刻度的分隔竖线
    "→",            // 双语字幕行里的方向箭头
    "中",            // 字体预览的示例字
    "SrtFlow",      // App 名
]

/// 把源码里的转义还原成真实字符。
///
/// 表是被 plist 解析器读进来的，`"…:\n%@"` 那种键里已经是**真的换行**；而扫描
/// 拿到的是源码原文（反斜杠 + n 两个字符）。不还原就会把两条本来配好的长文案
/// 误报成缺失 —— 第一版就是这么误报的。
func unescaped(_ literal: String) -> String {
    var out = ""
    var iterator = literal.startIndex
    while iterator < literal.endIndex {
        let c = literal[iterator]
        guard c == "\\", literal.index(after: iterator) < literal.endIndex else {
            out.append(c)
            iterator = literal.index(after: iterator)
            continue
        }
        let next = literal[literal.index(after: iterator)]
        switch next {
        case "n": out.append("\n")
        case "t": out.append("\t")
        case "r": out.append("\r")
        case "\"": out.append("\"")
        case "'": out.append("'")
        case "\\": out.append("\\")
        default: out.append(c); out.append(next)
        }
        iterator = literal.index(iterator, offsetBy: 2)
    }
    return out
}

// MARK: - 源码扫描

/// 去掉注释，但**不碰字符串字面量里的 `//`**（"https://…" 不是注释）。
func strippingComments(_ source: String) -> String {
    var out = ""
    var inString = false
    var inLineComment = false
    var inBlockComment = false
    var escaped = false
    var iterator = source.startIndex

    while iterator < source.endIndex {
        let c = source[iterator]
        let next = source.index(after: iterator) < source.endIndex
            ? source[source.index(after: iterator)] : nil

        if inLineComment {
            if c == "\n" { inLineComment = false; out.append(c) }
        } else if inBlockComment {
            if c == "*", next == "/" {
                inBlockComment = false
                iterator = source.index(after: iterator)
            } else if c == "\n" {
                out.append(c)
            }
        } else if inString {
            out.append(c)
            if escaped { escaped = false }
            else if c == "\\" { escaped = true }
            else if c == "\"" { inString = false }
        } else if c == "/", next == "/" {
            inLineComment = true
            iterator = source.index(after: iterator)
        } else if c == "/", next == "*" {
            inBlockComment = true
            iterator = source.index(after: iterator)
        } else {
            if c == "\"" { inString = true }
            out.append(c)
        }
        iterator = source.index(after: iterator)
    }
    return out
}

func swiftFiles(under directory: String) -> [String] {
    guard let walker = FileManager.default.enumerator(atPath: directory) else { return [] }
    return walker.compactMap { $0 as? String }
        .filter { $0.hasSuffix(".swift") }
        .map { directory + "/" + $0 }
        .sorted()
}

/// 源码里出现的一条写死文案，以及它在哪。
struct Occurrence {
    let key: String
    let file: String
    let line: Int
}

func scan(_ files: [String]) -> [Occurrence] {
    let callNames = localizedCalls.map { "\\b\($0)" }.joined(separator: "|")
    let modifierNames = localizedModifiers.map { "\\.\($0)" }.joined(separator: "|")
    let literal = #""((?:[^"\\]|\\.)*)""#
    let patterns = [
        // Foo("…") / .alert("…")：第一个实参就是文案，所以 ( 后面直接跟引号。
        // `Text(verbatim: "…")` 因此天然不匹配 —— 它本来就不该查表。
        "(?:\(callNames)|\(modifierNames))\\s*\\(\\s*\(literal)",
        // ToolbarIcon(help: "…")：经参数转交给 instantHelp。
        "\\bhelp:\\s*\(literal)",
    ].map { try! NSRegularExpression(pattern: $0, options: [.dotMatchesLineSeparators]) }

    var found: [Occurrence] = []
    for path in files {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
        let source = strippingComments(raw)
        let ns = source as NSString
        for regex in patterns {
            regex.enumerateMatches(in: source, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let match, let range = Range(match.range(at: 1), in: source) else { return }
                let key = unescaped(String(source[range]))
                let line = source[source.startIndex..<range.lowerBound]
                    .reduce(into: 1) { count, ch in if ch == "\n" { count += 1 } }
                found.append(Occurrence(key: key, file: path, line: line))
            }
        }
    }
    return found
}

// MARK: - 字符串表

func table(at path: String) -> [String: String]? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil)
    return parsed as? [String: String]
}

// MARK: - 跑

let root = FileManager.default.currentDirectoryPath
let sources = root + "/Sources"
let tables = [
    "en": root + "/Sources/SrtFlow/Resources/en.lproj/Localizable.strings",
    "zh-Hans": root + "/Sources/SrtFlow/Resources/zh-Hans.lproj/Localizable.strings",
]

var failures = 0

var loaded: [String: [String: String]] = [:]
for (lang, path) in tables {
    guard let dict = table(at: path) else {
        // 表读不出来 = 语法坏了（多半是漏了分号或引号），必须当场红，
        // 否则下面「一条都不缺」会假绿。
        print("FAIL \(lang) 的字符串表读不出来（语法坏了？）：\(path)")
        failures += 1
        continue
    }
    loaded[lang] = dict
}

let occurrences = scan(swiftFiles(under: sources))
// 插值键（`Text("已选 \(n) 段")`）的真实键要到运行期才成形，静态扫描认不出，
// 这是本守卫**已知的盲区**，不是漏网 —— 这类文案仍要人工确认进表。
let scannable = occurrences.filter { !$0.key.contains("\\(") && !exempt.contains($0.key) }
let distinct = Set(scannable.map(\.key))

// 一条都没扫到 / 扫得异常少 = 提取规则失效，宁可当场红。
if distinct.count < 300 {
    print("FAIL 只扫到 \(distinct.count) 条界面文案，提取规则多半失效了")
    failures += 1
}

var reported = Set<String>()
for occurrence in scannable.sorted(by: { ($0.file, $0.line) < ($1.file, $1.line) }) {
    for (lang, dict) in loaded where dict[occurrence.key] == nil {
        let tag = "\(lang)\u{1F}\(occurrence.key)"
        guard !reported.contains(tag) else { continue }
        reported.insert(tag)
        let file = occurrence.file.replacingOccurrences(of: root + "/", with: "")
        print("FAIL \(lang) 表里没有：\"\(occurrence.key)\"  ← \(file):\(occurrence.line)")
        failures += 1
    }
}

if failures == 0 {
    print("All \(distinct.count) 条界面文案在 en / zh-Hans 两张表里都有。")
} else {
    print("\n\(failures) 处缺失。两张表都要补：en 填原文，zh-Hans 填译文。")
    print("确实不需要翻译的（单位、符号），加进 checks/LocalizationCoverage/main.swift 的 exempt，并写清为什么。")
    exit(1)
}
