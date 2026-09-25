import Foundation

// MARK: - 数字滚动
//
// 独立的一种文字内容：不是打进去的字，而是从一个值滚到另一个值。
// 做成 `TextOverlay` 上的一个可选字段而不是另一个模型 —— 于是它白捡整套
// 样式、动画、摆放、时间线能力，而"数字"只是内容的来源不同。
//
// ## 两种形态
//
// - **数值插值**：整个数字连续变化（`0 → 1,234`），位数会跟着变多。
//   质感来自缓动收尾。
// - **老虎机**：每一位在一条垂直数字带上滚到位。质感明显更强，但要按位排版。
//
// ## 格式化**不跟系统区域走**
//
// 千分位一律逗号、小数点一律句点。看起来武断，但成片是文件：同一份工程在
// 不同区域设置的机器上必须渲出一模一样的画面。要别的写法用前缀/后缀兜。

enum NumberRollStyle: String, CaseIterable, Identifiable, Hashable, Sendable {
    /// 数值插值：整个数字连续变化。
    case count
    /// 老虎机：每一位各自在数字带上滚。
    case odometer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .count: return "Count up"
        case .odometer: return "Odometer"
        }
    }
}

struct NumberRoll: Hashable, Sendable {
    var from: Double
    var to: Double
    var fractionDigits: Int
    var groupsThousands: Bool
    var prefix: String
    var suffix: String
    var style: NumberRollStyle
    /// 滚动占多少秒。滚完之后停在终值上。
    var duration: Double
    /// 先等多少秒再开始滚（从这段文字的起点算起）。等待期间停在起始值上
    /// （2026-09-24 用户拍板：「Delay / 等待」）。默认 0，只有用了才落盘（v21）。
    var delay: Double = 0

    static let `default` = NumberRoll(
        from: 0, to: 100, fractionDigits: 0, groupsThousands: true,
        prefix: "", suffix: "", style: .count, duration: 1.5
    )

    static let fractionDigitsRange = 0...4
    static let durationRange = 0.1...20.0
    static let delayRange = 0.0...60.0
    /// 一条数字带最多转几圈。
    ///
    /// 不封顶的话，`0 → 1000000` 的个位要转一百万圈 —— 30fps 下每帧跳过
    /// 几万个数字，画面是一团无法辨认的糊。三圈已经足够"在转"，再多也只是糊。
    static let maximumWheelTurns = 3.0

    mutating func clampToValidRange() {
        fractionDigits = min(max(fractionDigits, NumberRoll.fractionDigitsRange.lowerBound),
                             NumberRoll.fractionDigitsRange.upperBound)
        duration = min(max(duration, NumberRoll.durationRange.lowerBound),
                       NumberRoll.durationRange.upperBound)
        delay = delay.isFinite
            ? min(max(delay, NumberRoll.delayRange.lowerBound), NumberRoll.delayRange.upperBound)
            : 0
        if !from.isFinite { from = 0 }
        if !to.isFinite { to = 0 }
    }

    // MARK: - 取值

    /// 滚动进度 0…1。`local` 是这段文字自己的时间；前 `delay` 秒是等待，进度为 0。
    func progress(local: Double) -> Double {
        guard duration > 0 else { return local < delay ? 0 : 1 }
        return TextEasing.easeOutCubic(min(max((local - delay) / duration, 0), 1))
    }

    /// 从段起点算，几秒之后数字停下来（等待 + 滚动）。导出切段按它算头部逐帧的长度。
    var settleTime: Double { delay + duration }

    /// 数值插值那一路：这一刻显示的数字。
    func value(local: Double) -> Double {
        from + (to - from) * progress(local: local)
    }

    // MARK: - 格式化

    /// 带前后缀的完整显示串。
    func text(for value: Double) -> String {
        prefix + NumberRoll.format(value, fractionDigits: fractionDigits,
                                   groupsThousands: groupsThousands) + suffix
    }

    /// 排版定版用的串：`from` 和 `to` 里**更长的那个**。
    ///
    /// 选中框、包络、老虎机的位槽都按它算 —— 取终值的话，`1000 → 5` 这种
    /// 会在滚动中途超出包络被裁掉。
    var settledText: String {
        let a = text(for: from)
        let b = text(for: to)
        return a.count >= b.count ? a : b
    }

    /// 定版串里每个数字所在的**十进制位**（0 = 个位，-1 = 小数第一位）。
    ///
    /// 老虎机按位滚，所以必须知道每个字符对应哪一位；前后缀、符号、千分位
    /// 逗号都不是位槽，不参与滚动。
    func digitPlaces(in text: String) -> [Int: Int] {
        var places: [Int: Int] = [:]
        let characters = Array(text)
        // 小数点右边从 -1 往下数，左边从 0 往上数。没有小数点就整串当整数部分。
        let dot = characters.firstIndex(of: ".")
        var place = 0
        var index = (dot ?? characters.count) - 1
        while index >= 0 {
            if characters[index].isNumber {
                places[index] = place
                place += 1
            }
            index -= 1
        }
        if let dot {
            var fraction = -1
            for position in (dot + 1)..<characters.count where characters[position].isNumber {
                places[position] = fraction
                fraction -= 1
            }
        }
        return places
    }

