import Foundation

// 数字元件的纯值合同（从 main.swift 拆出来，那个文件登记过超标、只许降）：
// 第 11 组 —— 格式化不跟系统区域走；第 16b 组 —— 等待（`NumberRoll.delay`，2026-09-24）。
// 合同见 docs/architecture/text-overlays.md「数字元件」。

/// 第 11 组：无区域依赖、定点、千分位。
///
/// 成片是文件：同一份工程在不同区域设置的机器上必须渲出一模一样的画面。
/// 所以格式化是自己写死的，不走 `NumberFormatter`。
func checkNumberFormatting() {
    //
    // 成片是文件：同一份工程在不同区域设置的机器上必须渲出一模一样的画面。
    // 所以格式化是自己写死的，不走 `NumberFormatter`。

    checkEqual(NumberRoll.format(1234567, fractionDigits: 0, groupsThousands: true),
               "1,234,567", "千分位按三位分组")
    checkEqual(NumberRoll.format(1234567, fractionDigits: 0, groupsThousands: false),
               "1234567", "关掉千分位就不分组")
    checkEqual(NumberRoll.format(1234.5, fractionDigits: 2, groupsThousands: true),
               "1,234.50", "小数位不足要补零")
    checkEqual(NumberRoll.format(-42.125, fractionDigits: 2, groupsThousands: true),
               "-42.13", "负数与四舍五入")
    checkEqual(NumberRoll.format(999.999, fractionDigits: 2, groupsThousands: true),
               "1,000.00", "进位要带着整数部分一起进（不能出 999.100）")
    checkEqual(NumberRoll.format(0, fractionDigits: 0, groupsThousands: true),
               "0", "零")
    checkEqual(NumberRoll.format(1000, fractionDigits: 0, groupsThousands: true),
               "1,000", "刚好四位时也要分组")
    checkEqual(NumberRoll.format(100, fractionDigits: 0, groupsThousands: true),
               "100", "三位不分组")
}

/// 第 12–15 组：数值插值终点精确、老虎机每一位收口、等宽数字、滚动期间位图尺寸落点不变。
/// （从 main.swift 搬出来，那个文件登记过超标、只许降；断言原样。）
func checkNumberRolling() {
    // MARK: 12 —— 数值插值：终点精确落在终值上
    //
    // 缓动收尾很容易差最后一点点，而"数到 99,999 而不是 100,000"是最扎眼的
    // 一种错。判据取**显示串**而不是数值 —— 用户看到的是串。

    var counting = whiteTitle(start: 2, duration: 5)
    counting.number = NumberRoll(
        from: 0, to: 1234, fractionDigits: 0, groupsThousands: true,
        prefix: "", suffix: "", style: .count, duration: 2
    )
    checkEqual(counting.resolvedText(local: 0), "0", "起点显示起始值")
    checkEqual(counting.resolvedText(local: 2), "1,234", "滚动结束时精确落在终值")
    checkEqual(counting.resolvedText(local: 4.9), "1,234", "滚完之后一直停在终值")
    check(counting.resolvedText(local: 1) != "0" && counting.resolvedText(local: 1) != "1,234",
          "中途应当是个中间值，实际 \(counting.resolvedText(local: 1))")

    // MARK: 13 —— 老虎机：每一位在终点落在终值的那一位上
    //
    // 轮位的整数部分就是当前数字，小数部分是往上移出去了多少。终点时小数部分
    // 必须是 0（否则数字停在两个数中间，糊成一片），整数部分必须等于终值的
    // 那一位。

    var rolling = whiteTitle(start: 0, duration: 4)
    rolling.number = NumberRoll(
        from: 0, to: 4827, fractionDigits: 0, groupsThousands: false,
        prefix: "", suffix: "", style: .odometer, duration: 1.5
    )
    if let roll = rolling.number {
        let template = roll.settledText
        checkEqual(template, "4827", "老虎机的排版取定版串")
        let places = roll.digitPlaces(in: template)
        checkEqual(places.count, 4, "四位数字应当有四个位槽")
        // 个位在最后一个字符上，千位在第一个。
        checkEqual(places[3], 0, "最后一个字符是个位")
        checkEqual(places[0], 3, "第一个字符是千位")
        for (index, place) in places.sorted(by: { $0.key < $1.key }) {
            let wheel = roll.wheel(place: place, local: 1.5)
            let expected = Double(Array(template)[index].wholeNumberValue ?? -1)
            checkClose(wheel.truncatingRemainder(dividingBy: 10), expected, 0.0001,
                       "滚动结束时第 \(place) 位要停在 \(Int(expected)) 上")
        }
        // 中途必须真的在动，而且个位要比千位动得多（这就是里程表的样子）。
        let unitsTravel = abs(roll.wheel(place: 0, local: 0) - roll.wheel(place: 0, local: 1.5))
        let thousandsTravel = abs(roll.wheel(place: 3, local: 0) - roll.wheel(place: 3, local: 1.5))
        check(unitsTravel > thousandsTravel,
              "个位转得要比千位多（\(unitsTravel) vs \(thousandsTravel)）")
        // 行程封顶：不封的话 0→1000000 的个位要转十万圈，每帧跳过几万个数字。
        var huge = roll
        huge.to = 1_000_000
        let hugeTravel = abs(huge.wheel(place: 0, local: 0) - huge.wheel(place: 0, local: 1.5))
        check(hugeTravel <= NumberRoll.maximumWheelTurns * 10 + 0.001,
              "单条数字带的行程必须封顶，实际 \(hugeTravel)")
    }

    // MARK: 14 —— 等宽数字：版面宽度不随数字内容变
    //
    // 比例数字里 `1` 比 `8` 窄。不开等宽的话，每跳一个数整行宽度就变一次，
    // 居中的标题会左右抖，老虎机的位槽也对不齐。

    var widths: Set<String> = []
    for sample in ["111111", "888888", "102938", "000000"] {
        let layout = TextTypesetter.layout(rolling, canvas: canvas, text: sample)
        widths.insert(String(format: "%.2f", layout.inkBounds.width))
    }
    checkEqual(widths.count, 1, "等长的数字串必须一样宽，实际有 \(widths.count) 种：\(widths)")

    // MARK: 15 —— 数字滚动期间，位图尺寸和落点全程固定
    //
    // 与动画那一组同一条契约：贴图位置得是常数，否则数字会一边滚一边挪。
    // 数字这边尤其容易翻车 —— 位数变化会直接改版面宽度。

    // 框故意收窄：位数变多时会多折一行，于是「按当帧算包络」和「按定版算」
    // 才有可观察的差别 —— 框放宽的话两者恒等，这条断言就是摆设。
    var jumpy = whiteTitle(start: 0, duration: 3)
    jumpy.boxWidth = 0.3
    jumpy.number = NumberRoll(
        from: 9, to: 100_000, fractionDigits: 0, groupsThousands: true,
        prefix: "", suffix: "", style: .count, duration: 2
    )
    var numberSizes: Set<String> = []
    var numberOrigins: Set<String> = []
    for step in 0...12 {
        let state = TextAnimator.state(
            for: jumpy, at: Double(step) * 0.25, canvas: canvas, frameRate: .fps30
        )
        guard let frame = TextRenderer.render(jumpy, canvas: canvas, state: state) else { continue }
        numberSizes.insert("\(frame.size)")
        numberOrigins.insert("\(frame.origin)")
    }
    checkEqual(numberSizes.count, 1, "数字滚动期间位图尺寸必须只有一种（位数变了也不许变）")
    checkEqual(numberOrigins.count, 1, "数字滚动期间贴图落点必须只有一个")
}

