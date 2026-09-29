import AppKit
import CoreText
import SrtFlowCore
import SwiftUI

// 预览上的字幕和烧出来的一样大（2026-09-29，docs/bugfixes/2026-09-29-subtitle-preview-bigger-than-burn.md）：
// 同一个字号，libass 把它当行高、CoreText 把它当 em，以前预览比成片大 15%–40%（Helvetica 85%、中文回退到苹方 71%）。
// 这里拿预览那个视图（BurnInSubtitleOverlay，AI 的「看」也用它）离屏渲一张，再照导出那条路（BurnInWorkspace + 同一个
// subtitles 滤镜）真烧一帧，量字的高和宽。编法见 scripts/check-subtitle-burn-size.sh。

var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL \(message)")
    }
}

/// 亮字的外框（黑底白字）。
func textBox(_ image: CGImage) -> CGRect? {
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height)
    guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return nil }
    context.setFillColor(gray: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var minX = width, minY = height, maxX = -1, maxY = -1
    for y in 0..<height {
        for x in 0..<width where pixels[y * width + x] > 128 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    return maxX < 0 ? nil : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

let canvas = CGSize(width: 1920, height: 1080)

/// 100 号、不加粗、正中：字大，差一点也量得出来。
func large(_ font: String) -> BurnInStyle {
    BurnInStyle(name: "check", fontName: font, fontSize: 100, bold: false, outlineWidth: 0, position: .middleCenter)
}

/// 默认样式（粗体 56 号、底部居中）换个字体、去掉描边：粗体画的是家族里真的粗体，比例按它量（Hiragino Sans GB 的 W6 和
/// W3 差 7%）。
func preset(_ font: String) -> BurnInStyle {
    var style = BurnInStyle.default
    style.fontName = font
    style.outlineWidth = 0
    return style
}

@MainActor
func previewBox(_ text: String, style: BurnInStyle, highlights: [SubtitleTextRange], highlight: SubtitleWordHighlight?) -> CGRect? {
    let renderer = ImageRenderer(content: BurnInSubtitleOverlay(
        text: text, style: style, scale: 1, boxSize: canvas, highlights: highlights, highlight: highlight
    ))
    renderer.scale = 1
    renderer.isOpaque = false
    return renderer.cgImage.flatMap(textBox)
}

/// 导出那条路：BurnInWorkspace 建工作目录（ASS + 字体软链），ffmpeg 在里面用同一个 subtitles 滤镜烧一帧。
func burnBox(_ text: String, style: BurnInStyle, highlights: [SubtitleTextRange], highlight: SubtitleWordHighlight?, ffmpeg: String) -> CGRect? {
    let cue = SubtitleCue(start: 0, end: 5, text: text)
    let block = SubtitleRenderBlock(cues: [cue], layout: nil, highlight: highlight,
                                    highlights: highlights.isEmpty ? [:] : [cue.id: highlights])
    let fontURL = (CTFontCopyAttribute(CTFontCreateWithName(style.fontName as CFString, 12, nil), kCTFontURLAttribute) as? URL)
    guard let prepared = try? BurnInWorkspace.create(
        blocks: [block], style: style, fontFileURL: fontURL, aspectRatio: canvas.width / canvas.height, title: "check"
    ) else { return nil }
    defer { try? FileManager.default.removeItem(at: prepared.directory) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: ffmpeg)
    process.currentDirectoryURL = prepared.directory
    process.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "color=black:s=1920x1080:d=1",
                         "-vf", "subtitles=filename=\(prepared.paths.assFileName):fontsdir=\(prepared.paths.fontsDirName)",
                         "-frames:v", "1", "frame.png"]
    guard (try? process.run()) != nil else { return nil }
    process.waitUntilExit()
    let png = prepared.directory.appendingPathComponent("frame.png")
    guard let image = NSImage(contentsOf: png)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    return textBox(image)
}

let ffmpeg = ProcessInfo.processInfo.environment["SRTFLOW_FFMPEG"] ?? "vendor/ffmpeg"
check(FileManager.default.isExecutableFile(atPath: ffmpeg), "ffmpeg is at \(ffmpeg)")

let yellow = SubtitleWordHighlight(color: .white, scale: 1.2)
// 字体里没有的字按回退到的那一款缩（Avenir Next 里没有韩文，回退到 Apple SD Gothic Neo：0.833 对 0.732，用错比例差一成多）。
// 回退用韩文、不用中文：拉丁字体里的中文回退到苹方，而苹方是按需下载的字体资源，CI 的机器上没有，libass 用不了系统私有的那份
// （族名带点，找不到）会画成方框 —— 那是另一个问题（见 docs/bugfixes/2026-09-29-subtitle-preview-bigger-than-burn.md 的已知不足），
// 不是字号。Apple SD Gothic Neo 每台 Mac 都在 /System/Library/Fonts 里。中文由自带中文的黑体、冬青黑体来测。
let cases: [(text: String, style: BurnInStyle, highlights: [SubtitleTextRange], highlight: SubtitleWordHighlight?)] = [
    ("HHHH", large("Helvetica"), [], nil),                        // libass 0.851
    ("안녕하세요", large("Avenir Next"), [], nil),                  // Avenir Next 里没有韩文：回退到 Apple SD Gothic Neo，0.833
    ("HHHH", large("Avenir Next"), [], nil),                      // 0.732
    ("南极冰山", large("Heiti SC"), [], nil),                       // 1.0（黑体两边一样）
    ("Hello 南极", large("Hiragino Sans GB"), [], nil),            // 0.861
    ("big news", large("Helvetica"), [SubtitleTextRange(location: 4, length: 4)], yellow),   // 逐词高亮放大 1.2 倍也一样
    ("Hello world", preset("Helvetica"), [], nil),                // Helvetica-Bold 0.839
    ("안녕하세요", preset("Avenir Next"), [], nil),                  // 粗体的回退：AppleSDGothicNeo-Bold 0.833
    ("Hello 南极", preset("Hiragino Sans GB"), [], nil)            // W6 0.806（W3 是 0.861）
]
for item in cases {
    let label = "\(item.text) [\(item.style.fontName)\(item.style.bold ? " bold" : "") \(Int(item.style.fontSize))]"
    let preview = MainActor.assumeIsolated { previewBox(item.text, style: item.style, highlights: item.highlights, highlight: item.highlight) }
    let burned = burnBox(item.text, style: item.style, highlights: item.highlights, highlight: item.highlight, ffmpeg: ffmpeg)
    guard let preview, let burned else {
        check(false, "\(label): could not measure (preview \(String(describing: preview)), burn \(String(describing: burned)))")
        continue
    }
    print("\(label): preview \(Int(preview.width))×\(Int(preview.height)) at (\(Int(preview.midX)), \(Int(preview.midY))), "
        + "burned \(Int(burned.width))×\(Int(burned.height)) at (\(Int(burned.midX)), \(Int(burned.midY)))")
    check(abs(preview.height - burned.height) <= 3, "\(label): preview text is \(Int(preview.height)) px tall, burned \(Int(burned.height)) px")
    check(abs(preview.width - burned.width) <= max(4, burned.width * 0.03),
          "\(label): preview text is \(Int(preview.width)) px wide, burned \(Int(burned.width)) px")
}

if failures > 0 {
    print("✗ \(failures) of \(checks) checks failed")
    exit(1)
}
print("All \(checks) checks passed.")