    /// 某个值在各个十进制位上的数字。
    ///
    /// 从**格式化之后的串**里取，不从数值上除 —— 除法在小数位上会踩浮点误差
    /// （`12.5 / 0.1` 可能是 124.999…，第一位小数会算成 4 而不是 5），
    /// 而串就是用户看到的东西，天然对得上。
    func digits(of value: Double) -> [Int: Int] {
        let text = NumberRoll.format(value, fractionDigits: fractionDigits,
                                     groupsThousands: groupsThousands)
        let characters = Array(text)
        var result: [Int: Int] = [:]
        for (index, place) in digitPlaces(in: text) {
            result[place] = characters[index].wholeNumberValue ?? 0
        }
        return result
    }

    /// 老虎机：某一位这一刻的**连续轮位**。整数部分是当前数字，小数部分是
    /// 它往上移出去了多少。
    ///
    /// 每条带子从**起始数字**转到**终止数字**，中间多转几圈。
    ///
    /// 没用「第 k 位的轮位 = 值/10^k」那个真实里程表公式：现实中高位只在低位
    /// 归零时才对齐，而目标值一般不是整十整百 —— 4827 的千位会停在 4.827，
    /// 也就是卡在 4 和 5 中间糊成一片。终点必须精确落在终值的那一位上。
    ///
    /// 圈数取整，否则起点显示的数字不等于起始值的那一位。
    /// 低位转得多、高位转得少，而且**高位先停**（`lead`）—— 这就是老虎机
    /// 依次锁定的那个节奏。
    func wheel(place: Int, local: Double) -> Double {
        let startDigit = Double(digits(of: from)[place] ?? 0)
        let endDigit = Double(digits(of: to)[place] ?? 0)
        let turns = min(
            NumberRoll.maximumWheelTurns,
            (abs(to - from) / pow(10.0, Double(place + 1))).rounded(.down)
        )
        let direction: Double = to >= from ? 1 : -1
        let travel = (endDigit - startDigit) + 10 * turns * direction

        // 高位提前收口：第 k 位在整体进度 `1 - lead` 处就到位。
        let lead = min(0.5, Double(max(0, place)) * 0.12)
        let own = min(1, progress(local: local) / max(0.0001, 1 - lead))
        return endDigit - travel * (1 - own)
    }

    /// 无区域依赖的定点格式化。
    static func format(_ value: Double, fractionDigits: Int, groupsThousands: Bool) -> String {
        let digits = min(max(fractionDigits, 0), 8)
        guard value.isFinite else { return "0" }
        let negative = value < 0
        let scale = pow(10.0, Double(digits))
        let rounded = (abs(value) * scale).rounded()
        // Double 到 UInt64 的安全上界。超了就退回科学计数以外的尽力而为，
        // 反正那种量级在标题里没有意义。
        guard rounded < 9.0e18 else { return negative ? "-" : "" }
        let total = UInt64(rounded)
        let unit = UInt64(scale)
        var integer = String(total / unit)
        if groupsThousands, integer.count > 3 {
            var grouped: [Character] = []
            for (offset, character) in integer.reversed().enumerated() {
                if offset > 0, offset % 3 == 0 { grouped.append(",") }
                grouped.append(character)
            }
            integer = String(grouped.reversed())
        }
        var result = (negative ? "-" : "") + integer
        if digits > 0 {
            let fraction = String(total % unit)
            result += "." + String(repeating: "0", count: digits - fraction.count) + fraction
        }
        return result
    }
}

extension NumberRoll: Codable {
    private enum CodingKeys: String, CodingKey {
        case from, to, fractionDigits, groupsThousands, prefix, suffix, style, duration, delay
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = NumberRoll.default
        self.init(
            from: try c.decodeIfPresent(Double.self, forKey: .from) ?? 0,
            to: try c.decodeIfPresent(Double.self, forKey: .to) ?? 0,
            fractionDigits: try c.decodeIfPresent(Int.self, forKey: .fractionDigits) ?? 0,
            groupsThousands: try c.decodeIfPresent(Bool.self, forKey: .groupsThousands) ?? true,
            prefix: try c.decodeIfPresent(String.self, forKey: .prefix) ?? "",
            suffix: try c.decodeIfPresent(String.self, forKey: .suffix) ?? "",
            style: try c.decodeIfPresent(NumberRollStyle.self, forKey: .style) ?? .count,
            duration: try c.decodeIfPresent(Double.self, forKey: .duration) ?? fallback.duration,
            delay: try c.decodeIfPresent(Double.self, forKey: .delay) ?? 0
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(from, forKey: .from)
        try c.encode(to, forKey: .to)
        try c.encode(fractionDigits, forKey: .fractionDigits)
        try c.encode(groupsThousands, forKey: .groupsThousands)
        try c.encode(prefix, forKey: .prefix)
        try c.encode(suffix, forKey: .suffix)
        try c.encode(style, forKey: .style)
        try c.encode(duration, forKey: .duration)
        // 按需写入：没等待的数字不落这个键，v21 的闸门只对真用了等待的工程关门。
        if delay > 0 { try c.encode(delay, forKey: .delay) }
    }
}

extension NumberRollStyle: LenientCodableEnum {
    static var decodingFallback: NumberRollStyle { .count }
}
