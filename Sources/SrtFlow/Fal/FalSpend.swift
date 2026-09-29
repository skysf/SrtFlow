import Foundation

// MARK: - fal 花钱：什么时候问用户、今天花了多少（纯值）
//
// 管什么：方案第 18 条 —— **只设每天的上限（默认 10 美元，用户能改），不设单次上限；额度内不问，超了先问；
// 换成没登记单价的模型，每次生成前先问**。这里是判断（`FalSpendPolicy`）和按天记账（`FalSpendLedger`）。
// 不管什么：问的界面（AISession 的提问 + 横幅）、账本存哪（FalSettingsStore）、每个模型的单价（FalModels）。
//
// 花的钱是**估算**（登记的单价 × 用量），不是 fal 的账单；方案「已知的风险」里写着。

enum FalSpendPolicy {
    enum Reason: Equatable {
        /// 这个模型没登记单价：估不出来，每次都先问。
        case unknownPrice
        /// 这一次做完今天就超过上限了。
        case overLimit(spent: Double, estimate: Double, limit: Double)
    }

    enum Decision: Equatable {
        case allow
        case ask(Reason)
    }

    /// 一美元的千分之一以内的误差不算（浮点加出来的 9.999999999 不该多问一次）。
    private static let slack = 0.0005

    static func decide(estimate: Double?, spentToday: Double, dailyLimit: Double) -> Decision {
        guard let estimate else { return .ask(.unknownPrice) }
        if spentToday + estimate <= dailyLimit + slack { return .allow }
        return .ask(.overLimit(spent: spentToday, estimate: estimate, limit: dailyLimit))
    }

    /// 配旁白这种**同步**的工具不能停下来等用户点头（客户端的调用一分钟左右就超时）：额度不够时直接退到下一档声音（本机的 / macOS 的）。
    static func allowsWithoutAsking(estimate: Double?, spentToday: Double, dailyLimit: Double) -> Bool {
        decide(estimate: estimate, spentToday: spentToday, dailyLimit: dailyLimit) == .allow
    }
}

/// 按天记的花费（本地时区的自然日）。只记数字，不记内容。
struct FalSpendLedger: Codable, Equatable, Sendable {
    /// `yyyy-MM-dd` → 这一天估算花了多少美元。
    private(set) var days: [String: Double] = [:]

    init(days: [String: Double] = [:]) { self.days = days }

    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    func spent(on date: Date, calendar: Calendar = .current) -> Double {
        days[Self.dayKey(for: date, calendar: calendar)] ?? 0
    }

    mutating func add(_ amount: Double, on date: Date, calendar: Calendar = .current) {
        guard amount > 0 else { return }
        days[Self.dayKey(for: date, calendar: calendar), default: 0] += amount
    }

    /// 退回一笔（生成失败 / 取消了、fal 没收钱）：不会退到负数。
    mutating func refund(_ amount: Double, on date: Date, calendar: Calendar = .current) {
        guard amount > 0 else { return }
        let key = Self.dayKey(for: date, calendar: calendar)
        guard let current = days[key] else { return }
        let left = max(0, current - amount)
        if left == 0 { days[key] = nil } else { days[key] = left }
    }

    /// 只留最近的几天：账本不该越攒越长。
    mutating func prune(keepingDays: Int = 40, now: Date, calendar: Calendar = .current) {
        guard let cutoff = calendar.date(byAdding: .day, value: -keepingDays, to: now) else { return }
        let oldest = Self.dayKey(for: cutoff, calendar: calendar)
        days = days.filter { $0.key >= oldest }
    }
}

enum FalMoney {
    /// 给人看的美元数：一分钱以上写两位小数，不到一分钱写到有效的那位（音效一秒 $0.0018）。
    static func text(_ usd: Double) -> String {
        if usd >= 0.01 || usd == 0 { return String(format: "$%.2f", usd) }
        let text = String(format: "%.4f", usd)
        var trimmed = text
        while trimmed.hasSuffix("0") { trimmed.removeLast() }
        return "$" + trimmed
    }
}
