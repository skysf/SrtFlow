import Foundation

// **收 `LocalizedStringKey` 的自家函数**：从源码里找出来，调用点自动纳入扫描。
//
// 由来（docs/bugfixes/2026-09-30-animation-in-out-labels-never-localized.md）：
// 「文案经参数转交」的调用（`ToolbarIcon(help:)`、`LabeledSlider(label:)`）原来靠
// main.swift 里手抄的参数名清单。`help:` 漏过一轮、`label:` 漏过一轮，2026-09-30 又
// 发现 `animationRow(title: "In")` 这一类从没被守到 —— 同一个教训撞第三次，改成机制：
// 只要一个函数有 `LocalizedStringKey` 类型的参数，给它传字面量就一定是查表的键，
// 调用点就该扫。参数是头一个且没标签的，按「第一个实参就是文案」扫；带标签的，
// 只在**这个函数名**的调用里认那个标签（`FalModel(title:)` 这种收 String 的同名标签
// 不会被误报）。

/// 一个收文案的参数：函数名 + 标签（nil = 没标签、且是第一个参数）。
struct KeyParameter: Hashable {
    let function: String
    let label: String?
}

/// 扫出源码里所有 `func 名(...)` 声明中类型为 `LocalizedStringKey`（可选也算）的参数。
func keyParameters(in files: [String]) -> Set<KeyParameter> {
    // 函数名 + 整个参数表（允许换行；参数表里不会再有配对的括号之外的东西，
    // 闭包类型 `() -> Void` 那种一层括号用交替分支吞掉）。
    let declaration = try! NSRegularExpression(
        pattern: #"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:<[^>]*>)?\s*\(((?:[^()]|\([^()]*\))*)\)"#,
        options: [.dotMatchesLineSeparators]
    )
    // 一个参数：`_ name: Type` / `label name: Type` / `name: Type`，只取类型是 LocalizedStringKey 的。
    let parameter = try! NSRegularExpression(
        pattern: #"(?:^|,)\s*(?:(_|[A-Za-z_][A-Za-z0-9_]*)\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*:\s*LocalizedStringKey\??"#
    )
    var found: Set<KeyParameter> = []
    for path in files {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
        let source = strippingComments(raw)
        let ns = source as NSString
        declaration.enumerateMatches(in: source, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match,
                  let nameRange = Range(match.range(at: 1), in: source),
                  let listRange = Range(match.range(at: 2), in: source) else { return }
            let name = String(source[nameRange])
            let list = String(source[listRange])
            let listNS = list as NSString
            parameter.enumerateMatches(in: list, range: NSRange(location: 0, length: listNS.length)) { hit, _, _ in
                guard let hit else { return }
                let external = hit.range(at: 1).location == NSNotFound ? nil : listNS.substring(with: hit.range(at: 1))
                let internalName = listNS.substring(with: hit.range(at: 2))
                let isFirst = hit.range.location == 0 || list[..<Range(hit.range, in: list)!.lowerBound].allSatisfy { $0.isWhitespace }
                if external == "_" {
                    // 没标签：只有排在头一个时，调用点才是「函数名( "文案"」的形状。
                    if isFirst { found.insert(KeyParameter(function: name, label: nil)) }
                } else {
                    found.insert(KeyParameter(function: name, label: external ?? internalName))
                }
            }
        }
    }
    return found
}

/// 把这些参数变成调用点的正则：没标签的和 main.swift 的 `localizedCalls` 同形，
/// 带标签的只认「这个函数名 ( … 标签: "文案"」（允许实参里有一层括号）。
func keyParameterPatterns(_ parameters: Set<KeyParameter>, literal: String) -> [NSRegularExpression] {
    var patterns: [String] = []
    let positional = parameters.filter { $0.label == nil }.map(\.function).sorted()
    if !positional.isEmpty {
        patterns.append("\\b(?:\(positional.joined(separator: "|")))\\s*\\(\\s*\(literal)")
    }
    for parameter in parameters.sorted(by: { ($0.function, $0.label ?? "") < ($1.function, $1.label ?? "") }) {
        guard let label = parameter.label else { continue }
        patterns.append("\\b\(parameter.function)\\s*\\((?:[^()]|\\([^()]*\\))*?\\b\(label):\\s*\(literal)")
    }
    return patterns.map { try! NSRegularExpression(pattern: $0, options: [.dotMatchesLineSeparators]) }
}
