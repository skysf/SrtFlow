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
