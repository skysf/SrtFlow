import CoreGraphics
import Foundation

// MARK: - 预览上的可点范围（`TextHitGeometry`）
//
// 守的是 docs/architecture/text-overlays.md「预览上点得着哪里」那几条，纯值、不导出：
//
// 1. **看得见的都点得着**：渲染图里每一个不透明的像素都落在可点范围里（按渲染器
//    真画出来的像素量，不是按排版推算 —— 两边的坐标系一个 y 向上、一个 y 向下，
//    推算写反了这里会红）。
// 2. **没选中时不按整框判**：短字（「090」）的可点范围比 80% 宽的版面框窄得多，
//    而且跟着对齐方式走（左 / 中 / 右）。
// 3. 边界：空文字 = 整个版面框（刚 Add 出来还没打字，要点得着）；开着底板时整块底板
//    都算（底板按版面框画，不按墨迹）；数字按定版串算（滚动中可点范围不跳）。

func checkHitGeometry() {
    let canvas = CGSize(width: 1280, height: 720)
    var style = TextStyle.default
    style.fontSize = 120
    style.shadow = nil  // 只量字本身：投影会画到可点范围外面，那是故意的（见架构文档）
    let short = TextOverlay(
        text: "090", timelineStart: 0, centerX: 0.3, centerY: 0.4, boxWidth: 0.8, style: style
    )
    let geometry = TextHitGeometry(short, canvas: canvas)
    let pad = TextHitGeometry.contentPadding

    checkClose(geometry.frame.width, 0.8 * canvas.width, 1, "版面框宽 = 折行宽度")
    check(geometry.frame == TextRenderer.layoutFrame(short, canvas: canvas),
          "可点范围的版面框必须和选中框是同一个（\(geometry.frame) vs \(TextRenderer.layoutFrame(short, canvas: canvas))）")

    // 1. 看得见的都点得着。第二个样本是两行 + 很大的行高：单行的墨迹上下都顶满排版框，
    //    y 轴翻没翻对根本看不出来（2026-09-24 反向验证时单行样本放过了写反的翻转）；
    //    行距拉大之后上下留白不对称，写反了墨迹就会落到可点范围外面。
    var tall = short
    tall.text = "09\n0"
    tall.style.lineSpacing = 2.5
    for sample in [short, tall] {
        let sampleGeometry = TextHitGeometry(sample, canvas: canvas)
        guard let ink = inkRect(sample, canvas: canvas) else {
            check(false, "「\(sample.text)」渲不出来，量不了可点范围")
            continue
        }
        let content = sampleGeometry.contentInFrame
            .offsetBy(dx: sampleGeometry.frame.minX, dy: sampleGeometry.frame.minY)
        check(content.insetBy(dx: -1, dy: -1).contains(ink),
              "渲染出来的字（\(ink)）必须整个落在可点范围（\(content)）里：\(sample.text.debugDescription)")
        // 横向不许白白大出一截：外扩的只有 padding，加上字形两侧的留白。
        check(content.width <= ink.width + 2 * pad + 0.25 * style.fontSize * TextOverlay.pixelScale(canvas: canvas),
              "可点范围横向不该比字宽出一大截（\(content.width) vs 字 \(ink.width)）")
    }

    // 2. 不按整框判，而且跟着对齐走
    check(geometry.contentInFrame.width < geometry.frame.width * 0.3,
          "短字的可点范围该比 80% 宽的版面框窄得多（\(geometry.contentInFrame.width) vs \(geometry.frame.width)）")
    checkClose(geometry.contentInFrame.midX, geometry.frame.width / 2, 2, "居中对齐：可点范围在框的正中")

    var leading = short
    leading.style.alignment = .leading
    checkClose(TextHitGeometry(leading, canvas: canvas).contentInFrame.minX, -pad, 2,
               "左对齐：可点范围贴着版面框的左边")
    var trailing = short
    trailing.style.alignment = .trailing
    let trailingGeometry = TextHitGeometry(trailing, canvas: canvas)
    checkClose(trailingGeometry.contentInFrame.maxX, trailingGeometry.frame.width + pad, 2,
               "右对齐：可点范围贴着版面框的右边")

    // 3. 边界
    let blank = TextOverlay(text: "", timelineStart: 0, style: style)
    let blankGeometry = TextHitGeometry(blank, canvas: canvas)
    checkEqual(blankGeometry.contentInFrame, CGRect(origin: .zero, size: blankGeometry.frame.size),
               "空文字的可点范围 = 整个版面框")

    var plated = short
    plated.style.background = .default
    let plateGeometry = TextHitGeometry(plated, canvas: canvas)
    check(plateGeometry.contentInFrame.minX < 0 && plateGeometry.contentInFrame.maxX > plateGeometry.frame.width,
          "开着底板时可点范围要把整块底板包进去（底板按版面框画、四周还有内边距）：\(plateGeometry.contentInFrame)")

    var rolling = short
    rolling.text = ""
    rolling.number = NumberRoll(
        from: 365, to: 90, fractionDigits: 0, groupsThousands: false,
        prefix: "", suffix: "", style: .odometer, duration: 1.7
    )
    let settled = TextHitGeometry(rolling, canvas: canvas)
    var asText = short
    asText.text = "365"
    checkClose(settled.contentInFrame.width, TextHitGeometry(asText, canvas: canvas).contentInFrame.width, 1,
               "数字按定版串（from / to 里更长的那个）算可点范围，滚动中不跳")
}

/// 渲染图里不透明像素的外接框，换算到画布坐标（左上原点）。
private func inkRect(_ overlay: TextOverlay, canvas: CGSize) -> CGRect? {
    guard let rendered = TextRenderer.render(overlay, canvas: canvas),
          let mask = alphaMask(rendered.image) else { return nil }
    var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
    for y in 0..<mask.height {
        for x in 0..<mask.width where mask.alpha[y * mask.width + x] > 24 {
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
        }
    }
    guard maxX >= 0 else { return nil }
    return CGRect(
        x: rendered.origin.x + Double(minX), y: rendered.origin.y + Double(minY),
        width: Double(maxX - minX + 1), height: Double(maxY - minY + 1)
    )
}
