import Foundation

// **带插值的键**：`Text("· \(n) lines")` 的真实键要到运行期才成形 —— SwiftUI 把 Int 换成 `%lld`、
// String 换成 `%@`（`"· %lld lines"`），表里得有这一条才查得到。以前这一类是守卫写明的盲区，
// 2026-09-30 做西班牙语时发现录屏设置页的「follows the project」、烧录列表的「· N lines」
// 在中文界面里也一直是英文（docs/bugfixes/2026-10-01-interpolated-keys-never-localized.md）。
//
// 静态上判不出类型，就把每个 `\(…)` 换成 `%lld` 或 `%@` 各试一遍，只要有一种写法在每张表里都有
// 就算过；去掉插值之后不含字母的（`"\(a) / \(b)"`、`"#\(n)"`、`"\(rate) kbps"`）没有要翻的字，跳过。

/// 把字面量里每个 `\(…)` 换成占位符之后的所有候选键；nil = 去掉插值后没有字母、不用翻。
func interpolationCandidates(_ literal: String) -> [String]? {
    var pieces: [String] = []       // 插值之间的文字
    var slots = 0
    var current = ""
    var index = literal.startIndex
    while index < literal.endIndex {
        if literal[index] == "\\", literal.index(after: index) < literal.endIndex,
           literal[literal.index(after: index)] == "(" {
            // 从 `\(` 数到配对的 `)`（插值里可以有嵌套的调用）。
            var depth = 0
            var cursor = literal.index(after: index)
            while cursor < literal.endIndex {
                if literal[cursor] == "(" { depth += 1 }
                if literal[cursor] == ")" { depth -= 1; if depth == 0 { break } }
                cursor = literal.index(after: cursor)
            }
            pieces.append(current); current = ""; slots += 1
            index = cursor < literal.endIndex ? literal.index(after: cursor) : cursor
            continue
        }
        current.append(literal[index])
        index = literal.index(after: index)
    }
    pieces.append(current)
    guard slots > 0 else { return nil }
    guard pieces.joined().contains(where: \.isLetter) else { return nil }
    // 每个槽 %lld / %@ 两种，槽多于 4 个就不穷举了（没有这么写的，真有也该拆开）。
    guard slots <= 4 else { return [] }
    var candidates: [String] = [""]
    for (i, piece) in pieces.enumerated() {
        if i == 0 { candidates = candidates.map { $0 + piece }; continue }
        candidates = candidates.flatMap { prefix in ["%lld", "%@"].map { prefix + $0 + piece } }
    }
    return candidates
}
