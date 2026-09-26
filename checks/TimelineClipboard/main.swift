import Foundation
import SrtFlowCore

// 时间线复制 / 剪切 / 粘贴的自检（纯值）。编译方式见 scripts/check-timeline-clipboard.sh。
// 2026-09-26 用户拍板（docs/plans/2026-09-26-timeline-clipboard-and-zoom.md）；长期约束见
// docs/architecture/timeline-clipboard.md。剪辑落到哪条轨的那几组在 Landing.swift。

var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL [line \(line)] \(message)")
    }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String, line: Int = #line) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL [line \(line)] \(message): got \(actual), expected \(expected)")
    }
}

let media = URL(fileURLWithPath: "/tmp/srtflow-clipboard-check/source.mp4")

func clip(_ start: Double, _ duration: Double, audio: Bool = false) -> EditClip {
    EditClip(sourceURL: media, isAudioOnly: audio, sourceDuration: duration, timelineStart: start)
}

/// 编码之后去掉顶层的 id：两样东西「除了身份以外一模一样」就是这两份相等。
func withoutID<Value: Encodable>(_ value: Value) -> NSDictionary? {
    guard let data = try? JSONEncoder().encode(value),
          var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    object["id"] = nil
    return object as NSDictionary
}

/// 粘一次：落点 `anchor`、指着 `row`。
func paste(
    _ payload: TimelineClipboardPayload?, into state: inout TimelineState, at anchor: Double,
    pointing row: TimelinePasteRow? = nil
) -> TimelinePasteResult {
    guard let payload else {
        check(false, "载荷是 nil")
        return TimelinePasteResult()
    }
    return TimelinePaste.apply(payload, to: &state, at: anchor, pointing: row)
}

// MARK: - 1. 拿什么

do {
    var state = TimelineState()
    var a = clip(0, 5), b = clip(5, 5)
    let c = clip(10, 5)
    a.transitionAfter = .crossFade
    b.transitionAfter = .crossFade
    b.needsStillConversion = true
    state.mainClips = [a, b, c]
    let overlay = EditLane(clips: [clip(2, 3)])
    let music = EditLane(clips: [clip(0, 20, audio: true)])
    state.overlayTracks = [overlay]
    state.audioTracks = [EditLane(clips: [clip(40, 1, audio: true)]), music]

    let payload = TimelineClipboardPayload(
        copying: state, clips: [a.id, b.id, overlay.clips[0].id, music.clips[0].id],
        shapes: [], texts: [], cues: [], filters: []
    )
    checkEqual(payload?.clips.map(\.clip.id), [a.id, b.id, overlay.clips[0].id, music.clips[0].id],
               "按时间线上的顺序拿：主轨 → 上层轨 → 音频轨")
    checkEqual(payload?.clips[0].clip.transitionAfter, .crossFade, "A 的下一段 B 也被拿走了：A 的转场留着")
    checkEqual(payload?.clips[1].clip.transitionAfter, ClipTransition.none, "B 的下一段 C 没被拿走：B 的转场不带（另一半不在）")
    checkEqual(payload?.clips[1].needsStillConversion, true, "静帧还没转完的标记单独带着（它不进存盘的编码）")
    checkEqual(payload?.clips[2].lane, .overlay(id: overlay.id, index: 0), "上层轨记身份和第几条")
    checkEqual(payload?.clips[3].lane, .audio(id: music.id, index: 1), "音频轨记身份和第几条")
    checkEqual(payload?.start, 0, "整批最早的开头")
    checkEqual(payload?.end, 20, "整批最晚的结尾")

    check(TimelineClipboardPayload(copying: state, clips: [], shapes: [], texts: [], cues: [], filters: []) == nil,
          "什么都没选：没有载荷（编辑菜单里的拷贝是灰的）")
    if let payload, let data = payload.encoded() {
        checkEqual(TimelineClipboardPayload.decoded(from: data), payload, "载荷往返保真")
        var newer = payload
        newer.version = TimelineClipboardPayload.currentVersion + 1
        check(newer.encoded().flatMap(TimelineClipboardPayload.decoded) == nil,
              "更新版本的载荷认不出就当没有，不硬解出半截")
    } else {
        check(false, "载荷编不出来")
    }
    check(TimelineClipboardPayload.decoded(from: Data("not json".utf8)) == nil, "坏字节当没有")
}

