import SrtFlowCore

// 字幕在预览和成片里摆在同一处（2026-09-29，docs/bugfixes/2026-09-29-subtitle-preview-line-box-differs-from-libass.md）：
// libass 的行框（一行多高、基线在行里哪儿）用字体 OS/2 的 win 量度，CoreText 用 hhea —— 两套量度不同的字体
// （Helvetica 是默认字体、Hiragino Sans GB、宋体）预览和成片的竖向位置和两行之间的距离不一样，以前只比大小、没比位置。
// 这里对每一种对齐（底部 / 居中 / 顶部）、一行和两行、英文和中英混排，量预览（BurnInSubtitleOverlay 离屏渲）和成片
// （BurnInWorkspace + ffmpeg 真烧一帧）字的外框上下沿各差多少。编法见 scripts/check-subtitle-burn-size.sh。
// 不管什么：字的大小（main.swift）、阴影（ShadowChecks.swift）。

private let placedPositions: [SubtitlePosition] = [.bottomCenter, .middleCenter, .topCenter]

/// 预览和成片字的上下沿最多差这么多像素（1080p 画布；没修时差 8–17 px，宋体两行差 40 px）。
private let placeTolerance = 3.0

private struct PlacedCase {
    var font: String
    var size: Double
    var bold: Bool
    var texts: [String]
    var why: String
}

private let placedCases: [PlacedCase] = [
    // 默认字体：hhea 的上下量度和 win 的不一样 —— 正中成片低 8 px、顶部低 16 px、两行的行距差 14 px（100 号）。
    PlacedCase(font: "Helvetica", size: 100, bold: false, texts: ["HHHH", "HHHH\nHHHH", "Hello 南极\nHHHH 冰山"], why: "hhea ≠ win"),
    // 纯中文的两行：换行符落在样式的字体（Helvetica）里，不许把它算进行框（libass 里换行不是字）。
    PlacedCase(font: "Helvetica", size: 100, bold: false, texts: ["南极冰山\n企鹅"], why: "the line break is not a glyph"),
    // 默认样式（粗体 56 号）。
    PlacedCase(font: "Helvetica", size: 56, bold: true, texts: ["Hello world\nHHHH"], why: "default style"),
    // hhea 比 win 大：行距要收紧（SwiftUI 的 lineSpacing 不认负数，一行一个 Text 用 VStack 的间距摆）。
    PlacedCase(font: "Songti SC", size: 100, bold: false, texts: ["HHHH\nHHHH"], why: "hhea line taller than win: negative spacing"),
    PlacedCase(font: "Hiragino Sans GB", size: 100, bold: false, texts: ["Hello 南极\nHHHH 冰山"], why: "hhea ≠ win, other direction"),
    // 两套量度一样的字体：不许被挪。
    PlacedCase(font: "Avenir Next", size: 100, bold: false, texts: ["HHHH\nHHHH"], why: "same metrics: leave alone")
]

func runPositionChecks(ffmpeg: String) {
    for item in placedCases {
        for text in item.texts {
            for position in placedPositions {
                let style = BurnInStyle(name: "check", fontName: item.font, fontSize: item.size, bold: item.bold,
                                        outlineWidth: 0, position: position)
                let label = "\(text.replacingOccurrences(of: "\n", with: " / ")) [\(item.font)\(item.bold ? " bold" : "") \(Int(item.size)), \(position)]"
                let preview = MainActor.assumeIsolated { previewBox(text, style: style, highlights: [], highlight: nil) }
                let burned = burnBox(text, style: style, highlights: [], highlight: nil, ffmpeg: ffmpeg)
                guard let preview, let burned else {
                    check(false, "\(label): could not measure")
                    continue
                }
                print("\(label): preview y \(Int(preview.minY))…\(Int(preview.maxY)), burned y \(Int(burned.minY))…\(Int(burned.maxY))")
                check(abs(preview.minY - burned.minY) <= placeTolerance,
                      "\(label): text top is at \(Int(preview.minY)) in the preview, \(Int(burned.minY)) burned (\(item.why))")
                check(abs(preview.maxY - burned.maxY) <= placeTolerance,
                      "\(label): text bottom is at \(Int(preview.maxY)) in the preview, \(Int(burned.maxY)) burned (\(item.why))")
            }
        }
    }
}
