import Foundation

// MARK: - 老虎机：每一位怎么滚、哪一格是空的
//
// 管什么：数字元件老虎机形态的**纯值**那一半 —— 定版串里每个字符是什么角色（哪一位数字、
// 跟着哪一位走的千分位逗号、负号），每一位的数字带从哪一格转到哪一格、哪一格是空白，以及
// 某一刻每个字符怎么画、占多宽。
// 不管什么：怎么画（`NumberWheelDrawing`）、怎么排版（`TextTypesetter`）、数值怎么格式化
// （`NumberRoll.format`）。
//
// ## 首帧就是起始值，末帧就是终值（2026-09-25）
//
// 定版串的位数取 from 和 to 里多的那个 —— 包络、选中框、可点范围都按它，滚动中不跳。可位数
// 少的那一头，多出来的高位**本来就不存在**：以前那几格照样画成 0，`365 → 90` 停在「090」上，
// `0 → 4827` 起步是「0000」，千分位逗号和负号也照样留着。
//
// 现在这种位的数字带在不存在的那一头是**一格空白**：365 → 90 的百位滚 3 → 2 → 1 → 空。
// 滚向空白的同时这一格的宽度跟着收成 0：居中和右对齐的**右边不动**（个位那一轮一动不动，后面
// 紧跟的「°」「天」「%」才贴得住），左对齐的左边不动，前缀和负号贴过来（`TextTypesetter` 里
// 收）。于是首帧显示的就是 from、末帧就是 to，中间是连着的。千分位逗号跟着它左边那一位一起
// 滚走 / 滚进；负号只在一头有时，自己滚进滚出。
//
// 两头都有的位不受影响：位数没变的滚动（4827 → 9000）和以前一格不差。
// 约束见 docs/architecture/text-overlays.md「数字元件」。

/// 老虎机这一刻，定版串里一个会动的字符怎么画。
enum OdometerCell: Equatable {
    /// 一条数字带。`wheel` 是连续轮位：整数部分是当前那一格，小数部分是它移出去了多少
    /// （第 k 格上的数字是 k mod 10）。`blank` 是带上画成**空白**的那一格 —— 这一位在起点
    /// 或终点不存在；nil = 两头都有这一位。
    case digit(wheel: Double, blank: Int?)
    /// 跟着滚进滚出的符号（千分位逗号、负号）。`reveal`：1 = 就位，0 = 整个滚出去了；
    /// `side`：滚出去的那一侧，+1 = 上方、-1 = 下方（y 向上，和数字带同一个方向）。
    case rider(reveal: Double, side: Double)

    /// 这个字符此刻占几成宽（0…1）。滚向空白的那一格，宽度跟着收。
    var width: Double {
        switch self {
        case .digit(let wheel, let blank):
            guard let blank else { return 1 }
            return min(1, abs(wheel - Double(blank)))
        case .rider(let reveal, _):
            return min(max(reveal, 0), 1)
        }
    }
}

/// 老虎机的一帧。
struct OdometerFrame: Equatable {
    /// 按 **UTF-16 下标**存，和 `TextLayout.Glyph.characterIndex` 同一套下标（前缀里可能有
    /// emoji，按字符数数的话后面全对不上）。不在表里的字符（前后缀、小数点、两头都有的逗号）
    /// 照常画、占满宽。
    var cells: [Int: OdometerCell]

    /// 没占满宽的那几个字符 → 此刻的宽度。排版按它收窄（`TextTypesetter.layout(widths:)`）。
    var widths: [Int: Double] {
        cells.compactMapValues { $0.width < 1 ? $0.width : nil }
    }
}

/// 老虎机的纯值那一半：角色表、数字带、某一刻的样子。
struct NumberOdometer {
    /// 定版串里一个会动的字符。
    enum Role: Equatable {
        /// 一位数字：0 = 个位，-1 = 小数第一位。
        case digit(place: Int)
        /// 千分位逗号：跟着它**左边**（高一位）那一位滚进滚出。
        case separator(abovePlace: Int)
        case sign
    }

    /// 一位数字的整条带：从 `start` 格转到 `end` 格，`blank` 那一格画成空白。
    struct Band: Equatable {
        var start: Double
        var end: Double
        var blank: Int?
    }

