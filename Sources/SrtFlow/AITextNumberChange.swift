import Foundation
import SrtFlowMCPKit

// MARK: - set_text 的 number：数字滚动（纯值）
//
// 管什么：AI 给的 `number` 对象怎么落到 `TextOverlay.number`（`NumberRoll`）上 —— 只改给了的字段，没有数字的文字从
// 检查器「数字」那一套的默认值起（`NumberRoll.default`）；`remove: true` 变回普通文字。
// 夹紧照旧只走 `TimelineState.updateTextOverlay` 那一处（`NumberRoll.clampToValidRange`），这里不另夹一份。
// 不管什么：数字怎么滚、怎么排（VideoEditTextNumber / VideoEditTextOdometer）。
// 2026-09-28 MCP 第 5 块补的零件：带货的「3 天」「10,000+」、科幻的倒计时（docs/plans/2026-09-28-mcp-recipes.md）。

struct AINumberRollChange {
    var remove = false
    var from: Double?
    var to: Double?
    var decimals: Int?
    var thousands: Bool?
    var prefix: String?
    var suffix: String?
    var style: NumberRollStyle?
    var seconds: Double?
    var delay: Double?

    /// `number` 没给是 nil；给了但不是对象就报错。
    init?(_ args: AIToolArguments) throws {
        guard let raw = args.raw["number"], !raw.isNull else { return nil }
        guard case .object = raw else { throw AIToolError("number must be an object, e.g. {\"from\": 0, \"to\": 100}.") }
        let fields = AIToolArguments(raw)
        remove = try fields.bool("remove") ?? false
        from = try fields.double("from")
        to = try fields.double("to")
        decimals = try fields.int("decimals")
        thousands = try fields.bool("thousands")
        prefix = try fields.string("prefix")
        suffix = try fields.string("suffix")
        style = try fields.choice("style", from: MCPVocabulary.numberStyles).flatMap(NumberRollStyle.init(rawValue:))
        seconds = try fields.double("seconds")
        delay = try fields.double("delay")
    }

    func apply(to overlay: inout TextOverlay) {
        if remove {
            // 变回普通文字：画面上原来显示的数字留成文字，免得整段突然空掉（数字元件的 text 是空的）。
            if let roll = overlay.number, overlay.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                overlay.text = roll.text(for: roll.to)
            }
            overlay.number = nil
            return
        }
        var roll = overlay.number ?? .default
        if let from { roll.from = from }
        if let to { roll.to = to }
        if let decimals { roll.fractionDigits = decimals }
        if let thousands { roll.groupsThousands = thousands }
        if let prefix { roll.prefix = prefix }
        if let suffix { roll.suffix = suffix }
        if let style { roll.style = style }
        if let seconds { roll.duration = seconds }
        if let delay { roll.delay = delay }
        overlay.number = roll
    }

    /// 回给 AI 看的那一小段（get_timeline / set_text 的结果里）。
    static func summary(_ roll: NumberRoll) -> JSONValue {
        var object: [String: JSONValue] = [
            "from": .number(roll.from), "to": .number(roll.to),
            "style": .string(roll.style.rawValue), "seconds": AIFormat.seconds(roll.duration)
        ]
        if roll.delay > 0 { object["delay"] = AIFormat.seconds(roll.delay) }
        if !roll.prefix.isEmpty { object["prefix"] = .string(roll.prefix) }
        if !roll.suffix.isEmpty { object["suffix"] = .string(roll.suffix) }
        return .object(object)
    }
}
