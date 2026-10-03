import CoreGraphics
import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - record_screen 的参数读成一个值
//
// 管什么：AI 传来的参数 → 一次「开始 / 停止 / 处置」的请求：默认值、每个参数的范围、只属于某种来源的参数给错了地方
// 当场报错（不悄悄忽略：AI 以为录的是那个窗口，其实录了整屏）；以及 AI 说的词和录屏类型之间的对照（`AIScreenRecordingWords`）。
// 纯值，自检直接喂参数（checks/MCP/ScreenRecordingToolChecks.swift）。
// 不管什么：挑哪个窗口 / 屏幕 / 麦克风（AIScreenSourceMatch）、真去录（AIScreenRecordingTool → ScreenRecordingCoordinator）。
// 产品口径见 docs/plans/2026-10-03-screen-recording-mcp.md。

struct AIScreenRecordingRequest: Equatable {
    enum Action: String {
        case start, stop, resolve
    }

    enum Source: Equatable {
        /// 整块屏幕；nil = 主屏（编号 1）。
        case display(Int?)
        /// 一个窗口：App 名、标题里的字，或 get_status 列出来的窗口编号。
        case window(String)
        /// 屏幕上的一块：显示器的比例（左上原点、0…1）。
        case region(display: Int?, fractions: CGRect)
        /// 区域框出来让用户拖（现有的手动功能；只有 AI 明说才会出现）。
        case drag(ratio: RegionAspectRatio)
    }

    enum Decision: String {
        case add, keep, discard
    }

    var action: Action
    var source: Source = .display(nil)
    var computerAudio = true
    /// nil = 不录麦克风；"default" = 系统默认的那个；其余是设备名里的字。
    var microphone: String?
    var cursor = CursorConfiguration.default
    var countdown = 3
    var duration: Double?
    /// 文件名主干（去掉了扩展名、斜杠、开头的点）；nil = 默认名「Screen Recording <日期 时间>」。
    var title: String?
    var addsToTimeline = true
    var decision: Decision?

    static let maxCountdown = 10
    static let maxDuration: Double = 14_400

    static func parse(_ args: AIToolArguments) throws -> AIScreenRecordingRequest {
        guard let name = try args.choice("action", from: MCPVocabulary.recordingActions), let action = Action(rawValue: name) else {
            throw AIToolError("action is required: start, stop or resolve.")
        }
        var request = AIScreenRecordingRequest(action: action)
        switch action {
        case .stop:
            break
        case .resolve:
            guard let word = try args.choice("decision", from: MCPVocabulary.recordingDecisions), let decision = Decision(rawValue: word) else {
                throw AIToolError("resolve needs decision: add (to the timeline), keep (the file only) or discard.")
            }
            request.decision = decision
        case .start:
            request.source = try source(args)
            try request.readOptions(args)
        }
        return request
    }

    /// 录哪里。只属于某一种来源的参数给到别的来源上就报错。
    private static func source(_ args: AIToolArguments) throws -> Source {
        let kind = try args.choice("source", from: MCPVocabulary.recordingSources) ?? "display"
        let display = try args.int("display")
        if let display, display < 1 { throw AIToolError("display counts from 1 (get_status screen=true lists them).") }
        let window = try args.string("window")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rect = try fractions(args)
        let ratio = try args.choice("ratio", from: MCPVocabulary.recordingRatios)
        if window != nil, kind != "window" { throw AIToolError("window goes with source=window.") }
        if rect != nil, kind != "region" { throw AIToolError("rect goes with source=region.") }
        if ratio != nil, kind != "drag" { throw AIToolError("ratio goes with source=drag (the user drags the area).") }
        if display != nil, kind == "window" || kind == "drag" { throw AIToolError("display goes with source=display or source=region.") }
        switch kind {
        case "window":
            guard let window, !window.isEmpty else {
                throw AIToolError("source=window needs window: an app name, title words, or a window number from get_status screen=true.")
            }
            return .window(window)
        case "region":
            guard let rect else {
                throw AIToolError("source=region needs rect: x, y, width, height as fractions of the display. To let the user drag the area, use source=drag.")
            }
            return .region(display: display, fractions: rect)
        case "drag":
            return .drag(ratio: AIScreenRecordingWords.ratio(ratio ?? "free"))
        default:
            return .display(display)
        }
    }