    let roll: NumberRoll
    /// 定版串（`roll.settledText`）里会动的字符，按 UTF-16 下标。前后缀、小数点不在表里。
    let roles: [Int: Role]
    /// 起点 / 终点在各位上的数字。不存在的位没有键。
    let startDigits: [Int: Int]
    let endDigits: [Int: Int]
    /// 定版串的整数位数。负号的节奏排在最高位之上。
    private let integerDigits: Int
    private let negative: (start: Bool, end: Bool)

    init(_ roll: NumberRoll) {
        self.roll = roll
        startDigits = Self.digits(of: roll.from, in: roll)
        endDigits = Self.digits(of: roll.to, in: roll)
        let parsed = Self.roles(of: roll)
        roles = parsed.roles
        integerDigits = parsed.integerDigits
        negative = (
            start: NumberRoll.format(roll.from, fractionDigits: roll.fractionDigits,
                                     groupsThousands: roll.groupsThousands).hasPrefix("-"),
            end: NumberRoll.format(roll.to, fractionDigits: roll.fractionDigits,
                                   groupsThousands: roll.groupsThousands).hasPrefix("-")
        )
    }

    /// 定版串里每个数字所在的位（UTF-16 下标 → 位）。
    var digitPlaces: [Int: Int] {
        roles.compactMapValues { role in
            if case .digit(let place) = role { return place }
            return nil
        }
    }

    // MARK: - 数字带

    /// 某一位的数字带。
    ///
    /// 每条带从**起始数字**转到**终止数字**，中间多转几圈。没用「第 k 位的轮位 = 值/10^k」
    /// 那个真实里程表公式：现实中高位只在低位归零时才对齐，4827 的千位会停在 4.827，卡在 4 和 5
    /// 中间糊成一片 —— 终点必须精确落在终值的那一位上。圈数取整（否则起点显示的数字不等于起始值
    /// 的那一位），按 `|to-from| / 10^(k+1)` 算并封顶（`NumberRoll.maximumWheelTurns`）。
    ///
    /// 这一位在某一头**不存在**时，那一头的那一格是空白。两头恰好是同一格（行程为 0：`100 → 5`
    /// 的十位，起点是 0、终点不存在）就往滚动方向多走一格 —— 不然空白和数字挤在同一格上，这一位
    /// 要么一直空着、要么一直是 0。
    func band(place: Int) -> Band {
        let startDigit = startDigits[place]
        let endDigit = endDigits[place]
        let turns = min(
            NumberRoll.maximumWheelTurns,
            (abs(roll.to - roll.from) / pow(10.0, Double(place + 1))).rounded(.down)
        )
        let direction: Double = roll.to >= roll.from ? 1 : -1
        var band = Band(
            start: Double(startDigit ?? 0) - 10 * turns * direction,
            end: Double(endDigit ?? 0),
            blank: nil
        )
        if startDigit == nil, endDigit != nil {
            if band.start == band.end { band.start -= direction }
            band.blank = Int(band.start)
        } else if endDigit == nil, startDigit != nil {
            if band.start == band.end { band.end += direction }
            band.blank = Int(band.end)
        }
        return band
    }

    /// 某一位这一刻的连续轮位：从 `band.start` 转到 `band.end`。
    func wheel(place: Int, local: Double) -> Double {
        wheel(band(place: place), place: place, local: local)
    }

    private func wheel(_ band: Band, place: Int, local: Double) -> Double {
        band.end - (band.end - band.start) * (1 - own(place: place, local: local))
    }

    /// 这一位自己的进度 0…1。低位转得多、高位转得少，而且**高位先停**：第 k 位在整体进度
    /// `1 - lead` 处就到位 —— 这就是老虎机依次锁定的那个节奏。
    private func own(place: Int, local: Double) -> Double {
        let lead = min(0.5, Double(max(0, place)) * 0.12)
        return min(1, roll.progress(local: local) / max(0.0001, 1 - lead))
    }

    // MARK: - 这一刻

