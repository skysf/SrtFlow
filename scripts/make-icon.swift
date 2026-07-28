import AppKit

// SrtFlow 图标生成器（仅需 Command Line Tools）：
//   swift scripts/make-icon.swift packaging/SrtFlow.iconset
// 然后用 iconutil 合成 icns（build-app.sh 已自动完成）。
//
// 设计：macOS 圆角方块，蓝色纵向渐变（自上而下，"流动"感），
// 三条居中的白色圆角长条模拟字幕文本行——长、短、中，简约扁平。

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "packaging/SrtFlow.iconset"
try! FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

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

for spec in specs {
    let rep = drawIcon(pixels: spec.pixels)
    let data = rep.representation(using: .png, properties: [:])!
    let path = "\(outDir)/\(spec.name).png"
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}
