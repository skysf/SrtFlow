import CoreGraphics
import Foundation
import SrtFlowMCPKit

// look（「看」）的纯值部分：几帧怎么排成格子、拼出来的图有多大、JPEG 真的是 JPEG、每帧的文字描述写了什么、
// 结果里图跟在文字后面（MCP 的 image 内容）。合成时间线画面要真 App，在 GUI 冒烟里看（docs/testing/）。
// 编法见 scripts/check-mcp.sh。

func runLookChecks() {
    checkSheetGrid()
    checkSheetDrawing()
    checkFrameDescription()
    checkImageResult()
}

private func checkSheetGrid() {
    let wide = 16.0 / 9.0, tall = 9.0 / 16.0
    checkEqual(AIContactSheet.grid(count: 1, aspect: wide), .init(columns: 1, rows: 1), "one frame is one tile")
    checkEqual(AIContactSheet.grid(count: 4, aspect: wide), .init(columns: 2, rows: 2), "four wide frames: 2 × 2")
    checkEqual(AIContactSheet.grid(count: 6, aspect: wide), .init(columns: 2, rows: 3), "six wide frames: 2 × 3")
    checkEqual(AIContactSheet.grid(count: 12, aspect: wide), .init(columns: 3, rows: 4), "twelve wide frames: 3 × 4")
    checkEqual(AIContactSheet.grid(count: 6, aspect: tall), .init(columns: 3, rows: 2), "six tall frames: 3 × 2")
    checkEqual(AIContactSheet.grid(count: 12, aspect: tall), .init(columns: 6, rows: 2), "twelve tall frames: 6 × 2")
    for count in 1...12 {
        let grid = AIContactSheet.grid(count: count, aspect: wide)
        check(grid.columns * grid.rows >= count && grid.columns * (grid.rows - 1) < count,
              "\(count) frames fit the grid with no empty row (\(grid))")
    }
}

private func solidFrame(_ width: Int, _ height: Int, gray: Double) -> CGImage? {
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
}

private func checkSheetDrawing() {
    guard let frame = solidFrame(1920, 1080, gray: 0.5), let tall = solidFrame(1080, 1920, gray: 0.5) else {
        check(false, "could not make test frames")
        return
    }
    let single = AIContactSheet.sheet([(label: "1.00s", image: frame)], size: .medium)
    checkEqual(single?.width, 768, "one wide frame: 768 pixels on the long side at medium")
    let four = AIContactSheet.sheet(Array(repeating: (label: "2.00s", image: frame), count: 4), size: .medium)
    checkEqual(four?.width, 1152, "a sheet is 1152 pixels wide at medium")
    let sixTall = AIContactSheet.sheet(Array(repeating: (label: "3.00s", image: tall), count: 6), size: .medium)
    check((sixTall?.height ?? .max) <= Int(1152 * 1.25) + 1, "a sheet of tall frames is at most 1.25 × its width high")
    let jpeg = single.flatMap { AIContactSheet.jpeg($0) }
    check(jpeg?.prefix(2) == Data([0xFF, 0xD8]), "the picture is a JPEG")
    checkEqual(AIContactSheet.scaled(frame, maxSide: 768)?.width, 768, "scaled keeps the long side at the limit")
}

private func checkFrameDescription() {
    var vision = AIVision.Findings()
    vision.labels = [.init(name: "penguin", confidence: 0.9), .init(name: "snow", confidence: 0.6)]
    vision.subject.faces = [CGRect(x: 0.1, y: 0.2, width: 0.05, height: 0.05), CGRect(x: 0.6, y: 0.3, width: 0.2, height: 0.2)]
    vision.texts = ["SOUTH POLE"]
    // 上下各 18 行黑边的亮画面。
    var pixels = [UInt8](repeating: 200, count: 256 * 144)
    for y in 0..<144 where y < 18 || y >= 126 { for x in 0..<256 { pixels[y * 256 + x] = 0 } }
    let luma = AIBlackBars.Luma(width: 256, height: 144, pixels: pixels)
    let described = AIFrameDescription.describe(.init(time: 2.5, luma: luma, vision: vision))
    checkEqual(described["time"]?.doubleValue, 2.5, "the frame's time")
    checkEqual(described["shows"]?.arrayValue?.compactMap(\.stringValue), ["penguin", "snow"], "what Vision says it shows")
    checkEqual(described["faces"]?.arrayValue?.first?.arrayValue?.first?.doubleValue, 0.6, "the biggest face comes first")
    checkEqual(described["text"]?.arrayValue?.first?.stringValue, "SOUTH POLE", "words on screen")
    checkEqual(described["subject"]?["kind"]?.stringValue, "face", "the main subject")
    checkEqual(described["black_bars"]?["top"]?.doubleValue, 0.125, "black bars on the frame")
    checkEqual(described["brightness"]?.doubleValue, 0.59, "average brightness")
    check(described["people"] == nil, "nothing that was not seen is written")
}

private func checkImageResult() {
    var result = AIToolResult.ok(["frames": []])
    result.images = [Data([0xFF, 0xD8, 0xFF])]
    let content = result.json["content"]?.arrayValue ?? []
    checkEqual(content.first?["type"]?.stringValue, "text", "the text comes first")
    checkEqual(content.last?["type"]?.stringValue, "image", "the picture follows as an MCP image")
    checkEqual(content.last?["mimeType"]?.stringValue, "image/jpeg", "the picture is a JPEG")
    checkEqual(content.last?["data"]?.stringValue, "/9j/", "the picture is base64")
    checkEqual(AIToolResult.ok(["a": 1]).json["content"]?.arrayValue?.count, 1, "no picture: text only")
}
