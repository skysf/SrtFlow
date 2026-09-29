import AppKit
import SrtFlowCore
import SwiftUI

// 字幕的阴影在预览和成片里画得一样（2026-09-29 验收第二轮：AI 给字幕加了 `shadow`，接口收下了，但样式带 3 像素的黑描边、
// 阴影混在描边里，肉眼看不出画没画；之前只测了样式的数值，没有一条测真画出来的像素）。这里在中灰底上画白字，
// 预览（BurnInSubtitleOverlay 离屏渲）和成片（BurnInWorkspace + ffmpeg 的 subtitles 滤镜真烧一帧）各出一张，
// 量白字外面那圈暗处：往右下偏了多少、最黑的一点有多黑。编法见 scripts/check-subtitle-burn-size.sh。
// 不管什么：字的大小（main.swift）。

/// 白字（亮度 > 200）的外框，和暗处（亮度 < 100，底是 128）的外框、最暗的一点。
private struct ShadowMeasure {
    var text: CGRect
    var dark: CGRect?
    var darkest: Int
}

private let gray = 0.5

private func measure(_ image: CGImage) -> ShadowMeasure? {
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height)
    guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return nil }
    context.setFillColor(gray: gray, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var text = (minX: width, minY: height, maxX: -1, maxY: -1)
    var dark = text
    var darkest = 255
    for y in 0..<height {
        for x in 0..<width {
            let value = Int(pixels[y * width + x])
            if value > 200 { text = (min(text.minX, x), min(text.minY, y), max(text.maxX, x), max(text.maxY, y)) }
            if value < 100 {
                dark = (min(dark.minX, x), min(dark.minY, y), max(dark.maxX, x), max(dark.maxY, y))
                darkest = min(darkest, value)
            }
        }
    }
    func rect(_ box: (minX: Int, minY: Int, maxX: Int, maxY: Int)) -> CGRect? {
        box.maxX < 0 ? nil : CGRect(x: box.minX, y: box.minY, width: box.maxX - box.minX + 1, height: box.maxY - box.minY + 1)
    }
    guard let textBox = rect(text) else { return nil }
    return ShadowMeasure(text: textBox, dark: rect(dark), darkest: darkest)
}

/// 白字、黑色（可半透明）阴影，描边宽度由用例给；100 号 Helvetica、正中，字大、差一两个像素也量得出来。
private func shadowStyle(offset: Double, opacity: Double, outline: Double) -> BurnInStyle {
    BurnInStyle(name: "check", fontName: "Helvetica", fontSize: 100, bold: false, fillColor: .white, outlineColor: .black,
                outlineWidth: outline, shadowColor: SubtitleColor(red: 0, green: 0, blue: 0, opacity: opacity), shadowOffset: offset,
                position: .middleCenter)
}

@MainActor
private func previewOnGray(_ style: BurnInStyle) -> CGImage? {
    let renderer = ImageRenderer(content: ZStack {
        Color(white: gray)
        BurnInSubtitleOverlay(text: "HHHH", style: style, scale: 1, boxSize: canvas, highlights: [], highlight: nil)
    }.frame(width: canvas.width, height: canvas.height))
    renderer.scale = 1
    renderer.isOpaque = true
    return renderer.cgImage
}

func runShadowChecks(ffmpeg: String) {
    // (说明, 阴影偏移, 阴影不透明度, 描边宽度)
    let cases: [(label: String, offset: Double, opacity: Double, outline: Double)] = [
        ("no shadow", 0, 1, 0),
        ("shadow 10, black", 10, 1, 0),
        ("shadow 10, 60% black", 10, 0.6, 0),
        ("outline 3, no shadow", 0, 1, 3),
        ("outline 3 + shadow 3, 60% black", 3, 0.6, 3)
    ]
    var preview: [String: ShadowMeasure] = [:]
    var burned: [String: ShadowMeasure] = [:]
    for item in cases {
        let style = shadowStyle(offset: item.offset, opacity: item.opacity, outline: item.outline)
        guard let previewImage = MainActor.assumeIsolated({ previewOnGray(style) }).flatMap(measure),
              let burnedImage = burnFrame("HHHH", style: style, ffmpeg: ffmpeg, background: "0x808080").flatMap(measure) else {
            check(false, "shadow \(item.label): could not measure the preview or the burned frame")
            return
        }
        preview[item.label] = previewImage
        burned[item.label] = burnedImage
    }

    // 往右下多出来多少：暗处外框的右 / 下边，减去白字外框的右 / 下边。
    func spill(_ measure: ShadowMeasure) -> (x: Int, y: Int) {
        guard let dark = measure.dark else { return (0, 0) }
        return (Int(dark.maxX - measure.text.maxX), Int(dark.maxY - measure.text.maxY))
    }
    for (name, pipeline) in [("preview", preview), ("burn", burned)] {
        guard let none = pipeline["no shadow"], let plain = pipeline["shadow 10, black"], let faint = pipeline["shadow 10, 60% black"],
              let outlined = pipeline["outline 3, no shadow"], let both = pipeline["outline 3 + shadow 3, 60% black"] else { continue }
        check(none.dark == nil, "shadow \(name): white text on grey with no outline and no shadow leaves nothing dark")
        let plainSpill = spill(plain), outlinedSpill = spill(outlined), bothSpill = spill(both)
        check(abs(plainSpill.x - 10) <= 3 && abs(plainSpill.y - 10) <= 3,
              "shadow \(name): a shadow of 10 lands about 10 px right and down of the text (got \(plainSpill.x), \(plainSpill.y))")
        check(plain.darkest <= 10, "shadow \(name): a black shadow is black (darkest \(plain.darkest))")
        // 底是 128、黑色 60% 不透明：暗处最黑的一点约 128 × 0.4 = 51。ASS 的透明度是反的，写反了会得 77。
        check(abs(faint.darkest - 51) <= 8, "shadow \(name): a 60% black shadow darkens the grey to about 51 (got \(faint.darkest))")
        check(bothSpill.x >= outlinedSpill.x + 2 && bothSpill.y >= outlinedSpill.y + 2,
              "shadow \(name): a shadow of 3 sticks out past a 3 px outline (outline alone \(outlinedSpill), with shadow \(bothSpill))")
    }
    // 两条路画得一样：偏出去的量、最黑的一点。
    for label in ["shadow 10, black", "shadow 10, 60% black", "outline 3 + shadow 3, 60% black"] {
        guard let previewed = preview[label], let burnedOne = burned[label] else { continue }
        let a = spill(previewed), b = spill(burnedOne)
        check(abs(a.x - b.x) <= 2 && abs(a.y - b.y) <= 2, "shadow \(label): preview spills \(a), burn spills \(b)")
        check(abs(previewed.darkest - burnedOne.darkest) <= 8, "shadow \(label): darkest point is \(previewed.darkest) in the preview, \(burnedOne.darkest) in the burn")
    }
}
