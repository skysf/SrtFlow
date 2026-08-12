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
    // 语言选择器的三个选项：**故意不翻译**，每一项都用它代表的那种语言写，
    // 这样界面现在是哪种语言，用户都能认出自己要的那一项（AppLanguage.displayName）。
    "System", "English", "简体中文",
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
/// 把两张表里对应的条目全删掉，守卫照样全绿。
///
/// 做法：先从调用点收集用到的属性名（`title`、`blurb`、`displayName`…），再回头
/// 把这些名字的**计算属性体**里的字面量都当成 key。覆盖不了在初始化时赋值的存储
/// 属性（那要真求值才知道），那部分靠两张表键集必须相同兜住。
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

// MARK: - 字符串表

func table(at path: String) -> [String: String]? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil)
    return parsed as? [String: String]
}

/// 同一张表里出现两次的键。
///
/// 解析器**不会报错**，后面那条静静地盖掉前面那条 —— 表现为「明明翻译过了，
/// 界面上却是另一个词」。实测踩过：`"Size"` 在样式编辑里是「字号」、在画中画里
/// 是「大小」，同一个键写了两遍，字号那处就跟着显示成了「大小」。
/// 一个键只能有一个含义：撞车了就把其中一处改成更具体的键（`Font size`）。
func duplicateKeys(inRawTableAt path: String) -> [String] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    let regex = try! NSRegularExpression(pattern: #"^"((?:[^"\\]|\\.)*)"\s*="#, options: [.anchorsMatchLines])
    var counts: [String: Int] = [:]
    let ns = text as NSString
    regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
        guard let match, let range = Range(match.range(at: 1), in: text) else { return }
        counts[unescaped(String(text[range])), default: 0] += 1
    }
    return counts.filter { $0.value > 1 }.keys.sorted()
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
    for key in duplicateKeys(inRawTableAt: path) {
        print("FAIL \(lang) 表里 \"\(key)\" 出现了两次（后面那条会静静盖掉前面那条）")
        failures += 1
    }
}

// 两张表的键集必须完全相同。
//
// 这条是**兜底**：动态 key（存储属性、运行期拼出来的）静态扫不到，一旦有人只往
// 一张表里加，上面的逐条核对不会报错，界面上却会一边有一边没有。
if let en = loaded["en"], let zh = loaded["zh-Hans"] {
    for key in Set(en.keys).subtracting(zh.keys).sorted() {
        print("FAIL 只有 en 表里有：\"\(key)\"（zh-Hans 缺译文）")
        failures += 1
    }
    for key in Set(zh.keys).subtracting(en.keys).sorted() {
        print("FAIL 只有 zh-Hans 表里有：\"\(key)\"（en 缺原文）")
        failures += 1
    }
}

// 译文不许为空：空串在界面上就是一片空白，比留着英文还糟。
for (lang, dict) in loaded {
    for (key, value) in dict where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        print("FAIL \(lang) 表里 \"\(key)\" 的译文是空的")
        failures += 1
    }
}

// 占位符必须两张表一致。
//
// `String(format:)` 按格式串取参数：译文少一个 %@ 就少读一个参数（内容错位），
// 多一个就去读根本没传的参数（**崩溃**）。这类错误只在那条错误路径真的发生时才
// 暴露，测不到。
func placeholders(in text: String) -> [String] {
    let regex = try! NSRegularExpression(pattern: #"%(\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|L|z|t|j)?[@dDuUxXoOfeEgGcCsSpaAn%]"#)
    let ns = text as NSString
    return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        .map { ns.substring(with: $0.range) }
        .filter { $0 != "%%" }
}
if let en = loaded["en"], let zh = loaded["zh-Hans"] {
    for (key, enValue) in en.sorted(by: { $0.key < $1.key }) {
        guard let zhValue = zh[key] else { continue }
        let a = placeholders(in: enValue), b = placeholders(in: zhValue)
        // 不带位置的（`%@`）按出现顺序取参数，所以**按顺序比**，不比多重集：
        // `%d, %@` 变成 `%@, %d` 会被抓住。
        //
        // **抓不住的**：两个同类型占位符对调（`%@ … %@`）—— 调完序列一模一样，
        // 静态上根本分辨不出来。所以规矩是：**要换语序就用带位置的 `%1$@`/`%2$@`**，
        // 那是唯一能安全重排的写法（这时才比多重集）。
        let positional = (a + b).allSatisfy { $0.contains("$") }
        let mismatch = positional ? a.sorted() != b.sorted() : a != b
        if mismatch {
            print("FAIL \"\(key)\" 两张表的占位符对不上：en \(a) vs zh-Hans \(b)")
            if !positional && a.sorted() == b.sorted() {
                print("     （数量一样、顺序不同 —— 要换语序请改用 %1$@ / %2$@ 这种带位置的写法）")
            }
            failures += 1
        }
    }
}

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
    print("All \(distinct.count) 条界面文案在 en / zh-Hans 两张表里都有。")
} else {
    print("\n\(failures) 处问题。")
    print("  · 缺文案：两张表都要补 —— en 填原文，zh-Hans 填译文。")
    print("  · 重复键：一个键只能有一个含义，把其中一处改成更具体的键（如 Font size）。")
    print("  · 确实不需要翻译的（单位、符号）：加进 checks/LocalizationCoverage/main.swift 的 exempt，并写清为什么。")
    exit(1)
}
