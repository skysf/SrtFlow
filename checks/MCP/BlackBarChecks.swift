import CoreGraphics
import Foundation

// 去黑边（AIBlackBars）：遮幅、柱边、暗场、夜空里的星星、遮幅里压着字幕、几帧合起来取最小，
// 以及真画一张 CGImage 读回来 —— 第一行必须是画面最上面一行（上下弄反了就裁错边）。
// 编法见 scripts/check-mcp.sh。

func runBlackBarChecks() {
    checkLetterboxAndPillarbox()
    checkDarkFramesAndStars()
    checkSubtitleInsideBar()
    checkCombineTakesTheSmallest()
    checkLumaIsTopDown()
}

/// 造一帧：`width`×`height`，`bright(x, y)` 为真的地方是亮的内容（带点起伏），其余是带噪点的黑。
private func frame(_ width: Int, _ height: Int, bright: (Int, Int) -> Bool) -> AIBlackBars.Luma {
    var pixels = [UInt8](repeating: 0, count: width * height)
    for y in 0..<height {
        for x in 0..<width {
            pixels[y * width + x] = bright(x, y) ? UInt8(60 + (x * 7 + y * 13) % 180) : UInt8((x + y) % 12)
        }
    }
    return AIBlackBars.Luma(width: width, height: height, pixels: pixels)
}

private func rounded(_ value: Double?) -> Double? {
    value.map { ($0 * 1000).rounded() / 1000 }
}

private func checkLetterboxAndPillarbox() {
    let letterbox = AIBlackBars.bars(in: frame(256, 144) { _, y in y >= 18 && y < 126 })
    checkEqual(rounded(letterbox?.top), 0.125, "a letterbox's top bar is found")
    checkEqual(rounded(letterbox?.bottom), 0.125, "a letterbox's bottom bar is found")
    checkEqual(letterbox?.left, 0, "a letterbox has no side bars")
    let pillarbox = AIBlackBars.bars(in: frame(256, 144) { x, _ in x >= 32 && x < 224 })
    checkEqual(rounded(pillarbox?.left), 0.125, "a pillarbox's left bar is found")
    checkEqual(rounded(pillarbox?.right), 0.125, "a pillarbox's right bar is found")
    checkEqual(pillarbox?.top, 0, "a pillarbox has no top bar")
    let full = AIBlackBars.bars(in: frame(256, 144) { _, _ in true })
    checkEqual(full, AIBlackBars.Insets.none, "a full picture has no bars")
    check(full?.isEmpty == true, "no bars is empty")
    // 边上一个像素宽的黑线（编码器留的）：不到半个百分点，不算黑边。
    let hairline = AIBlackBars.bars(in: frame(256, 400) { _, y in y >= 1 })
    checkEqual(hairline?.top, 0, "a one-pixel line at the edge is not a bar")
}

private func checkDarkFramesAndStars() {
    // 淡入淡出、黑场：整帧都黑，这一帧不算数。
    checkEqual(AIBlackBars.bars(in: frame(256, 144) { _, _ in false }), nil, "an all-black frame does not count")
    // 夜空：上面一片很暗，但有几颗亮星 —— 最亮的点过了线，不是遮幅。
    let night = AIBlackBars.bars(in: frame(256, 144) { x, y in y >= 40 || (x % 50 == 7 && y % 9 == 0) })
    checkEqual(night?.top, 0, "a dark sky with stars is not a letterbox bar")
}

private func checkSubtitleInsideBar() {
    // 字幕烧在下面的遮幅里（第 132–135 行有白字）：扫到字就停，字那几行留着。
    let subtitled = AIBlackBars.bars(in: frame(256, 144) { x, y in
        (y >= 18 && y < 126) || (y >= 132 && y < 136 && x >= 80 && x < 176)
    })
    checkEqual(rounded(subtitled?.bottom), rounded(8.0 / 144), "a bar with burned-in subtitles stops at the text")
}

private func checkCombineTakesTheSmallest() {
    let wide = AIBlackBars.Insets(top: 0.125, bottom: 0.125, left: 0, right: 0)
    let narrow = AIBlackBars.Insets(top: 0.05, bottom: 0.2, left: 0, right: 0)
    let combined = AIBlackBars.combine([wide, nil, narrow])
    checkEqual(combined, AIBlackBars.Insets(top: 0.05, bottom: 0.125, left: 0, right: 0),
               "several frames: each edge takes the smallest bar, frames that do not count are skipped")
    checkEqual(AIBlackBars.combine([nil, nil]), nil, "no frame that counts: cannot tell")
    let active = AIBlackBars.Insets(top: 0.1, bottom: 0.2, left: 0.05, right: 0).active
    check(abs(active.minY - 0.1) < 1e-9 && abs(active.height - 0.7) < 1e-9 && abs(active.width - 0.95) < 1e-9,
          "the usable area is what the bars leave (\(active))")
}

/// 真画一张：上面 12 行黑、下面 4 行黑（故意不对称）。读回来要是上下反了，这里当场红。
private func checkLumaIsTopDown() {
    let width = 64, height = 36
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        check(false, "could not make a test image")
        return
    }
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    // CG 的原点在左下：y 4…24 是「从下往上数」的第 4 到 24 行 = 下面留 4 行、上面留 12 行。
    context.fill(CGRect(x: 0, y: 4, width: width, height: 20))
    guard let image = context.makeImage(), let luma = AIBlackBars.luma(of: image, maxSide: 64) else {
        check(false, "could not read the test image back")
        return
    }
    let bars = AIBlackBars.bars(in: luma)
    checkEqual(rounded(bars?.top), rounded(12.0 / 36), "the image's top rows are the luma's first rows")
    checkEqual(rounded(bars?.bottom), rounded(4.0 / 36), "the image's bottom rows are the luma's last rows")
}
