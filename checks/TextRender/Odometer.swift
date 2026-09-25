import CoreGraphics
import Foundation

// 第 13b 组：老虎机的首帧就是起始值、末帧就是终值（2026-09-25）。
//
// 现场：365 → 90 停在「090」上 —— 定版串按位数多的 365 排了三格，终值 90 没有百位，那一格
// 照样画成 0。同一个毛病还让 0 → 4,827 起步是「0,000」、$1,299 → $999 落在「$0,999」上、
// -5 → 10 落在「-0」上（docs/bugfixes/2026-09-25-odometer-leading-zero.md）。
//
// 参照物是**一直停在那个值上的数字**（from = to）：和被测的走同一条数字排版、同一个渲染函数。
// 拿普通文字当参照，量的是字体版本的巧合（docs/bugfixes/2026-09-25-pr71-first-ci-run.md）。
// 比的是渲染图本身：墨迹落在画布的哪一块，左 / 右对齐时再逐像素比不透明度。
//
// 位数变了的时候谁不动：左对齐左边不动、右对齐右边不动 —— 和停着的数字一模一样；**居中的右边
// 不动**（个位那一轮不横着挪，后面紧跟的「°」才贴得住），所以居中时参照物要往右挪「两头行宽
// 之差的一半」（`TextTypesetter.placeCollapsing`）。

func checkOdometerEndpoints() {
    // 1. 用户的现场：居中、千分位开着、带字距。
    var user = odometerTitle(from: 365, to: 90)
    user.style.letterSpacing = 17
    matchesParked(user, at: .end, "365 → 90 末帧（以前是「090」）")
    unitsStayPut(user, "365 → 90 居中")
    matchesParked(user, at: .start, "365 → 90 首帧")
    matchesParked(odometerTitle(from: 90, to: 365), at: .start, "90 → 365 首帧（以前是「090」）")
    matchesParked(odometerTitle(from: 365, to: 90, alignment: .leading), at: .end, "左对齐 365 → 90 末帧")
    matchesParked(odometerTitle(from: 365, to: 90, alignment: .trailing), at: .end, "右对齐 365 → 90 末帧")

    // 2. 差不止一位、千分位逗号、前缀、负号、小数。
    matchesParked(odometerTitle(from: 0, to: 4827), at: .start, "0 → 4,827 首帧（以前是「0,000」）")
    matchesParked(odometerTitle(from: 0, to: 4827), at: .end, "0 → 4,827 末帧")
    let price = odometerTitle(from: 1299, to: 999, prefix: "$")
    matchesParked(price, at: .end, "$1,299 → $999 末帧：逗号跟着千位走掉，前缀贴过来")
    matchesParked(odometerTitle(from: 100, to: 5), at: .end, "100 → 5 末帧（十位行程为 0，要多走一格才滚得成空白）")
    matchesParked(odometerTitle(from: -5, to: 10), at: .end, "-5 → 10 末帧（以前是「-0」）")
    matchesParked(odometerTitle(from: -5, to: 10), at: .start, "-5 → 10 首帧")
    matchesParked(odometerTitle(from: 10, to: -5), at: .end, "10 → -5 末帧")
    matchesParked(odometerTitle(from: 0.5, to: 12.25, fractionDigits: 2), at: .start, "0.50 → 12.25 首帧")
    // 左 / 右对齐的参照物不用挪，逐像素比得上：逗号、负号、空白格的画法都在这几条里。
    matchesParked(odometerTitle(from: 1299, to: 999, prefix: "$", alignment: .trailing), at: .end,
                  "右对齐 $1,299 → $999 末帧")
    matchesParked(odometerTitle(from: 1299, to: 999, prefix: "$", alignment: .leading), at: .end,
                  "左对齐 $1,299 → $999 末帧")
    matchesParked(odometerTitle(from: 0, to: 4827, alignment: .trailing), at: .start, "右对齐 0 → 4,827 首帧")
    matchesParked(odometerTitle(from: -5, to: 10, alignment: .leading), at: .start, "左对齐 -5 → 10 首帧")
    matchesParked(odometerTitle(from: -5, to: 10, alignment: .leading), at: .end, "左对齐 -5 → 10 末帧")

    // 3. 位数没变的滚动：没有空白格、一格都不收（和以前一格不差）。
    let steady = NumberOdometer(NumberRoll(
        from: 4827, to: 9000, fractionDigits: 0, groupsThousands: true,
        prefix: "", suffix: "", style: .odometer, duration: 1.5
    ))
    check((0...15).allSatisfy { steady.frame(local: Double($0) * 0.1).widths.isEmpty },
          "4,827 → 9,000：位数没变，任何时刻都不该有收窄的格子")

    // 4. 定版串：两头符号不同时不许漏位；前后缀里的数字、句点不是位槽。
    let mixed = NumberRoll(from: -12, to: 345, fractionDigits: 0, groupsThousands: true,
                           prefix: "", suffix: "", style: .odometer, duration: 1)
    checkEqual(mixed.settledText, "-345", "-12 → 345 的定版串要有负号和三位（以前取了「-12」，终点画成「-45」）")
    let labelled = NumberOdometer(NumberRoll(
        from: 5, to: 20, fractionDigits: 0, groupsThousands: true,
        prefix: "No.1 ", suffix: " m2", style: .odometer, duration: 1
    ))
    checkEqual(labelled.digitPlaces.values.sorted(), [0, 1],
               "前后缀里的「1」「2」「.」不是位槽，只有 20 的两位是")

    checkOdometerRolling(user)
}