/// 第 16b 组：等待 —— 前 `delay` 秒停在起始值上，之后照常滚；头部逐帧算到 `delay + duration`。
func checkNumberDelay() {
    var roll = NumberRoll(
        from: 0, to: 1234, fractionDigits: 0, groupsThousands: true,
        prefix: "", suffix: "", style: .count, duration: 2, delay: 1
    )
    checkEqual(roll.text(for: roll.value(local: 0)), "0", "等待开始时显示起始值")
    checkEqual(roll.text(for: roll.value(local: 0.99)), "0", "等待期间一直是起始值")
    checkEqual(roll.progress(local: 1), 0, "等待刚结束那一刻进度还是 0（不跳）")
    check(roll.value(local: 1.5) > 0 && roll.value(local: 1.5) < 1234,
          "等待过后才开始滚，实际 \(roll.value(local: 1.5))")
    checkEqual(roll.text(for: roll.value(local: 3)), "1,234", "等待 + 滚动结束时精确落在终值")
    checkEqual(roll.settleTime, 3, "停下来的时刻 = 等待 + 滚动")

    // 老虎机：等待期间每一位停在起始值的那一位上。轮位带着整圈数（起点 = 终点数字减去
    // 全部行程），所以按 10 取模比（同 main.swift 第 13 组比终点的写法）。
    roll.style = .odometer
    roll.from = 4827
    roll.to = 9000
    let template = roll.settledText
    for (index, place) in roll.digitPlaces(in: template) {
        let expected = Double(roll.digits(of: roll.from)[place] ?? -1)
        let wheel = roll.wheel(place: place, local: 0.5)
        let digit = (wheel.truncatingRemainder(dividingBy: 10) + 10).truncatingRemainder(dividingBy: 10)
        checkClose(digit, expected, 0.0001,
                   "等待期间第 \(place) 位要停在起始值的 \(Int(expected)) 上（字符 \(index)，轮位 \(wheel)）")
        checkClose(wheel, roll.wheel(place: place, local: 0), 0.0001, "等待期间轮位一动不动")
    }

    // 头部逐帧：入场 0.3s、等待 1s + 滚动 2s → 3s；被段长夹住。
    var overlay = TextOverlay(timelineStart: 0, duration: 5)
    overlay.number = roll
    overlay.animation = TextAnimation(
        entrance: .fade, exit: .none, entranceDuration: 0.3, exitDuration: 0,
        emphasis: .none, intensity: 0.5
    )
    let window = overlay.animation.window(span: overlay.duration)
    checkClose(overlay.animatedHead(window: window), 3, 0.0001, "头部逐帧 = 等待 + 滚动")
    overlay.duration = 2.5
    checkClose(overlay.animatedHead(window: overlay.animation.window(span: 2.5)), 2.5, 0.0001,
               "段比等待 + 滚动还短时头部夹到段长")

    // 没设等待 = 老行为。
    var plain = roll
    plain.delay = 0
    plain.style = .count
    check(plain.value(local: 0.5) > plain.from, "没有等待时一开始就在滚")
}
