import Foundation

// **本地化覆盖自检**：源码里写死的界面文案，必须在 en 原文表和每一张译文表里都有。
// 这个文件管调用点扫描；表的发现与对账在 Tables.swift。编译方式见 scripts/check-localization-coverage.sh。
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
    // 录屏设置早就在用、却一直没进这张表（2026-09-24 导出面板要用它时补上）：
    // 在此之前「Frame rate」「Save to」这几条是碰巧在表里，不是被守着。
    "LabeledContent",
    // 仓库自己的控件：第一个实参就是 LocalizedStringKey，最后还是进 Text。
    // 不列进来的话，整条检查器右栏（全是 labelledSlider）都是扫描盲区 ——
    // 2026-09-17 加文字功能时发现「Box width」这类文案一条都没被守到。
    "labelledSlider", "decorationRow",
]
/// 带实参标签的查表调用：`String(localized: "…")`。
///
/// 注意它**只认系统语言**，不认 App 内的语言选择，所以生产代码里应该用 `L10n`；
/// 这里仍然扫，免得有人写回去时守卫看不见。
private let localizedLabelledCalls = ["localized"]
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
    // 语言选择器里各语言的名字（`AppLanguage.nativeName`）不在这里：它们经
    // `Text(verbatim:)` 画、属性名也不叫 title / displayName，扫描本来就碰不到。
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
        // ToolbarIcon(help: "…")、LabeledSlider(label: "…")：文案经参数转交，
        // 最后还是进 Text/instantHelp。只认调用名会漏掉这一整类。
        // `DispatchQueue(label:)` 排掉 —— 那是队列名，不是给人看的。
        "(?<!DispatchQueue\\()\\b(?:help|label):\\s*\(literal)",
        // String(localized: "…")。
        "\\b(?:\(localizedLabelledCalls.joined(separator: "|"))):\\s*\(literal)",
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

// MARK: - 运行期才成形的 key

/// `L10n(section.title)` / `LocalizedStringKey(kind.title)` 这种**动态 key**：
/// 键不写在调用点，而是某个属性算出来的。只扫调用点的话，这一整类都是假绿 ——
/// 把每张表里对应的条目全删掉，守卫照样全绿。
///
/// 做法：先从调用点收集用到的属性名（`title`、`blurb`、`displayName`…），再回头
/// 把这些名字的**计算属性体**里的字面量都当成 key。覆盖不了在初始化时赋值的存储
/// 属性（那要真求值才知道），那部分靠每张表键集必须相同兜住。
///
/// 第二类同样扫不到调用点：**返回 `LocalizedStringKey` 的函数/属性**。
/// 2026-09-17 加文字动画时发现这是个盲区 —— 检查器里好几条提示文案从没被
/// 守过，全靠写的人自觉。
func dynamicKeys(in files: [String]) -> [Occurrence] {
    let callSite = try! NSRegularExpression(
        pattern: #"(?:L10n|LocalizedStringKey)\(\s*([A-Za-z_][A-Za-z0-9_.]*)\s*\)"#
    )
    var propertyNames: Set<String> = []
    var sources: [(path: String, text: String)] = []
    for path in files {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
        let source = strippingComments(raw)
        sources.append((path, source))
        let ns = source as NSString
        callSite.enumerateMatches(in: source, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, let range = Range(match.range(at: 1), in: source) else { return }
            // `state.section.title` → `title`
            if let name = source[range].split(separator: ".").last { propertyNames.insert(String(name)) }
        }
    }

    let literal = try! NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
    var found: [Occurrence] = []

    // 返回 LocalizedStringKey 的函数/属性：文案写在 return 后面，调用点只有
    // 一个变量名，前面那几条调用点规则一条都够不着。`?` 是为了把
    // `-> LocalizedStringKey?`（"没有提示就返回 nil"那种）也一起收进来。
    let keyReturning = try! NSRegularExpression(
        pattern: #"(?:->|:)\s*LocalizedStringKey\??\s*\{"#
    )
    for (path, source) in sources {
        found += literals(inBodiesMatching: keyReturning, source: source, path: path, literal: literal)
    }

    for (path, source) in sources {
        for name in propertyNames {
            let declaration = try! NSRegularExpression(pattern: "\\bvar\\s+\(name)\\s*:\\s*String\\s*\\{")
            let ns = source as NSString
            declaration.enumerateMatches(in: source, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let match, let start = Range(match.range, in: source)?.upperBound else { return }
                // 从开花括号数到配对的闭花括号，只取这个属性自己的体。
                var depth = 1
                var end = start
                var index = start
                while index < source.endIndex {
                    if source[index] == "{" { depth += 1 }
                    if source[index] == "}" {
                        depth -= 1
                        if depth == 0 { end = index; break }
                    }
                    index = source.index(after: index)
                }
                guard depth == 0 else { return }
                let body = String(source[start..<end])
                let line = source[source.startIndex..<start]
                    .reduce(into: 1) { count, ch in if ch == "\n" { count += 1 } }
                let bodyRange = NSRange(location: 0, length: (body as NSString).length)
                literal.enumerateMatches(in: body, range: bodyRange) { hit, _, _ in
                    guard let hit, let range = Range(hit.range(at: 1), in: body) else { return }
                    found.append(Occurrence(key: unescaped(String(body[range])), file: path, line: line))
                }
            }
        }
    }
    return found
}