    /// 声音、指针、倒数、多久停、叫什么、入不入轨。
    private mutating func readOptions(_ args: AIToolArguments) throws {
        computerAudio = try args.bool("computer_audio") ?? true
        microphone = try Self.microphone(args)
        cursor = AIScreenRecordingWords.cursor(try args.choice("pointer", from: MCPVocabulary.recordingPointers) ?? "shown")
        if let seconds = try args.int("countdown") {
            guard (0...Self.maxCountdown).contains(seconds) else { throw AIToolError("countdown is 0 to \(Self.maxCountdown) seconds.") }
            countdown = seconds
        }
        if let seconds = try args.double("duration") {
            guard seconds >= 1, seconds <= Self.maxDuration else {
                throw AIToolError("duration is 1 to \(Int(Self.maxDuration)) seconds.")
            }
            duration = seconds
        }
        if let text = try args.string("title") {
            let stem = ExportFileName.stem(from: text, droppingExtension: "mov", fallback: "")
            title = stem.isEmpty ? nil : stem
        }
        addsToTimeline = try args.bool("add_to_timeline") ?? true
    }

    /// rect：{x, y, width, height}，显示器的比例、左上原点。出了 0…1、宽高不为正、伸出右边 / 下边都报错 ——
    /// 不悄悄夹进去，AI 以为录的就是它给的那一块。
    static func fractions(_ args: AIToolArguments) throws -> CGRect? {
        guard args.has("rect") else { return nil }
        guard let raw = args.raw["rect"], case .object = raw else { throw AIToolError("rect must be an object: {x, y, width, height}.") }
        let rect = AIToolArguments(raw)
        let x = try rect.requiredDouble("x"), y = try rect.requiredDouble("y")
        let width = try rect.requiredDouble("width"), height = try rect.requiredDouble("height")
        let slack = 0.001
        guard x >= 0, y >= 0, width > 0, height > 0, x + width <= 1 + slack, y + height <= 1 + slack else {
            throw AIToolError("rect is fractions of the display: x and y from 0, width and height above 0, x + width and y + height at most 1.")
        }
        return CGRect(x: x, y: y, width: min(width, 1 - x), height: min(height, 1 - y))
    }

    /// microphone：true / "default" = 系统默认的那个；false / "off" / "none" = 不录；别的字 = 设备名里的字。
    static func microphone(_ args: AIToolArguments) throws -> String? {
        guard args.has("microphone") else { return nil }
        if case .bool(let on)? = args.raw["microphone"] { return on ? "default" : nil }
        guard let text = try args.string("microphone")?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        switch text.lowercased() {
        case "false", "off", "none", "no": return nil
        case "true", "on", "yes", "default": return "default"
        default: return text
        }
    }
}

/// AI 说的词 ↔ 录屏的类型。词表（`MCPVocabulary.recording*`）和这里对账（checks/MCP/ScreenRecordingToolChecks.swift）。
enum AIScreenRecordingWords {
    /// `RegionAspectRatio` 的说法：free，其余照界面上的写法（16:9 …）。
    static func word(for ratio: RegionAspectRatio) -> String {
        ratio == .free ? "free" : ratio.title
    }

    static func ratio(_ word: String) -> RegionAspectRatio {
        RegionAspectRatio.allCases.first { self.word(for: $0) == word } ?? .free
    }

    static func cursor(_ word: String) -> CursorConfiguration {
        switch word {
        case "hidden": return CursorConfiguration(showsCursor: false, showsClicks: false)
        case "clicks": return CursorConfiguration(showsCursor: true, showsClicks: true)
        default: return .default
        }
    }

    /// 录屏状态给 AI 的说法（get_status、get_job）。
    static func state(_ state: ScreenRecordingState) -> String {
        switch state {
        case .idle, .finished, .failed: return "idle"
        case .configuring, .choosingDestination, .preparing: return "preparing"
        case .choosingSource: return "choosing_source"
        case .countingDown: return "counting_down"
        case .starting: return "starting"
        case .recording: return "recording"
        case .stopping, .finishing, .importing: return "finishing"
        case .partialRecovery: return "waiting_for_decision"
        }
    }
}
