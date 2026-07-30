import AppKit

// SrtFlow 图标生成器（仅需 Command Line Tools）：
//   swift scripts/make-icon.swift packaging/SrtFlow.iconset
// 然后用 iconutil 合成 icns（build-app.sh 已自动完成）。
//
// 有 packaging/icon-source-1024.png 就用它，否则退回下面用代码画的那版。

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "packaging/SrtFlow.iconset"
try! FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// MARK: - 用设计好的 PNG 作为图标源

/// 成品 PNG 里，圆角方块本身的位置和圆角半径（1024 画布，左上角为原点）。
///
/// 量出来的：方块 834×834，左上角 (94, 87)，圆角半径 200。
/// 这些数字是必须的 —— 那张图是**不带透明通道**的，圆角外面是接近白的底色。
/// 直接拿去当图标，Dock 和 Finder 里就是一个白方块。所以要按这个圆角形状抠出来。
private enum IconSource {
    static let path = "packaging/icon-source-1024.png"

    static let canvas: CGFloat = 1024
    /// 源图里圆角方块的范围（左上原点坐标系）。
    static let artOrigin = CGPoint(x: 94, y: 87)
    static let artSide: CGFloat = 834
    static let artCornerRadius: CGFloat = 200

    /// macOS 图标栅格：1024 画布里内容占 824×824、四周留 100 透明边。
    static let targetInset: CGFloat = 100
    static var targetSide: CGFloat { canvas - targetInset * 2 }
    /// 圆角比例照源图来（0.24），比 Apple 栅格的 0.225 更圆一点 ——
    /// 这样裁切线正好落在源图自己的圆角上，不会在四角漏出白底。
    static var targetCornerRadius: CGFloat { targetSide * (artCornerRadius / artSide) }

    static func load() -> NSImage? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return NSImage(contentsOfFile: path)
    }
}

/// 把源图里的圆角方块搬进标准栅格，并把圆角外面清成透明。
func drawIconFromSource(_ source: NSImage, pixels: Int) -> NSBitmapImageRep {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    let unit = size / IconSource.canvas
    let target = NSRect(
        x: IconSource.targetInset * unit,
        y: IconSource.targetInset * unit,
        width: IconSource.targetSide * unit,
        height: IconSource.targetSide * unit
    )

    // 往里收半个像素：边界上的抗锯齿像素属于源图的浅色底，留着会是一圈白边。
    let clipInset = 0.5 * unit
    let clip = NSBezierPath(
        roundedRect: target.insetBy(dx: clipInset, dy: clipInset),
        xRadius: IconSource.targetCornerRadius * unit,
        yRadius: IconSource.targetCornerRadius * unit
    )
    clip.addClip()

    // NSImage 的坐标系原点在左下，源图的量测值是左上原点，这里换算一次。
    let sourceRect = NSRect(
        x: IconSource.artOrigin.x,
        y: IconSource.canvas - IconSource.artOrigin.y - IconSource.artSide,
        width: IconSource.artSide,
        height: IconSource.artSide
    )
    source.draw(in: target, from: sourceRect, operation: .sourceOver, fraction: 1)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let specs: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
]

/// 退路：没有源 PNG 时用代码画一版。
/// 设计：macOS 圆角方块，蓝色纵向渐变，三条居中的白色圆角长条模拟字幕文本行。
func drawIcon(pixels: Int) -> NSBitmapImageRep {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let unit = size / 1024

    // 背景：圆角方块（macOS 标准：内容区约 824/1024，圆角约 22.5%）
    let inset = 100 * unit
    let shapeRect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let shape = NSBezierPath(roundedRect: shapeRect, xRadius: 186 * unit, yRadius: 186 * unit)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0x4C / 255, green: 0x9A / 255, blue: 0xF5 / 255, alpha: 1),
        NSColor(calibratedRed: 0x1E / 255, green: 0x4F / 255, blue: 0xD8 / 255, alpha: 1),
    ])!
    gradient.draw(in: shape, angle: -90)

    // 字幕条：三条居中胶囊，宽度不一（像居中对齐的字幕文本块）
    let barHeight = 96 * unit
    let bars: [(width: CGFloat, centerY: CGFloat)] = [
        (500 * unit, 620 * unit),
        (640 * unit, 512 * unit),
        (520 * unit, 404 * unit),
    ]
    NSColor.white.withAlphaComponent(0.96).setFill()
    for bar in bars {
        let rect = NSRect(
            x: (size - bar.width) / 2,
            y: bar.centerY - barHeight / 2,
            width: bar.width,
            height: barHeight
        )
        NSBezierPath(roundedRect: rect, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let source = IconSource.load()
if source == nil {
    print("note: \(IconSource.path) 不存在，用代码画的图标")
}

for spec in specs {
    let rep = source.map { drawIconFromSource($0, pixels: spec.pixels) } ?? drawIcon(pixels: spec.pixels)
    let data = rep.representation(using: .png, properties: [:])!
    let path = "\(outDir)/\(spec.name).png"
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}