// 字幕句记下在哪条轨、藏没藏。
do {
    var state = TimelineState()
    let original = SubtitleCue(start: 1, end: 2, text: "hello")
    let hiddenOriginal = SubtitleCue(start: 3, end: 4, text: "hidden")
    let translated = SubtitleCue(start: 1, end: 2, text: "你好")
    state.subtitle = SubtitleDocumentModel(cues: [original, hiddenOriginal])
    state.subtitleCompanion = SubtitleCompanion(
        translation: SubtitleDocumentModel(cues: [translated]), hiddenCueIDs: [hiddenOriginal.id]
    )
    let payload = TimelineClipboardPayload(
        copying: state, clips: [], shapes: [], texts: [],
        cues: [original.id, hiddenOriginal.id, translated.id], filters: []
    )
    checkEqual(payload?.cues.map(\.isTranslation), [false, false, true], "字幕句记下在哪条轨")
    checkEqual(payload?.cues.map(\.isHidden), [false, true, false], "藏起来的记着（旁表里的，句子本身不带）")
}

// MARK: - 2. 换新身份：除了 id 每个字段都照抄

do {
    var source = clip(3, 4)
    source.markers = [ClipMarker(sourceTime: 1.25, color: .red, text: "note")]
    source.isHidden = true
    source.remoteKey = "library-123"
    source.speed = 1.5
    source.volume = 0.3
    source.linkGroup = UUID()
    source.placement = ClipPlacement(centerX: 0.4, centerY: 0.6, width: 0.5, height: 0.5)
    let renewed = ClipboardIdentity.renewed(source)
    check(renewed != nil && renewed?.id != source.id, "剪辑换了新身份")
    checkEqual(renewed.flatMap(withoutID), withoutID(source), "剪辑除了 id 每个字段都照抄（标记、隐藏、音频库的键……）")

    let text = TextOverlay(text: "Title", timelineStart: 2, duration: 3, row: 2)
    let renewedText = ClipboardIdentity.renewed(text)
    check(renewedText != nil && renewedText?.id != text.id, "文字换了新身份")
    checkEqual(renewedText.flatMap(withoutID), withoutID(text), "文字除了 id 都照抄")

    let shape = ShapeAnnotation(kind: .rectangle, timelineStart: 1, duration: 2)
    let renewedShape = ClipboardIdentity.renewed(shape)
    check(renewedShape != nil && renewedShape?.id != shape.id, "形状换了新身份")
    checkEqual(renewedShape.flatMap(withoutID), withoutID(shape), "形状除了 id 都照抄")

    let filter = FilterClip(preset: .coldIron, strength: 0.42, timelineStart: 7.5, duration: 2.25, layer: 3)
    let renewedFilter = ClipboardIdentity.renewed(filter)
    check(renewedFilter != nil && renewedFilter?.id != filter.id, "滤镜段换了新身份")
    checkEqual(renewedFilter.flatMap(withoutID), withoutID(filter), "滤镜段除了 id 都照抄（强度、时长、层号）")

    struct NoIdentity: Codable { var name = "x" }
    check(ClipboardIdentity.renewed(NoIdentity()) == nil,
          "编码里没有 id 键就拒绝：宁可粘不出来，也不许粘出两个同身份的东西")
}

// MARK: - 3. 文字 / 滤镜 / 形状 / 字幕句落在哪