/// 居中时，每一位的字形**全程**停在定版串里它那一格上（排版坐标，横向一动不动）——
/// 包括正在滚走的那一位：它是原地滚走的，不往邻居身上蹭（第一版蹭过去半截，像个逗号）。
private func unitsStayPut(_ overlay: TextOverlay, _ label: String) {
    guard let number = overlay.number else { return }
    let odometer = NumberOdometer(number)
    let settled = TextTypesetter.layout(overlay, canvas: canvas, text: overlay.settledText)
    var worst = (drift: 0.0, place: 0, local: 0.0)
    for frame in 0...Int(((number.settleTime + 0.2) * 30).rounded()) {
        let local = Double(frame) / 30
        let layout = odometerFrameLayout(overlay, local: local)
        for (offset, place) in odometer.digitPlaces {
            let before = settled.lines.first?.glyphs.first { $0.characterIndex == offset }?.position.x ?? 0
            let now = layout.lines.first?.glyphs.first { $0.characterIndex == offset }?.position.x ?? -1000
            if abs(now - before) > worst.drift { worst = (abs(now - before), place, local) }
        }
    }
    check(worst.drift < 0.01,
          "\(label)：每一位全程不许横着挪，第 \(worst.place) 位在 \(worst.local)s 挪了 \(worst.drift)")
}

/// 滚动中：位图尺寸和落点全程固定；右边一动不动，一位收起来时左边是一点点收过去的，不是跳过去的。
private func checkOdometerRolling(_ overlay: TextOverlay) {
    guard let number = overlay.number else { return }
    var sizes: Set<String> = []
    var origins: Set<String> = []
    var lineStarts: [Double] = []
    var lineEnds: [Double] = []
    let fps = 30.0
    for frame in 0...Int(((number.settleTime + 0.2) * fps).rounded()) {
        let state = TextAnimator.state(for: overlay, at: Double(frame) / fps, canvas: canvas, frameRate: .fps30)
        if let rendered = TextRenderer.render(overlay, canvas: canvas, state: state) {
            sizes.insert("\(rendered.size)")
            origins.insert("\(rendered.origin)")
        }
        let line = odometerFrameLayout(overlay, local: Double(frame) / fps).lines.first
        lineStarts.append(line?.originX ?? 0)
        lineEnds.append((line?.originX ?? 0) + (line?.width ?? 0))
    }
    checkEqual(sizes.count, 1, "老虎机滚动期间位图尺寸必须只有一种（位数变了也不许变）")
    checkEqual(origins.count, 1, "老虎机滚动期间贴图落点必须只有一个")

    // 一格 = 两头停着时的行宽之差（365 比 90 多一格）。
    let cell = abs((lineWidth(overlay, value: number.from) ?? 0) - (lineWidth(overlay, value: number.to) ?? 0))
    let moved = abs((lineStarts.last ?? 0) - (lineStarts.first ?? 0))
    let steepest = zip(lineStarts, lineStarts.dropFirst()).map { abs($1 - $0) }.max() ?? 0
    check(cell > 10, "用例本身：365 和 90 要差出一格来（实际 \(cell)）")
    check((lineEnds.max() ?? 0) - (lineEnds.min() ?? 0) < 0.01,
          "居中的 365 → 90：右边全程一动不动，实际在 \(lineEnds.min() ?? 0)…\(lineEnds.max() ?? 0) 之间")
    checkClose(moved, cell, 0.5, "居中的 365 → 90：左边最后收进一整格（百位收掉了）")
    check(steepest < cell * 0.3,
          "一位收起来时要一点点收过去，一帧最多挪 \(steepest)，超过了三成格（\(cell * 0.3)）")
}

/// 这一刻真要画的那份排版 —— 和 `TextRenderer.render` 同一个调用。
private func odometerFrameLayout(_ overlay: TextOverlay, local: Double) -> TextLayout {
    let state = TextAnimator.state(
        for: overlay, at: overlay.timelineStart + local, canvas: canvas, frameRate: .fps30
    )
    return TextTypesetter.layout(
        overlay, canvas: canvas, text: overlay.settledText, widths: state.odometer?.widths ?? [:]
    )
}

