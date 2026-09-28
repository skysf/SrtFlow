import Foundation
import SrtFlowCore

// 第 37 组：工程自己的字幕样式和逐词高亮（2026-09-28，方案第 38、54 条）。
// `projectSubtitleStyle`、`subtitleHighlight`、`SubtitleCue.words` 是 v25 数据：都按需写键、判据和写键同源、存得回来；
// 用样式都问 `subtitleStyle(appWide:)`（有工程自己的就用它）；预览和烧录共用的字幕块带着高亮。
// 编法见 scripts/check-project-file.sh。

func checkSubtitleLook(root: URL) throws {
    var state = TimelineState()
    state.subtitle = SubtitleDocumentModel(cues: [SubtitleCue(start: 0, end: 2, text: "big news")])
    check(!state.requiresFormatVersion25, "没设样式、没高亮、句子没有词的时间：不是 v25 数据（按需）")
    let path = root.appendingPathComponent("subtitle-look.srtflowproj")
    try VideoEditProjectIO.save(state, to: path)
    let cleanTimeline = (try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])?["timeline"] as? [String: Any]
    check(cleanTimeline?["projectSubtitleStyle"] == nil && cleanTimeline?["subtitleHighlight"] == nil, "没设的不写键（与判据同源）")

    let appWide = BurnInStyle.default
    checkEqual(state.subtitleStyle(appWide: appWide), appWide, "没有工程自己的样式：用全 App 的")
    var own = BurnInStyle.builtInPresets[2]
    own.position = .topCenter
    own.fontSize = 72
    state.projectSubtitleStyle = own
    checkEqual(state.subtitleStyle(appWide: appWide), own, "有工程自己的样式：用它")
    check(state.requiresFormatVersion25, "工程自己的样式 → v25")

    state.projectSubtitleStyle = nil
    state.subtitle?.cues[0].words = [SubtitleCueWord(location: 4, length: 4, start: 0.5, end: 1.0)]
    check(state.requiresFormatVersion25, "句子带词的时间 → v25（丢了之后再打开高亮也亮不起来）")
    state.subtitle?.cues[0].words = nil
    state.subtitleHighlight = SubtitleWordHighlight(color: .yellow, scale: 1.2)
    check(state.requiresFormatVersion25, "逐词高亮 → v25")

    state.projectSubtitleStyle = own
    state.subtitle?.cues[0].words = [SubtitleCueWord(location: 4, length: 4, start: 0.5, end: 1.0)]
    try VideoEditProjectIO.save(state, to: path)
    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
    checkEqual(raw?["formatVersion"] as? Int, 25, "带工程样式、高亮、词时间的工程写 v25")
    let back = try VideoEditProjectIO.load(from: path).timeline
    checkEqual(back.projectSubtitleStyle, own, "往返不丢工程自己的样式")
    checkEqual(back.subtitleHighlight, state.subtitleHighlight, "往返不丢高亮的颜色和倍数")
    checkEqual(back.subtitle?.cues.first?.words, state.subtitle?.cues.first?.words, "往返不丢词的时间")

    // 预览和烧录共用的那一块带着高亮：说「news」那一刻它亮着，烧录的事件在那一刻切开。
    let block = back.subtitleScreenBlocks()[0]
    checkEqual(block.display(at: 0.7)?.highlights, [SubtitleTextRange(location: 4, length: 4)], "字幕块：说到的词亮着")
    checkEqual(block.display(at: 0.2)?.highlights, [], "字幕块：还没说到时不亮")
    let render = block.renderBlock
    checkEqual(render.cues.map(\.start), [0, 0.5, 1.0], "烧录：在词开口、说完的那一刻切开")
    check(render.highlight != nil && render.highlights.count == 1, "烧录：中间那一段带着亮的词")
    var off = back
    off.subtitleHighlight = nil
    checkEqual(off.subtitleScreenBlocks()[0].renderBlock.cues.count, 1, "关了高亮：整句一段，和以前一样")
}
