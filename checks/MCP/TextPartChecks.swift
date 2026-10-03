import Foundation
import SrtFlowMCPKit

// set_text 在 2026-09-28 补的几样（MCP 第 5 块，配方卡要用）：字距、入场 / 出场时长、动画强度、强调（呼吸）、数字滚动。
// 都是模型里早就有、AI 调不到的；夹紧照旧走 updateTextOverlay 那一处。编法见 scripts/check-mcp.sh。

func runTextPartChecks() {
    var state = TimelineState()
    let overlay = TextOverlay(text: "Title", timelineStart: 0)
    state.textOverlays = [overlay]
    func apply(_ object: [String: JSONValue]) {
        guard let change = try? AITextChange(args(object)) else {
            check(false, "set_text refused \(object)")
            return
        }
        state.updateTextOverlay(overlay.id) { change.apply(to: &$0) }
    }
    func current() -> TextOverlay { state.textOverlays[0] }

    apply(["letter_spacing": 200, "animation_in": "focus", "animation_in_duration": 1.2,
           "animation_out_duration": 0.3, "animation_intensity": 0.4, "emphasis": "breathe"])
    checkEqual(current().style.letterSpacing, TextStyle.letterSpacingRange.upperBound, "letter spacing is clamped where the inspector clamps it")
    checkEqual(current().animation.entrance, .focus, "entrance kind")
    checkEqual(current().animation.entranceDuration, 1.2, "entrance seconds")
    checkEqual(current().animation.exitDuration, 0.3, "exit seconds")
    checkEqual(current().animation.intensity, 0.4, "animation intensity")
    checkEqual(current().animation.emphasis, .breathe, "emphasis")
    checkThrows("an unknown emphasis is refused") { _ = try AITextChange(args(["emphasis": "shake"])) }

    // 数字滚动：没有数字的文字从检查器那一套默认值起；只改给了的字段；remove 变回普通文字、画面上留着终值。
    apply(["number": ["to": 10000, "suffix": "+", "style": "odometer"]])
    checkEqual(current().number?.from, NumberRoll.default.from, "a new number starts from the inspector's default")
    checkEqual(current().number?.to, 10000, "to lands")
    checkEqual(current().number?.style, .odometer, "odometer style")
    checkEqual(current().settledText, "10,000+", "thousands are grouped by default and the suffix is kept")
    apply(["number": ["seconds": 99, "delay": 0.5]])
    checkEqual(current().number?.to, 10000, "fields not passed are kept")
    checkEqual(current().number?.duration, NumberRoll.durationRange.upperBound, "roll seconds are clamped")
    checkEqual(current().number?.delay, 0.5, "delay lands")
    let context = AITimelineSummary.Context(
        ids: AIShortIDs(state: state), workspace: nil, playhead: 0, selection: [], renderSize: CGSize(width: 1920, height: 1080)
    )
    let summary = AITimelineSummary.make(state, context)["texts"]?.arrayValue?.first ?? .null
    checkEqual(summary["number"]?["to"]?.doubleValue, 10000, "get_timeline shows the number")
    checkEqual(summary["emphasis"]?.stringValue, "breathe", "get_timeline shows the emphasis")
    check(summary["letter_spacing"] != nil, "get_timeline shows the letter spacing")
    checkThrows("number must be an object") { _ = try AITextChange(args(["number": 5])) }

    state.updateTextOverlay(overlay.id) { $0.text = "" }
    apply(["number": ["remove": true]])
    check(current().number == nil, "remove turns it back into text")
    checkEqual(current().text, "10,000+", "the end value stays on screen as text instead of disappearing")

    // 字面的反斜杠 + n（客户端把说明里的 \n 原样当两个字符传来）也是换行；真换行照旧（2026-09-29 婚礼工程 BUG-09）。
    apply(["text": "一桌好酒席\\n见证好姻缘"])
    checkEqual(current().text, "一桌好酒席\n见证好姻缘", "a literal backslash-n becomes a line break")
    apply(["text": "line one\nline two"])
    checkEqual(current().text, "line one\nline two", "a real newline is kept as it is")

    // 旋转（界面上的旋转把手转的那个）和更大的字号（拿字符拼大图形，2026-10-03 南极工程：AI 想让「○」当圆环转起来、要比 400 大）。
    apply(["rotation": 30, "font_size": 900])
    checkEqual(current().rotationDegrees, 30, "rotation lands")
    checkEqual(current().style.fontSize, 900, "font_size above the old 400 cap lands")
    apply(["rotation": -450, "font_size": 5000])
    checkEqual(current().rotationDegrees, -90, "rotation is normalised the way the rotate handle normalises it")
    checkEqual(current().style.fontSize, TextStyle.fontSizeRange.upperBound, "font_size is clamped where the inspector clamps it")
    checkEqual(TextStyle.fontSizeRange.upperBound, 1000, "the font size cap is 1000")
    let rotated = AITimelineSummary.make(state, context)["texts"]?.arrayValue?.first ?? .null
    checkEqual(rotated["rotation"]?.doubleValue, -90, "get_timeline shows the rotation")
}
