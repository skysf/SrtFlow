import Foundation

// 第二组：花钱的把关（方案第 18 条）和按天记账。
// 只设每天的上限，不设单次上限；额度内不问，超了先问；没登记单价的每次都问。

func runSpendChecks() {
    typealias Policy = FalSpendPolicy

    // 额度内不问
    checkEqual(Policy.decide(estimate: 0.40, spentToday: 0, dailyLimit: 10), .allow, "well inside the limit: no question")
    checkEqual(Policy.decide(estimate: 0.40, spentToday: 9.60, dailyLimit: 10), .allow, "landing exactly on the limit is inside it")
    checkEqual(Policy.decide(estimate: 0.40, spentToday: 9.5999999, dailyLimit: 10), .allow, "float dust does not cost a question")
    // 超了先问
    if case .ask(.overLimit(let spent, let estimate, let limit)) = Policy.decide(estimate: 0.50, spentToday: 9.60, dailyLimit: 10) {
        checkClose(spent, 9.60, "the question carries what was spent")
        checkClose(estimate, 0.50, "the question carries the estimate")
        checkClose(limit, 10, "the question carries the limit")
    } else {
        check(false, "0.50 on top of 9.60 goes over a 10.00 limit: ask")
    }
    // 没有单次上限：一次就超过整天的额度也只是「超了要问」，不是拒绝
    check(Policy.decide(estimate: 25, spentToday: 0, dailyLimit: 10) != .allow, "a single call above the daily limit asks")
    // 没登记单价：每次都问，哪怕额度还很多
    checkEqual(Policy.decide(estimate: nil, spentToday: 0, dailyLimit: 1000), .ask(.unknownPrice), "an unknown price always asks")
    // 上限调成 0：什么要钱的都问
    check(Policy.decide(estimate: 0.01, spentToday: 0, dailyLimit: 0) != .allow, "a limit of zero asks for everything that costs")
    checkEqual(Policy.decide(estimate: 0, spentToday: 0, dailyLimit: 0), .allow, "something free never asks")
    // 配旁白这种同步的工具不能停下来等：额度不够 / 价格不明时退到下一档
    check(Policy.allowsWithoutAsking(estimate: 0.04, spentToday: 1, dailyLimit: 10), "a small voiceover inside the limit goes ahead")
    check(!Policy.allowsWithoutAsking(estimate: 0.04, spentToday: 9.99, dailyLimit: 10), "a voiceover over the limit does not")
    check(!Policy.allowsWithoutAsking(estimate: nil, spentToday: 0, dailyLimit: 10), "an unknown price does not")

    // 按天记账（固定时区和日期，别让自检跟着跑的那天和机器变）
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)!
    }
    let morning = date("2026-09-29T01:00:00+08:00")
    let night = date("2026-09-29T23:59:00+08:00")
    let nextDay = date("2026-09-30T00:01:00+08:00")
    checkEqual(FalSpendLedger.dayKey(for: morning, calendar: calendar), "2026-09-29", "day key in the local time zone")
    // UTC 的 09-29 16:30 在上海已经是 09-30 —— 按本地自然日记，不按 UTC
    checkEqual(FalSpendLedger.dayKey(for: date("2026-09-29T16:30:00Z"), calendar: calendar), "2026-09-30", "the day follows the local clock, not UTC")

    var ledger = FalSpendLedger()
    ledger.add(0.40, on: morning, calendar: calendar)
    ledger.add(0.60, on: night, calendar: calendar)
    checkClose(ledger.spent(on: morning, calendar: calendar), 1.0, "the same local day adds up")
    checkClose(ledger.spent(on: nextDay, calendar: calendar), 0, "a new day starts at zero")
    ledger.refund(0.40, on: night, calendar: calendar)
    checkClose(ledger.spent(on: morning, calendar: calendar), 0.60, "a refund takes the estimate back")
    ledger.refund(5, on: morning, calendar: calendar)
    checkClose(ledger.spent(on: morning, calendar: calendar), 0, "a refund never goes below zero")
    check(ledger.days.isEmpty, "an empty day leaves no entry")
    ledger.add(-3, on: morning, calendar: calendar)
    ledger.add(0, on: morning, calendar: calendar)
    check(ledger.days.isEmpty, "nothing is recorded for zero or negative amounts")
    ledger.refund(1, on: nextDay, calendar: calendar)
    check(ledger.days.isEmpty, "refunding a day that has nothing changes nothing")

    // 老的天数清掉
    var old = FalSpendLedger()
    old.add(1, on: date("2026-05-01T12:00:00+08:00"), calendar: calendar)
    old.add(2, on: date("2026-09-20T12:00:00+08:00"), calendar: calendar)
    old.add(3, on: date("2026-09-29T12:00:00+08:00"), calendar: calendar)
    old.prune(keepingDays: 40, now: date("2026-09-29T12:00:00+08:00"), calendar: calendar)
    checkEqual(Set(old.days.keys), ["2026-09-20", "2026-09-29"], "days older than the window are dropped")

    // 存取往返
    let back = try? JSONDecoder().decode(FalSpendLedger.self, from: JSONEncoder().encode(old))
    checkEqual(back, old, "the ledger survives a save / load round trip")

    // 给人看的钱数
    checkEqual(FalMoney.text(10), "$10.00", "whole dollars")
    checkEqual(FalMoney.text(0.4), "$0.40", "cents")
    checkEqual(FalMoney.text(0.027), "$0.03", "a few cents are rounded to a cent")
    checkEqual(FalMoney.text(0.0018), "$0.0018", "a fraction of a cent keeps its digits")
    checkEqual(FalMoney.text(0.009), "$0.009", "trailing zeros are trimmed")
    checkEqual(FalMoney.text(0), "$0.00", "zero")
}
