import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// 客户端配置文件的增删、文字参数、颜色、字幕批量改、以及「小程序那份选项词表」和 App 里的
// 类型逐项对账（小程序不链接 App 的代码，词表是抄的，抄的就会漂）。

func runConfigChecks() {
    jsonConfigChecks()
    tomlConfigChecks()
    textChecks()
    subtitleEditChecks()
    vocabularyChecks()
}

private func jsonConfigChecks() {
    let existing = Data(#"{"theme":"dark","mcpServers":{"other":{"command":"/bin/other"}}}"#.utf8)
    let added = try? AIClientConfigFiles.jsonAdding(command: "/Applications/SrtFlow.app/Contents/Helpers/srtflow-mcp", to: existing)
    checkEqual(AIClientConfigFiles.jsonCommand(in: added), "/Applications/SrtFlow.app/Contents/Helpers/srtflow-mcp",
               "the srtflow entry is added")
    let root = added.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    checkEqual(root["theme"] as? String, "dark", "other settings are kept")
    check(((root["mcpServers"] as? [String: Any])?["other"]) != nil, "other MCP servers are kept")
    let removed = try? AIClientConfigFiles.jsonRemoving(from: added)
    check(AIClientConfigFiles.jsonCommand(in: removed) == nil, "the srtflow entry is removed")
    check(((removed.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["mcpServers"]
        as? [String: Any])?["other"]) != nil, "removing keeps the other servers")
    checkEqual(AIClientConfigFiles.jsonCommand(in: try? AIClientConfigFiles.jsonAdding(command: "/x", to: nil)), "/x",
               "a missing file becomes a fresh configuration")
    checkThrows("a broken JSON file is left alone") { _ = try AIClientConfigFiles.jsonAdding(command: "/x", to: Data("{oops".utf8)) }
}

private func tomlConfigChecks() {
    let existing = """
    model = "gpt-5"

    [mcp_servers.srtflow]
    command = "/old/path"

    [mcp_servers.srtflow.env]
    A = "1"

    [projects."/Users/me/code"]
    trust_level = "trusted"
    """
    let added = AIClientConfigFiles.tomlAdding(command: #"/Applications/SrtFlow "Beta".app/Contents/Helpers/srtflow-mcp"#, to: existing)
    checkEqual(added.components(separatedBy: "[mcp_servers.srtflow]").count - 1, 1, "exactly one srtflow table")
    check(!added.contains("[mcp_servers.srtflow.env]"), "the old sub-table goes too")
    check(added.contains("model = \"gpt-5\"") && added.contains("trust_level = \"trusted\""), "the rest of the file is kept")
    checkEqual(AIClientConfigFiles.tomlCommand(in: added), #"/Applications/SrtFlow "Beta".app/Contents/Helpers/srtflow-mcp"#,
               "a path with quotes round-trips")
    let removed = AIClientConfigFiles.tomlRemoving(from: added)
    check(AIClientConfigFiles.tomlCommand(in: removed) == nil, "the srtflow table is removed")
    check(removed.contains("[projects.\"/Users/me/code\"]"), "removing keeps the other tables")
    checkEqual(AIClientConfigFiles.tomlAdding(command: "/x", to: ""), "[mcp_servers.srtflow]\ncommand = \"/x\"\n",
               "an empty file gets just the table")
}

private func textChecks() {
    checkEqual((try? AIColor.parse("#FF0000"))??.red, 1, "hex red")
    check(abs(((try? AIColor.parse("#00FF0080"))??.opacity ?? 0) - 0.502) < 0.01, "#RRGGBBAA carries alpha")
    checkEqual(try? AIColor.parse("none"), .some(nil), "none removes")
    checkEqual((try? AIColor.parse("white"))??.blue, 1, "colour names work")
    checkThrows("a bad colour is refused") { _ = try AIColor.parse("#GGG") }
    checkEqual(AIColor.hex(SubtitleColor(red: 1, green: 0.5, blue: 0)), "#FF8000", "hex output")

    var overlay = TextOverlay(text: "", timelineStart: 0)
    overlay.style.stroke = TextStroke.default
    let change = try? AITextChange(args([
        "text": "Antarctica", "position": "bottom", "color": "#FFFF00", "stroke_color": "none",
        "background_color": "#000000AA", "animation_in": "pop", "font_size": "120"
    ]))
    change?.apply(to: &overlay)
    checkEqual(overlay.text, "Antarctica", "text lands")
    checkEqual(overlay.centerY, 0.88, "bottom position")
    checkEqual(overlay.style.fill.primaryColor, SubtitleColor(red: 1, green: 1, blue: 0), "fill colour")
    check(overlay.style.stroke == nil, "stroke_color none removes the outline")
    check(overlay.style.background != nil, "background box added")
    checkEqual(overlay.animation.entrance, .pop, "entrance animation")
    checkEqual(overlay.style.fontSize, 120, "numbers written as strings are accepted")
    checkThrows("an unknown position is refused") { _ = try AITextChange(args(["position": "left"])) }

    // 字放不放得下：竖屏 1080 宽、框宽 0.8，110 号的「Antarctica」放不下、被从中间折断；小一号就放下了。
    var title = TextOverlay(text: "南极 Antarctica", timelineStart: 0)
    title.style.fontSize = 110
    let portrait = CGSize(width: 1080, height: 1920)
    checkEqual(AITextFit.brokenWord(in: TextTypesetter.layout(title, canvas: portrait), text: title.text), "Antarctica",
               "a word broken in the middle is reported")
    title.style.fontSize = 70
    check(AITextFit.brokenWord(in: TextTypesetter.layout(title, canvas: portrait), text: title.text) == nil,
          "a smaller size fits and reports nothing")
    var chinese = TextOverlay(text: "这是一段很长很长很长很长很长很长很长的中文标题", timelineStart: 0)
    chinese.style.fontSize = 110
    check(AITextFit.brokenWord(in: TextTypesetter.layout(chinese, canvas: portrait), text: chinese.text) == nil,
          "Chinese wrapping between characters is normal, not a broken word")

    // 文字块出了画面：贴着顶上放、字又大，块的上半截在画面外（2026-09-27 冒烟：「南极探险」折成两行顶出上沿）。
    var high = TextOverlay(text: "南极探险", timelineStart: 0)
    high.style.fontSize = 130
    high.centerY = 0.02
    let out = AITextFit.overflow(of: TextRenderer.layoutFrame(high, canvas: portrait), canvas: portrait)
    check((out?.top ?? 0) > 100, "a text pushed against the top sticks out and says by how much (got \(String(describing: out)))")
    high.centerY = 0.5
    check(AITextFit.overflow(of: TextRenderer.layoutFrame(high, canvas: portrait), canvas: portrait) == nil,
          "the same text in the middle fits")
    checkEqual(AITextFit.describe(.init(top: 12.2, right: 3)), "top by 13 px, right by 3 px", "the overflow is written per edge")
    check(AITextFit.overflow(of: CGRect(x: 0, y: -0.4, width: 100, height: 100), canvas: portrait) == nil,
          "less than half a pixel does not count")
}

private func subtitleEditChecks() {
    var state = TimelineState()
    let first = SubtitleCue(id: UUID(), start: 0, end: 2, text: "one")
    let second = SubtitleCue(id: UUID(), start: 3, end: 5, text: "two")
    var document = SubtitleDocumentModel(format: .srt)
    document.cues = [first, second]
    state.subtitle = document
    let ids = AIShortIDs(state: state)
    let edits = try? AISubtitleEdits.parse(args([
        "changes": [["id": .string(ids.short(first.id)), "text": "uno", "end": 2.5]],
        "add": [["start": 6, "end": 7, "text": "three"]],
        "delete": [.string(ids.short(second.id))]
    ]), ids: ids, in: state)
    let created = edits?.apply(to: &state) ?? []
    let cues = state.subtitleCues(of: .original)
    checkEqual(cues.map(\.text), ["uno", "three"], "text changed, line added, line deleted")
    checkEqual(cues.first?.end, 2.5, "time changed")
    checkEqual(created.count, 1, "the new line's id is returned")
    checkThrows("end before start is refused before anything changes") {
        _ = try AISubtitleEdits.parse(args(["add": [["start": 5, "end": 4, "text": "x"]]]), ids: ids, in: state)
    }
}

private func vocabularyChecks() {
    checkEqual(MCPVocabulary.transitions, ClipTransition.allCases.map(\.rawValue), "transition list matches ClipTransition")
    checkEqual(MCPVocabulary.filterPresetIDs, FilterPreset.allCases.map(\.rawValue), "filter list matches FilterPreset")
    checkEqual(MCPVocabulary.textAnimations, TextAnimationKind.allCases.map(\.rawValue), "text animations match TextAnimationKind")
    checkEqual(MCPVocabulary.frameRates, ProjectFrameRate.allCases.map(\.fps), "frame rates match ProjectFrameRate")
    checkEqual(MCPVocabulary.canvasRatios, CanvasRatio.allCases.map { $0 == .auto ? "auto" : $0.title },
               "canvas ratios match CanvasRatio")
    checkEqual(MCPVocabulary.resolutions, ResolutionLimit.allCases.map { $0.maxShortSide.map { "\($0)p" } ?? "original" },
               "resolutions match ResolutionLimit")
    checkEqual(MCPVocabulary.clipAnimations, ClipPresetKind.allCases.map(\.rawValue), "clip animations match ClipPresetKind")
    checkEqual(MCPVocabulary.soundScenes, ["none"] + SoundSceneKind.allCases.map(\.rawValue), "sound scenes match SoundSceneKind")
    checkEqual(MCPVocabulary.markerColors, MarkerColor.allCases.map(\.rawValue), "marker colours match MarkerColor")
    checkEqual(MCPVocabulary.frameRateLimits, FrameRateLimit.allCases.map { $0.value.map { "\(Int($0))" } ?? "original" },
               "encode frame rates match FrameRateLimit")
    checkEqual(MCPVocabulary.subtitleFormats.sorted(), SubtitleFormat.allCases.map(\.rawValue).sorted(),
               "subtitle formats match SubtitleFormat")
    checkEqual(Set(AIEncodeOptions.crf.keys), Set(MCPVocabulary.encodeQualities), "every advertised quality has a CRF")
    checkEqual(Set(AIEncodeOptions.hardwareQuality.keys), Set(MCPVocabulary.encodeQualities), "and a hardware quality")
    checkEqual(AIClipDetails.presetNames, MCPVocabulary.clipAnimations, "edit_clip reads the same animation names it advertises")
    checkEqual(AIClipDetails.sceneNames, MCPVocabulary.soundScenes, "edit_clip reads the same scene names it advertises")
    for position in MCPVocabulary.textPositions {
        check(AITextPlacement.centerY(for: position) > 0 && AITextPlacement.centerY(for: position) < 1, "\(position) is on screen")
    }
}