private enum OdometerMoment { case start, end }

/// 一段只有数字的白字：从 0 秒开始，等 0.2 秒、滚 1.5 秒。
private func odometerTitle(
    from: Double, to: Double, fractionDigits: Int = 0, prefix: String = "",
    alignment: TextBlockAlignment = .center
) -> TextOverlay {
    var overlay = whiteTitle(start: 0, duration: 4, text: "")
    overlay.style.alignment = alignment
    overlay.number = NumberRoll(
        from: from, to: to, fractionDigits: fractionDigits, groupsThousands: true,
        prefix: prefix, suffix: "", style: .odometer, duration: 1.5, delay: 0.2
    )
    return overlay
}

/// 这一刻的渲染图，与一直停在那一头的值上的数字（from = to）比：墨迹落在哪一块（居中时参照物往右
/// 挪两头行宽之差的一半），左 / 右对齐时再逐像素比。
private func matchesParked(_ overlay: TextOverlay, at moment: OdometerMoment, _ label: String) {
    guard let number = overlay.number else { return }
    let local = moment == .start ? 0 : number.settleTime + 0.5
    let value = moment == .start ? number.from : number.to
    var parked = overlay
    parked.number?.from = value
    parked.number?.to = value
    let shift = overlay.style.alignment == .center
        ? ((lineWidth(overlay, value: nil) ?? 0) - (lineWidth(overlay, value: value) ?? 0)) / 2
        : 0
    guard let actual = odometerRender(overlay, local: local),
          let expected = odometerRender(parked, local: local) else {
        check(false, "\(label)：渲不出来")
        return
    }
    guard let actualInk = inkBox(actual), let expectedInk = inkBox(expected)?.offsetBy(dx: shift, dy: 0) else {
        check(false, "\(label)：没有墨迹")
        return
    }
    let edges = [actualInk.minX - expectedInk.minX, actualInk.maxX - expectedInk.maxX,
                 actualInk.minY - expectedInk.minY, actualInk.maxY - expectedInk.maxY]
    check(edges.allSatisfy { abs($0) <= 1 },
          "\(label)：墨迹要落在停着的数字那一块上（实际 \(actualInk)，期望 \(expectedInk)）")
    guard shift == 0 else { return }  // 挪了零点几个像素的参照物没法逐像素比
    let differing = differingPixels(actual, expected)
    check(differing <= 4, "\(label)：和停着的数字逐像素比，有 \(differing) 个像素差得明显")
}

private func odometerRender(_ overlay: TextOverlay, local: Double) -> RenderedText? {
    let state = TextAnimator.state(
        for: overlay, at: overlay.timelineStart + local, canvas: canvas, frameRate: .fps30
    )
    return TextRenderer.render(overlay, canvas: canvas, state: state)
}

/// 停在某个值上时的行宽（排版像素）；`value` 为 nil 时是定版串的行宽。
private func lineWidth(_ overlay: TextOverlay, value: Double?) -> Double? {
    var parked = overlay
    if let value {
        parked.number?.from = value
        parked.number?.to = value
    }
    return TextTypesetter.layout(parked, canvas: canvas, text: parked.settledText).lines.first?.width
}

/// 不透明像素的外接框，画布坐标（左上原点）。
private func inkBox(_ rendered: RenderedText) -> CGRect? {
    guard let mask = alphaMask(rendered.image) else { return nil }
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
    return CGRect(x: rendered.origin.x + Double(minX), y: rendered.origin.y + Double(minY),
                  width: Double(maxX - minX + 1), height: Double(maxY - minY + 1))
}

/// 两张渲染图在画布上逐像素比，不透明度差超过 1/4 的像素有几个。
private func differingPixels(_ a: RenderedText, _ b: RenderedText) -> Int {
    guard let maskA = alphaMask(a.image), let maskB = alphaMask(b.image) else { return Int.max }
    func alpha(_ mask: (width: Int, height: Int, alpha: [UInt8]), origin: CGPoint, x: Int, y: Int) -> Int {
        let localX = x - Int(origin.x)
        let localY = y - Int(origin.y)
        guard localX >= 0, localY >= 0, localX < mask.width, localY < mask.height else { return 0 }
        return Int(mask.alpha[localY * mask.width + localX])
    }
    let minX = Int(min(a.origin.x, b.origin.x))
    let minY = Int(min(a.origin.y, b.origin.y))
    let maxX = Int(max(a.origin.x + Double(maskA.width), b.origin.x + Double(maskB.width)))
    let maxY = Int(max(a.origin.y + Double(maskA.height), b.origin.y + Double(maskB.height)))
    var count = 0
    for y in minY..<maxY {
        for x in minX..<maxX
        where abs(alpha(maskA, origin: a.origin, x: x, y: y) - alpha(maskB, origin: b.origin, x: x, y: y)) > 64 {
            count += 1
        }
    }
    return count
}
