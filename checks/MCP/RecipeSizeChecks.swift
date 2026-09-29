import CoreGraphics
import Foundation
import SrtFlowCore

// 风格卡里的字号在竖屏上放得下（2026-09-29，docs/bugfixes/2026-09-29-recipe-sizes-too-big-on-vertical.md）：
// SrtFlow 的字号按画面高度算（1080 高的画面上多少像素），9:16 的画面 1920 高，同一个数字画出来相对宽度大 1.78 倍。
// 卡里原来照 16:9 的习惯给 9:16 写了 font_size 110–140、字幕 64–72，AI 照做的大字折成三行、顶出画面，字幕一行一两个词。
// 1. 画幅里有 9:16 的卡，每个 font_size / size 的范围都写明是哪种画幅的（「on 9:16」「on 16:9」）。
// 2. 写给 9:16 的上限用生产那一套量：font_size 用 set_text 的排版（TextTypesetter / TextRenderer.layoutFrame / AITextFit）
//    在 1080×1920 上排 14 个英文大写、8 个中文，各一行、不出画面；字幕 size 用生成字幕切行的 SubtitleLineFit，
//    默认样式（粗体）开着放大 1.1 倍的高亮，一行至少放得下 9 个字号宽（英文约 18 个字母、三四个词）。

func runRecipeSizeChecks() {
    let resources = URL(fileURLWithPath: "Sources/SrtFlow/Resources", isDirectory: true)
    for card in AIBuiltInRecipes.load(from: [resources]) {
        let lines = card.body.components(separatedBy: "\n")
        guard lines.contains(where: { $0.contains("- Shape:") && $0.contains("9:16") }) else { continue }
        for line in lines {
            for range in RecipeSizes.ranges(in: line) {
                check(range.shape != nil, "\(card.id): \"\(range.text)\" says which shape it is for (on 9:16 / on 16:9)")
                guard range.shape == "9:16" else { continue }
                switch range.kind {
                case .text:
                    for sample in RecipeSizes.textSamples {
                        let fit = RecipeSizes.textFit(sample.text, font: sample.font, size: range.upper)
                        check(fit.lines == 1 && fit.overflow == nil,
                              "\(card.id): font_size \(Int(range.upper)) on 9:16 fits \(sample.label) on one line inside the frame (lines \(fit.lines), \(fit.overflow.map(AITextFit.describe) ?? "inside"))")
                    }
                case .subtitle:
                    let ems = RecipeSizes.subtitleEms(size: range.upper)
                    check(ems >= 9, "\(card.id): subtitle size \(Int(range.upper)) on 9:16 leaves at least 9 ems a line (got \(String(format: "%.1f", ems)))")
                }
            }
        }
    }
}

enum RecipeSizes {
    enum Kind { case text, subtitle }

    struct Range {
        var text: String
        var kind: Kind
        var upper: Double
        /// 「on 9:16」「on 16:9」；没写是 nil。
        var shape: String?
    }

    static let textSamples = [
        (label: "14 English capitals", text: "MAKE YOUR FILM", font: "Avenir Next"),
        (label: "8 Chinese characters", text: "用人工智能拍电影", font: "PingFang SC")
    ]

    /// 一行里的字号范围：「font_size 44–52 on 9:16」「size 56–64 on 16:9 or 42–48 on 9:16」「28–36 on 16:9, 16–20 on 9:16」——
    /// 数字前面最近的那个 font_size / size 说它是哪一种。只认写了画幅的、或者紧跟在 font_size / size 后面的
    /// （「3–4 words a line」「0.15–0.25 s」不是字号）。
    static func ranges(in line: String) -> [Range] {
        let pattern = try! NSRegularExpression(pattern: #"(\d+)–(\d+)( on (9:16|16:9))?"#)
        let keyword = try! NSRegularExpression(pattern: #"(font_size|(?<![_\w])size)\b"#)
        let text = line as NSString
        var result: [Range] = []
        for match in pattern.matches(in: line, range: NSRange(location: 0, length: text.length)) {
            let before = NSRange(location: 0, length: match.range.location)
            guard let last = keyword.matches(in: line, range: before).last else { continue }
            // 关键字和数字之间隔着别的量（letter_spacing、line_width……）就不是字号。
            let between = text.substring(with: NSRange(location: last.range.upperBound, length: match.range.location - last.range.upperBound))
            if between.contains("letter_spacing") || between.contains("line_width") || between.contains("margin") { continue }
            let kind: Kind = text.substring(with: last.range) == "font_size" ? .text : .subtitle
            let shape = match.range(at: 4).location == NSNotFound ? nil : text.substring(with: match.range(at: 4))
            if shape == nil, !between.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            result.append(Range(text: text.substring(with: match.range), kind: kind,
                                upper: Double(text.substring(with: match.range(at: 2))) ?? 0, shape: shape))
        }
        return result
    }

    /// set_text 那一套排版：默认的框（宽 0.8、正中），粗体。
    static func textFit(_ text: String, font: String, size: Double) -> (lines: Int, overflow: AITextFit.Overflow?) {
        let canvas = CGSize(width: 1080, height: 1920)
        var overlay = TextOverlay(text: text, timelineStart: 0)
        overlay.style.fontName = font
        overlay.style.bold = true
        overlay.style.fontSize = size
        let layout = TextTypesetter.layout(overlay, canvas: canvas)
        return (layout.lines.count, AITextFit.overflow(of: TextRenderer.layoutFrame(overlay, canvas: canvas), canvas: canvas))
    }

    /// 生成字幕切行那一套：默认样式（粗体 Helvetica）换个字号，开着放大 1.1 倍的高亮（SubtitleLineFit 按占一行的一半让）。
    static func subtitleEms(size: Double) -> Double {
        var style = BurnInStyle.default
        style.fontSize = size
        let ems = SubtitleLineFit.ems(style: style, layout: nil, renderSize: CGSize(width: 1080, height: 1920))
        return ems / (1 + (1.1 - 1) * 0.5)
    }
}