do {
    // 文字：指着的那一行（单一来源）→ 那一行空着就落那儿；占着就往上找。
    var state = TimelineState()
    let low = TextOverlay(text: "low", timelineStart: 0, duration: 10, row: 0)
    let high = TextOverlay(text: "high", timelineStart: 20, duration: 5, row: 1)
    state.textOverlays = [low, high]
    let copied = TimelineClipboardPayload(copying: state, clips: [], shapes: [], texts: [high.id], cues: [], filters: [])
    var pasted = paste(copied, into: &state, at: 2, pointing: .textRow(0))
    let first = state.textOverlays.first { pasted.texts.contains($0.id) }
    checkEqual(first?.timelineStart, 2, "左边缘对齐落点")
    checkEqual(first?.row, 1, "指着第 0 行，但 2–7 秒第 0 行被占了 → 往上找到第 1 行（那儿 2–7 秒是空的）")
    pasted = paste(copied, into: &state, at: 2)
    let second = state.textOverlays.first { pasted.texts.contains($0.id) }
    checkEqual(second?.row, 2, "没指着：从原来那一行（1）起往上找，第 1 行这时被刚粘的占了 → 新开第 2 行")

    // 跨工程：原来那一行在这个工程里没有 → 最上面新开一行（同新加一段文字）。
    var other = TimelineState()
    other.textOverlays = [TextOverlay(text: "only", timelineStart: 50, duration: 1, row: 0)]
    var source = TimelineState()
    let row5 = TextOverlay(text: "row5", timelineStart: 0, duration: 1, row: 5)
    source.textOverlays = [row5]
    let crossProject = TimelineClipboardPayload(copying: source, clips: [], shapes: [], texts: [row5.id], cues: [], filters: [])
    pasted = paste(crossProject, into: &other, at: 3)
    checkEqual(other.textOverlays.first { pasted.texts.contains($0.id) }?.row, 1,
               "原来的第 5 行在这个工程里没有：落在现有行的上面一行，不凭空多出几条空行")
}

do {
    // 滤镜：原来那一层起往上找空的；跨工程（那一层不存在）→ 空着的最低层。
    var state = TimelineState()
    let base = FilterClip(preset: .coldIron, timelineStart: 0, duration: 10, layer: 0)
    let top = FilterClip(preset: .warmSun, timelineStart: 0, duration: 10, layer: 1)
    state.filters = [base, top]
    let copied = TimelineClipboardPayload(copying: state, clips: [], shapes: [], texts: [], cues: [], filters: [top.id])
    var pasted = paste(copied, into: &state, at: 20)
    checkEqual(state.filters.first { pasted.filters.contains($0.id) }?.layer, 1, "20 秒处第 1 层空着：回原来那一层")
    pasted = paste(copied, into: &state, at: 5, pointing: .filterLayer(0))
    checkEqual(state.filters.first { pasted.filters.contains($0.id) }?.layer, 2,
               "指着第 0 层，5 秒处第 0、1 层都占着 → 开第 2 层")

    var fresh = TimelineState()
    fresh.filters = [FilterClip(preset: .neon, timelineStart: 100, duration: 1, layer: 0)]
    var source = TimelineState()
    let layer4 = FilterClip(preset: .neon, timelineStart: 0, duration: 2, layer: 4)
    source.filters = [layer4]
    pasted = paste(
        TimelineClipboardPayload(copying: source, clips: [], shapes: [], texts: [], cues: [], filters: [layer4.id]),
        into: &fresh, at: 0
    )
    checkEqual(fresh.filters.first { pasted.filters.contains($0.id) }?.layer, 0,
               "跨工程：原来的第 4 层不存在 → 空着的最低层（同按 +）")
    checkEqual(fresh.filterLayerCount, 1, "不凭空多出空层")
}

do {
    // 形状：平移、换身份，同一行允许重叠。
    var state = TimelineState()
    let shape = ShapeAnnotation(kind: .line, timelineStart: 4, duration: 2)
    state.shapes = [shape]
    let pasted = paste(
        TimelineClipboardPayload(copying: state, clips: [], shapes: [shape.id], texts: [], cues: [], filters: []),
        into: &state, at: 5
    )
    checkEqual(state.shapes.count, 2, "形状粘出一份")
    checkEqual(state.shapes.first { pasted.shapes.contains($0.id) }?.timelineStart, 5, "形状落在落点（和原来那个重叠也行）")
}

