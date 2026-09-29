import AppKit
import CoreGraphics
import Foundation
import ImageIO

// 窗口截图里的各条断言（窗口搭法见 main.swift）。

/// 一张截图：读成 RGB 字节，按面板算坐标。
struct Shot {
    let width: Int
    let height: Int
    let bytes: [UInt8]
    /// 截图相对窗口（点）放大了几倍（视网膜屏是 2）。
    let scale: Double

    init?(_ url: URL) {
        guard let data = try? Data(contentsOf: url), let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var raw = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(data: &raw, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        width = image.width
        height = image.height
        bytes = raw
        scale = Double(image.width) / (panelWidth * Double(columns) + gap * Double(columns + 1))
    }

    func rgb(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let i = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }

    /// 第 i 块面板在截图里的左上角和大小（像素）。
    func panel(_ index: Int) -> (x: Int, y: Int, width: Int, height: Int) {
        let col = index % columns, row = index / columns
        return (Int((gap + (panelWidth + gap) * Double(col)) * scale), Int((gap + (panelHeight + gap) * Double(row)) * scale),
                Int(panelWidth * scale), Int(panelHeight * scale))
    }

    /// 面板里一点（0…1 归一化）的颜色。
    func at(_ index: Int, _ fx: Double, _ fy: Double, dx: Double = 0, dy: Double = 0) -> (r: Int, g: Int, b: Int) {
        let p = panel(index)
        return rgb(p.x + Int(fx * Double(p.width) + dx * scale), p.y + Int(fy * Double(p.height) + dy * scale))
    }

    func difference(_ a: (r: Int, g: Int, b: Int), _ b: (r: Int, g: Int, b: Int)) -> Int {
        max(abs(a.r - b.r), max(abs(a.g - b.g), abs(a.b - b.b)))
    }
}

/// 面板里一条线上（横或竖）颜色跳变的位置（点，相对 `origin`），跳变 = 相邻像素某个通道差 ≥ `minimum`。
private func jumps(_ shot: Shot, panel index: Int, horizontal: Bool, at fraction: Double, from: Double, to: Double, origin: Double, minimum: Int = 3) -> [Double] {
    let p = shot.panel(index)
    var result: [Double] = []
    var previous: (r: Int, g: Int, b: Int)?
    let start = Int(from * Double(horizontal ? p.width : p.height)), end = Int(to * Double(horizontal ? p.width : p.height))
    for i in start...end {
        let current = horizontal
            ? shot.rgb(p.x + i, p.y + Int(fraction * Double(p.height)))
            : shot.rgb(p.x + Int(fraction * Double(p.width)), p.y + i)
        if let previous, shot.difference(previous, current) >= minimum {
            result.append(Double(i) / shot.scale - origin)
        }
        previous = current
    }
    return result
}

func runAssertions(first: Shot, second: Shot) {
    let w = { (i: Int) in Double(first.panel(i).width) / first.scale }, h = { (i: Int) in Double(first.panel(i).height) / first.scale }
    // 0. 素材本身：左红右蓝，交界在正中且是硬的。
    let left = first.at(0, 0.5, 0.5, dx: -4), right = first.at(0, 0.5, 0.5, dx: 4)
    check(left.r - left.b > 100 && right.b - right.r > 100, "参照：左红右蓝、交界是硬的 \(left) \(right)")

    // 1. 模糊：块里的交界是混色，块外的交界还是硬的。
    let mixed = first.at(1, 0.5, 0.5)
    check(min(mixed.r, mixed.b) >= 45, "盖上的那块里，红蓝交界被糊成混色：\(mixed)")
    let aboveLeft = first.at(1, 0.5, 0.1, dx: -3), aboveRight = first.at(1, 0.5, 0.1, dx: 3)
    check(aboveLeft.r - aboveLeft.b > 100 && aboveRight.b - aboveRight.r > 100, "块的上方，交界还是硬的：\(aboveLeft) \(aboveRight)")
    // 改动的范围：交界左边 6 点的那一列，被改的行 = 这一块的上下沿（±2 点）。
    let p1 = first.panel(1), p0 = first.panel(0)
    var top: Int?, bottom: Int?
    for y in 0..<p1.height {
        let a = first.rgb(p1.x + p1.width / 2 - Int(6 * first.scale), p1.y + y), b = first.rgb(p0.x + p0.width / 2 - Int(6 * first.scale), p0.y + y)
        if first.difference(a, b) > 20 { top = top ?? y; bottom = y }
    }
    if let top, let bottom {
        check(abs(Double(top) / first.scale - regionA.minY * h(1)) <= 2 && abs(Double(bottom + 1) / first.scale - regionA.maxY * h(1)) <= 2,
              "改动的行是这一块的上下沿（\(Double(top) / first.scale)…\(Double(bottom + 1) / first.scale) 点，应当是 \(regionA.minY * h(1))…\(regionA.maxY * h(1))）")
    } else {
        check(false, "块里没有找到被改的像素")
    }

    // 2. 调色 + 模糊：块里离交界远的地方，和「只调色」的参照一样；和没调色的参照不一样（这条断言才有意义）。
    let gradedCover = first.at(2, 0.33, 0.5), gradedOnly = first.at(3, 0.33, 0.5), plain = first.at(0, 0.33, 0.5)
    check(first.difference(gradedCover, gradedOnly) <= 14, "调色 + 盖一块：块里的颜色和只调色一样（这一层带上了调色）：\(gradedCover) 对 \(gradedOnly)")
    check(first.difference(gradedOnly, plain) > 12, "冷铁真的改了颜色（不然上一条什么都没证明）：\(gradedOnly) 对 \(plain)")

    // 3. 马赛克：格线落在这一块的左上角 + k × 12 点（水平）/ 上边 + k × 12 点（竖直）。
    let regionLeft = regionA.minX * w(4), regionTop = regionA.minY * h(5)
    let horizontal = jumps(first, panel: 4, horizontal: true, at: 0.4, from: 0.3, to: 0.68, origin: regionLeft)
    check(horizontal.count >= 4 && horizontal.prefix(5).allSatisfy { abs(($0 / 12).rounded() * 12 - $0) <= 1.2 },
          "马赛克的水平格线从这一块的左边起、每 12 点一条：\(horizontal.map { ($0 * 10).rounded() / 10 })")
    let vertical = jumps(first, panel: 5, horizontal: false, at: 0.5, from: 0.12, to: 0.58, origin: regionTop)
    check(vertical.count >= 3 && vertical.prefix(4).allSatisfy { abs(($0 / 12).rounded() * 12 - $0) <= 1.2 },
          "马赛克的竖直格线从这一块的上边起、每 12 点一条（不是从下边）：\(vertical.map { ($0 * 10).rounded() / 10 })")

    // 4. 两块同时盖（0.35…0.65 × 0.1…0.4 和 0.4…0.7 × 0.6…0.9），两块之间的交界还是硬的。
    let upper = first.at(6, 0.5, 0.25), lower = first.at(6, 0.5, 0.75)
    check(min(upper.r, upper.b) >= 45 && min(lower.r, lower.b) >= 45, "两块都糊了：\(upper) \(lower)")
    let between1 = first.at(6, 0.5, 0.5, dx: -3), between2 = first.at(6, 0.5, 0.5, dx: 3)
    check(between1.r - between1.b > 100 && between2.b - between2.r > 100, "两块之间的交界没被糊：\(between1) \(between2)")

    // 5. 撤掉：第一拍里面板 7 是糊的，第二拍（撤掉之后）和参照一样。
    let before = first.at(7, 0.5, 0.5), after = second.at(7, 0.5, 0.5), reference = second.at(8, 0.5, 0.5)
    check(min(before.r, before.b) >= 45, "面板 7 的第一拍是糊的：\(before)")
    check(second.difference(after, reference) <= 20 && min(after.r, after.b) < 45, "盖一块撤掉之后画面回到和参照一样：\(after) 对 \(reference)")
}