/// 扫出所有匹配 `declaration` 的声明，把各自**函数体里的字面量**当成 key。
///
/// 从开花括号数到配对的闭花括号，只取这个声明自己的体。
func literals(
    inBodiesMatching declaration: NSRegularExpression,
    source: String, path: String, literal: NSRegularExpression
) -> [Occurrence] {
    var found: [Occurrence] = []
    let ns = source as NSString
    declaration.enumerateMatches(in: source, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
        guard let match, let start = Range(match.range, in: source)?.upperBound else { return }
        var depth = 1
        var end = start
        var index = start
        while index < source.endIndex {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 { end = index; break }
            }
            index = source.index(after: index)
        }
        guard depth == 0 else { return }
        let body = String(source[start..<end])
        let line = source[source.startIndex..<start]
            .reduce(into: 1) { count, ch in if ch == "\n" { count += 1 } }
        let bodyRange = NSRange(location: 0, length: (body as NSString).length)
        literal.enumerateMatches(in: body, range: bodyRange) { hit, _, _ in
            guard let hit, let range = Range(hit.range(at: 1), in: body) else { return }
            found.append(Occurrence(key: unescaped(String(body[range])), file: path, line: line))
        }
    }
    return found
}

// MARK: - 跑

let root = FileManager.default.currentDirectoryPath
let sources = root + "/Sources"
let resources = root + "/Sources/SrtFlow/Resources"
let languages = localizations(under: resources)

var failures = 0

// 至少要有原文 + 一种译文：一张都找不到就是目录搬了、扫描规则失效，宁可当场红。
if !languages.contains(referenceLanguage) || languages.count < 2 {
    print("FAIL \(resources) 下只找到这些语言：\(languages)（要有 \(referenceLanguage) 和至少一种译文）")
    failures += 1
}

// 界面文案表：每种语言一张，逐张和原文对账（键集、空值、占位符、重复键）。
let (loaded, tableFailures) = verifyTables(named: "Localizable.strings", languages: languages, resources: resources)
failures += tableFailures

// 系统权限弹窗的用途说明（InfoPlist.strings）同样每种语言一张、键集一致：
// 少一张，那种语言的用户在权限弹窗里看到的就是英文。
failures += verifyTables(named: "InfoPlist.strings", languages: languages, resources: resources).failures

let occurrences = scan(swiftFiles(under: sources)) + dynamicKeys(in: swiftFiles(under: sources))
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
    print("All \(distinct.count) 条界面文案在 \(languages.joined(separator: " / ")) 每张表里都有。")
} else {
    print("\n\(failures) 处问题。")
    print("  · 缺文案：每张表都要补 —— en 填原文，其余各填那种语言的译文。")
    print("  · 重复键：一个键只能有一个含义，把其中一处改成更具体的键（如 Font size）。")
    print("  · 确实不需要翻译的（单位、符号）：加进 checks/LocalizationCoverage/main.swift 的 exempt，并写清为什么。")
    exit(1)
}