do {
    // 字幕句：指着的轨（单一来源）/ 原来那条；藏着的照样藏着；没有原文轨时建一条。
    var state = TimelineState()
    let line = SubtitleCue(start: 1, end: 2, text: "hello")
    let secret = SubtitleCue(start: 3, end: 4, text: "secret")
    state.subtitle = SubtitleDocumentModel(cues: [line, secret])
    state.subtitleCompanion = SubtitleCompanion(
        translation: SubtitleDocumentModel(cues: [SubtitleCue(start: 1, end: 2, text: "你好")]), hiddenCueIDs: [secret.id]
    )
    let copied = TimelineClipboardPayload(copying: state, clips: [], shapes: [], texts: [], cues: [line.id, secret.id], filters: [])
    var pasted = paste(copied, into: &state, at: 10)
    checkEqual(state.subtitle?.cues.count, 4, "没指着：回原文轨")
    let pastedSecret = state.subtitle?.cues.first { pasted.cues.contains($0.id) && $0.text == "secret" }
    checkEqual(pastedSecret?.start, 12, "整批平移：hello 在 10、secret 在 12（间隔不变）")
    checkEqual(pastedSecret.map { state.isSubtitleCueHidden($0.id) }, true, "藏着的粘出来还藏着")
    checkEqual(state.subtitleCompanion?.cueMeta[pastedSecret?.id ?? UUID()]?.origin, .editedManually, "原文轨：出处人工")

    pasted = paste(copied, into: &state, at: 20, pointing: .subtitle(.translation))
    checkEqual(state.subtitleCompanion?.translation?.cues.filter { pasted.cues.contains($0.id) }.count, 2,
               "指着译文轨：原文句粘进译文轨（两条轨独立，粘贴是新句子）")
    checkEqual(state.subtitle?.cues.count, 4, "原文轨这回不动")

    var empty = TimelineState()
    let translatedOnly = TimelineClipboardPayload(copying: {
        var s = TimelineState()
        s.subtitle = SubtitleDocumentModel(cues: [])
        s.subtitleCompanion = SubtitleCompanion(translation: SubtitleDocumentModel(cues: [line]))
        return s
    }(), clips: [], shapes: [], texts: [], cues: [line.id], filters: [])
    pasted = paste(translatedOnly, into: &empty, at: 0)
    checkEqual(empty.subtitle?.cues.map(\.text), ["hello"], "没有字幕的工程：建一条原文轨，译文句也落进原文轨")
    checkEqual(pasted.cues.count, 1, "粘出来的句子记在结果里（粘完选中它）")
}

do {
    // 落点是负数当 0；整批按最早的开头对齐。
    var state = TimelineState()
    let early = TextOverlay(text: "a", timelineStart: 5, duration: 1, row: 0)
    let late = TextOverlay(text: "b", timelineStart: 8, duration: 1, row: 0)
    state.textOverlays = [early, late]
    let pasted = paste(
        TimelineClipboardPayload(copying: state, clips: [], shapes: [], texts: [early.id, late.id], cues: [], filters: []),
        into: &state, at: -3
    )
    let starts = state.textOverlays.filter { pasted.texts.contains($0.id) }.map(\.timelineStart).sorted()
    checkEqual(starts, [0, 3], "负的落点当 0，两段之间的间隔（3 秒）不变")
}

checkClipLanding()

// MARK: - 4. 分割也不许丢段自己的标记（同一条教训：手写「照抄每个字段」迟早漏）
//
// 2026-09-26 写复制粘贴时发现：`split` 手写构造右半段，漏了 `isHidden`（藏着的段切开，右半冒进预览和成片）
// 和 `remoteKey`（音频库素材的右半缓存一清就永久失链）。案例 docs/bugfixes/2026-09-26-split-drops-hidden-and-library-key.md。
do {
    var state = TimelineState()
    var hidden = EditClip(sourceURL: media, sourceDuration: 6, timelineStart: 0, remoteKey: "library-42")
    hidden.isHidden = true
    state.mainClips = [hidden]
    state.split(clipID: hidden.id, at: 2)
    checkEqual(state.mainClips.map(\.isHidden), [true, true], "藏着的段切开：两半都还藏着（右半不许冒进成片）")
    checkEqual(state.mainClips.map(\.remoteKey), ["library-42", "library-42"],
               "音频库素材切开：两半都带着 manifest 的键（重链接的第一层线索）")
}

// MARK: - 收尾

print("TimelineClipboard checks: \(checks) 项，失败 \(failures) 项")
if failures > 0 {
    exit(1)
}
print("OK")
