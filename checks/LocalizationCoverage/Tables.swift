import Foundation

// **字符串表这一半**：找出包里有哪些语言、读表、表和表之间对账。
// 调用点扫描那一半在 main.swift。编译方式见 scripts/check-localization-coverage.sh。
//
// 表的结构：`en.lproj` 是原文（键就是英文原文，个别缩写除外），其余每个 `<code>.lproj`
// 是一种译文。**有几张表不写死**——按 `Sources/SrtFlow/Resources/*.lproj/` 现场找，
// 加一种语言只要加目录，这里不用改（docs/architecture/localization.md「加一种界面语言」）。

/// 原文表的语言代码。别的表都拿它当基准对账。
let referenceLanguage = "en"

/// `Resources/` 下每个 `.lproj` 的名字（`en`、`zh-Hans`…），原文排第一、其余按字母。
func localizations(under resources: String) -> [String] {
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: resources)) ?? [])
        .filter { $0.hasSuffix(".lproj") }
        .map { String($0.dropLast(".lproj".count)) }
    return names.filter { $0 == referenceLanguage } + names.filter { $0 != referenceLanguage }.sorted()
}

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

/// 格式串里的占位符，按出现顺序。`%%` 不算。
func placeholders(in text: String) -> [String] {
    let regex = try! NSRegularExpression(pattern: #"%(\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|L|z|t|j)?[@dDuUxXoOfeEgGcCsSpaAn%]"#)
    let ns = text as NSString
    return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        .map { ns.substring(with: $0.range) }
        .filter { $0 != "%%" }
}

/// 读 `Resources/` 下每种语言的一张表（`Localizable.strings` 或 `InfoPlist.strings`），
/// 逐张核对：读得出来、没有重复键、键集和原文表完全相同、译文不为空、占位符和原文对得上。
/// 返回读到的表（按语言代码）和红了几条。
func verifyTables(named file: String, languages: [String], resources: String) -> (loaded: [String: [String: String]], failures: Int) {
    var failures = 0
    var loaded: [String: [String: String]] = [:]
    for lang in languages {
        let path = "\(resources)/\(lang).lproj/\(file)"
        guard let dict = table(at: path) else {
            // 表读不出来 = 语法坏了（多半是漏了分号或引号），必须当场红，
            // 否则下面「一条都不缺」会假绿。
            print("FAIL \(lang) 的 \(file) 读不出来（语法坏了？没有这张表？）：\(path)")
            failures += 1
            continue
        }
        loaded[lang] = dict
        for key in duplicateKeys(inRawTableAt: path) {
            print("FAIL \(lang) 的 \(file) 里 \"\(key)\" 出现了两次（后面那条会静静盖掉前面那条）")
            failures += 1
        }
        // 译文不许为空：空串在界面上就是一片空白，比留着英文还糟。
        for (key, value) in dict where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            print("FAIL \(lang) 的 \(file) 里 \"\(key)\" 的译文是空的")
            failures += 1
        }
    }

    guard let reference = loaded[referenceLanguage] else { return (loaded, failures) }
    for lang in languages where lang != referenceLanguage {
        guard let translated = loaded[lang] else { continue }
        // 每张译文表的键集必须和原文表完全相同。
        //
        // 这条是**兜底**：动态 key（存储属性、运行期拼出来的）静态扫不到，一旦有人只往
        // 一张表里加，逐条核对不会报错，界面上却会一种语言有、另一种没有。
        for key in Set(reference.keys).subtracting(translated.keys).sorted() {
            print("FAIL \(file)：只有 \(referenceLanguage) 表里有 \"\(key)\"（\(lang) 缺译文）")
            failures += 1
        }
        for key in Set(translated.keys).subtracting(reference.keys).sorted() {
            print("FAIL \(file)：只有 \(lang) 表里有 \"\(key)\"（\(referenceLanguage) 缺原文）")
            failures += 1
        }
        // 占位符必须和原文一致。
        //
        // `String(format:)` 按格式串取参数：译文少一个 %@ 就少读一个参数（内容错位），
        // 多一个就去读根本没传的参数（**崩溃**）。这类错误只在那条错误路径真的发生时才
        // 暴露，测不到。
        for (key, enValue) in reference.sorted(by: { $0.key < $1.key }) {
            guard let value = translated[key] else { continue }
            let a = placeholders(in: enValue), b = placeholders(in: value)
            // 不带位置的（`%@`）按出现顺序取参数，所以**按顺序比**，不比多重集：
            // `%d, %@` 变成 `%@, %d` 会被抓住。
            //
            // **抓不住的**：两个同类型占位符对调（`%@ … %@`）—— 调完序列一模一样，
            // 静态上根本分辨不出来。所以规矩是：**要换语序就用带位置的 `%1$@`/`%2$@`**，
            // 那是唯一能安全重排的写法（这时才比多重集）。
            let positional = (a + b).allSatisfy { $0.contains("$") }
            let mismatch = positional ? a.sorted() != b.sorted() : a != b
            if mismatch {
                print("FAIL \(file)：\"\(key)\" 的占位符对不上：\(referenceLanguage) \(a) vs \(lang) \(b)")
                if !positional && a.sorted() == b.sorted() {
                    print("     （数量一样、顺序不同 —— 要换语序请改用 %1$@ / %2$@ 这种带位置的写法）")
                }
                failures += 1
            }
        }
    }
    return (loaded, failures)
}