    /// 这一刻每个会动的字符怎么画。
    func frame(local: Double) -> OdometerFrame {
        var cells: [Int: OdometerCell] = [:]
        var bands: [Int: (band: Band, wheel: Double)] = [:]
        for (offset, role) in roles {
            guard case .digit(let place) = role else { continue }
            let band = band(place: place)
            let wheel = wheel(band, place: place, local: local)
            cells[offset] = .digit(wheel: wheel, blank: band.blank)
            bands[place] = (band, wheel)
        }
        for (offset, role) in roles {
            switch role {
            case .digit:
                continue
            case .separator(let above):
                // 左边那一位两头都在：逗号一直在，照常画。
                guard let entry = bands[above], let blank = entry.band.blank else { continue }
                let reveal = min(1, abs(entry.wheel - Double(blank)))
                guard reveal < 1 else { continue }
                cells[offset] = .rider(reveal: reveal, side: Self.side(of: entry.band, blank: blank))
            case .sign:
                if let cell = signCell(local: local) { cells[offset] = cell }
            }
        }
        return OdometerFrame(cells: cells)
    }

    /// 空白那一格在带子的哪一头，跟着这一位的符号就从哪一侧走：带子往上转（轮位变大、数字
    /// 往上走）而空白在终点 → 往上滚走（+1）；空白在起点 → 从下面滚进来（-1）。往下转反过来。
    private static func side(of band: Band, blank: Int) -> Double {
        let other = Double(blank) == band.end ? band.start : band.end
        return Double(blank) > other ? 1 : -1
    }

    /// 负号只在一头有时才动，节奏排在最高位之上（比最高位再早一拍收口）：负 → 正时顺着滚动
    /// 方向滚走，正 → 负时从反方向滚进来 —— 两种情况都和数字带往同一边走。
    private func signCell(local: Double) -> OdometerCell? {
        guard negative.start != negative.end else { return nil }
        let own = own(place: integerDigits, local: local)
        let direction: Double = roll.to >= roll.from ? 1 : -1
        return negative.start
            ? .rider(reveal: 1 - own, side: direction)
            : .rider(reveal: own, side: -direction)
    }

    // MARK: - 解析

    /// 定版串里每个会动的字符的角色。只解析去掉前后缀的那一段（`settledNumber`）：前后缀里的
    /// 数字、句点不是位槽 —— 以前整串一起扫，后缀里的「2」会被当成个位，前缀里的「.」会被
    /// 当成小数点。
    private static func roles(of roll: NumberRoll) -> (roles: [Int: Role], integerDigits: Int) {
        let base = roll.prefix.utf16.count
        // 这一段只有负号、数字、千分位逗号和小数点，全是 ASCII：一个字符正好一个 UTF-16 单元。
        let characters = Array(roll.settledNumber)
        let dot = characters.firstIndex(of: ".") ?? characters.count
        let integerDigits = characters[..<dot].filter(\.isNumber).count
        var roles: [Int: Role] = [:]
        var place = integerDigits
        for (index, character) in characters.enumerated() {
            let offset = base + index
            if character == "-" {
                roles[offset] = .sign
            } else if index < dot, character.isNumber {
                place -= 1
                roles[offset] = .digit(place: place)
            } else if index < dot, character == "," {
                roles[offset] = .separator(abovePlace: place)
            } else if index > dot, character.isNumber {
                roles[offset] = .digit(place: dot - index)
            }
        }
        return (roles, integerDigits)
    }

    /// 某个值在各位上的数字。
    ///
    /// 从**格式化之后的串**里取，不从数值上除 —— 除法在小数位上会踩浮点误差（`12.5 / 0.1`
    /// 可能是 124.999…，第一位小数会算成 4 而不是 5），而串就是用户看到的东西，天然对得上。
    static func digits(of value: Double, in roll: NumberRoll) -> [Int: Int] {
        let characters = Array(NumberRoll.format(
            value, fractionDigits: roll.fractionDigits, groupsThousands: roll.groupsThousands
        ))
        let dot = characters.firstIndex(of: ".") ?? characters.count
        var result: [Int: Int] = [:]
        var place = 0
        for index in stride(from: dot - 1, through: 0, by: -1) {
            guard let digit = characters[index].wholeNumberValue else { continue }
            result[place] = digit
            place += 1
        }
        for index in characters.indices where index > dot {
            if let digit = characters[index].wholeNumberValue { result[dot - index] = digit }
        }
        return result
    }
}
