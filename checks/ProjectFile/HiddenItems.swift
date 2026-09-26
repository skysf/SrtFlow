import Foundation
import SrtFlowCore

// 第 24 组：单个隐藏（快捷键 V）。2026-09-26 从 main.swift 搬出来（那个文件只许降），同时扩到文字、
// 形状、滤镜段（它们也有了自己的 `isHidden`）。合同见 docs/architecture/clip-visibility.md。

func checkHiddenItems(root: URL) throws {
    try checkHiddenClips(root: root)
    try checkHiddenOverlays(root: root)
    checkHiddenClipsNotTranscribed(root: root)
}

// 字幕生成：按 V 藏起来的段不许被转写（2026-09-26）。
//
// 隐藏 = 预览和成片里连声音都没有；字幕生成挑素材的可听快照（`SubtitleAudibleClips.soundClips`，
// 探针、metadata、转写、分段全从它取）必须同一个口径。单段的 V 是 2026-09-18 加的，快照当时只滤
// 整轨的眼睛，藏起来的段照样被转写成字幕
// （docs/bugfixes/2026-09-26-subtitle-generation-transcribes-hidden-clips.md）。
//
// 链接关着时只藏了视频、分离出来的音频还显示着：那段声音听得见，照样转写（用户拍板）。
private func checkHiddenClipsNotTranscribed(root: URL) {
    let media = root.appendingPathComponent("hidden-voice.mp4")
    makeFile(media)
    func clip(at start: Double, hidden: Bool = false, audioOnly: Bool = false) -> EditClip {
        var clip = EditClip(sourceURL: media, sourceDuration: 3, timelineStart: start)
        clip.info = MediaInfo(
            duration: 3, displaySize: CGSize(width: 1920, height: 1080), frameRate: 30,
            videoCodec: "h264", audioCodec: "aac", hasAudio: true,
            audioCanCopyToMP4: true, fileBytes: 2048
        )
        clip.isHidden = hidden
        clip.isAudioOnly = audioOnly
        return clip
    }
    let hiddenMain = clip(at: 0, hidden: true)
    let shownMain = clip(at: 4)
    let hiddenUpper = clip(at: 0, hidden: true)
    let hiddenAudio = clip(at: 0, hidden: true, audioOnly: true)
    let shownAudio = clip(at: 4, audioOnly: true)
    // 分离过声音的视频（静音了）被藏起来，分离出来的那段音频还显示着。
    var detachedVideo = clip(at: 8, hidden: true)
    detachedVideo.isMuted = true
    let detachedAudio = clip(at: 8, audioOnly: true)

    var state = TimelineState()
    state.mainClips = [hiddenMain, shownMain, detachedVideo]
    state.overlayTracks = [EditLane(clips: [hiddenUpper])]
    state.audioTracks = [EditLane(clips: [hiddenAudio, shownAudio, detachedAudio])]

    let ids = SubtitleAudibleClips.soundClips(in: state).map(\.clipID)
    checkEqual(Set(ids), [shownMain.id, shownAudio.id, detachedAudio.id],
               "按 V 藏起来的段（主轨 / 上层轨 / 音频轨）不进字幕生成的可听快照；分离出来还显示着的音频照样进")
}

// 剪辑那一级（原第 24 组）：切换规则、渲染过滤、存盘往返与 v16 登记
//
// 隐藏有两级：整轨（眼睛）和单段（V）。这一节守单段那一级的纯值合同，
// 合同全文见 docs/architecture/clip-visibility.md。
//
//   1. 切换规则：一批里**只要还有显示的就全部隐藏**，全藏了才全部放出来。
//      逐个翻转的话，混合状态按一下 V 会一半藏一半现，永远回不到「全显示」。
//   2. 隐藏的段不进「只导出选中的」那份子时间线，**而且不参与起点计算** ——
//      算进来的话，藏在最前面的那段会把整条子时间线往后推，成片开头多一截黑场。
//   3. 选中的全是隐藏段时**不能退回整条时间线**：用户点的是「只导出选中的」，
//      给他整条 = 导出成功但内容根本不是他要的（同 needsStillConversion 那条）。
//   4. 存盘：按需写键（没隐藏的段不落 `isHidden`）、往返无损、缺键读作 false、
//      判据 `requiresFormatVersion16` 与写键同源。
private func checkHiddenClips(root: URL) throws {
    let media = root.appendingPathComponent("hidden.mp4")
    makeFile(media)

    var state = TimelineState()
    var first = EditClip(sourceURL: media, sourceDuration: 3, timelineStart: 0)
    var second = EditClip(sourceURL: media, sourceDuration: 3, timelineStart: 4)
    let third = EditClip(sourceURL: media, sourceDuration: 3, timelineStart: 8)
    state.mainClips = [first, second, third]

    // ---- 1. 切换规则 ----
    checkEqual(ClipVisibility.nextHidden(for: [first.id, second.id], in: state), true,
               "全都显示着 → 按 V 全部隐藏")
    state.setHidden(true, ids: [first.id])
    check(state.clip(with: first.id)?.isHidden == true, "setHidden 真的写进了那一段")
    check(state.clip(with: second.id)?.isHidden == false, "setHidden 不碰名单外的段")
    checkEqual(ClipVisibility.nextHidden(for: [first.id, second.id], in: state), true,
               "一藏一显 → 按 V 统一隐藏（不是逐个翻转）")
    state.setHidden(true, ids: [second.id])
    checkEqual(ClipVisibility.nextHidden(for: [first.id, second.id], in: state), false,
               "全藏着 → 按 V 全部放出来")
    checkEqual(ClipVisibility.visible(state.mainClips).map(\.id), [third.id],
               "visible 只留没藏的那几段")

    // ---- 2/3. 只导出选中的 ----
    //
    // 带上一段音频：只挑主轨内容时 `selectionForExport` 会 `packMain()` 拼紧凑，
    // 位移多少都看不出来。带着音频轨才保持相对位置 —— 这一条才量得到起点。
    state.setHidden(false, ids: [first.id, second.id])
    state.setHidden(true, ids: [first.id])
    var withAudio = state
    let audioClip = EditClip(sourceURL: media, isAudioOnly: true, sourceDuration: 3, timelineStart: 4)
    withAudio.audioTracks = [EditLane(clips: [audioClip])]
    let subset = withAudio.selectionForExport(ids: [first.id, second.id, audioClip.id])
    checkEqual(subset.mainClips.count, 1, "隐藏的段不进「只导出选中的」")
    checkEqual(subset.mainClips.first?.id, second.id, "留下的是没藏的那一段")
    checkEqual(subset.mainClips.first?.timelineStart, 0,
               "起点按真会导出的段算：藏在最前面的那段不许把成片往后推出一截黑场")
    checkEqual(subset.audioTracks.first?.clips.first?.timelineStart, 0,
               "音频跟着同一个起点走，音画不许错位")
    let allHidden = state.selectionForExport(ids: [first.id])
    check(allHidden.mainClips.isEmpty && allHidden.overlayTracks.isEmpty
              && allHidden.audioTracks.isEmpty,
          "选中的全是隐藏段 → 给一份空时间线让导出报错，绝不能退回整条时间线")
    checkEqual(allHidden.frameRate, state.frameRate, "空时间线也要带着工程帧率")

    // ---- 4. 存盘：按需写键、往返、缺键、版本登记 ----
    var clean = TimelineState()
    clean.mainClips = [EditClip(sourceURL: media, sourceDuration: 3, timelineStart: 0)]
    check(!clean.requiresFormatVersion16, "没藏过任何段的工程不是 v16 数据（按需）")
    check(state.requiresFormatVersion16,
          "藏了段的工程 → v16 判据为真（旧版打开那几段会当场回到成片里）")

    let hiddenProject = root.appendingPathComponent("hidden.srtflowproj")
    try VideoEditProjectIO.save(clean, to: hiddenProject)
    let cleanRaw = try JSONSerialization.jsonObject(with: Data(contentsOf: hiddenProject)) as? [String: Any]
    let cleanClip = (((cleanRaw?["timeline"] as? [String: Any])?["mainClips"] as? [[String: Any]]))?.first
    check(cleanClip?["isHidden"] == nil, "没隐藏的段不写 isHidden 键（与判据同源）")
    // 缺键读作 false —— 老工程（v15 及更早）根本没有这个概念，回退值必须是
    // 「它们当时的渲染结果」，否则升级会改变谁已经做好的片子。
    let cleanBack = try VideoEditProjectIO.load(from: hiddenProject).timeline
    checkEqual(cleanBack.mainClips.first?.isHidden, false, "缺键读作 false")

    try VideoEditProjectIO.save(state, to: hiddenProject)
    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: hiddenProject)) as? [String: Any]
    let clips = ((raw?["timeline"] as? [String: Any])?["mainClips"] as? [[String: Any]]) ?? []
    checkEqual(clips.filter { $0["isHidden"] as? Bool == true }.count, 1, "藏了的那一段落了键")
    let back = try VideoEditProjectIO.load(from: hiddenProject).timeline
    checkEqual(back.clip(with: first.id)?.isHidden, true, "往返不丢单段隐藏")
    checkEqual(back.clip(with: second.id)?.isHidden, false, "没藏的段往返后照旧显示")
    check(back.requiresFormatVersion16, "往返后仍是 v16 数据")
}

// 文字、形状、滤镜段（2026-09-26 用户拍板「让它们也能藏」）：和剪辑同一套 V。
//
//   1. 切换规则跨类：一批里混着剪辑、文字、形状、滤镜（框选 / ⌘A），只要还有一个显示的就全部藏；
//   2. 进预览和成片的清单只算一次（`renderedTextOverlays` / `renderedShapes` / `renderedFilters`），
//      藏起来的不在里面，顺序不变（文字按叠放序、滤镜按生效顺序）；此刻生效的滤镜也不算藏起来的；
//   3. 存盘：按需写键、缺键读作 false、往返无损，`requiresFormatVersion22` 与写键同源，写出来是 v22。
private func checkHiddenOverlays(root: URL) throws {
    let media = root.appendingPathComponent("hidden-overlays.mp4")
    makeFile(media)
    var state = TimelineState()
    let clip = EditClip(sourceURL: media, sourceDuration: 6, timelineStart: 0)
    state.mainClips = [clip]
    let low = TextOverlay(text: "low", timelineStart: 0, row: 0)
    let high = TextOverlay(text: "high", timelineStart: 0, row: 1)
    state.textOverlays = [high, low]
    let box = ShapeAnnotation(kind: .rectangle, timelineStart: 1)
    let line = ShapeAnnotation(kind: .line, timelineStart: 2)
    state.shapes = [box, line]
    let base = FilterClip(preset: .tealOrange, timelineStart: 0, duration: 6, layer: 0)
    let top = FilterClip(preset: .coldIron, timelineStart: 0, duration: 6, layer: 1)
    state.filters = [top, base]

    // ---- 1. 切换规则跨类 ----
    let everything: Set<UUID> = [clip.id, low.id, box.id, base.id]
    checkEqual(ClipVisibility.nextHidden(for: everything, in: state), true, "全都显示着 → 按 V 全部藏")
    state.setHidden(true, ids: [low.id, box.id, base.id])
    check(state.textOverlays.first { $0.id == low.id }?.isHidden == true, "setHidden 写进了文字")
    check(state.shapes.first { $0.id == box.id }?.isHidden == true, "setHidden 写进了形状")
    check(state.filters.first { $0.id == base.id }?.isHidden == true, "setHidden 写进了滤镜段")
    check(state.textOverlays.first { $0.id == high.id }?.isHidden == false
              && state.shapes.first { $0.id == line.id }?.isHidden == false
              && state.filters.first { $0.id == top.id }?.isHidden == false,
          "setHidden 不碰名单外的")
    checkEqual(ClipVisibility.nextHidden(for: everything, in: state), true,
               "剪辑还显示着 → 按 V 统一藏（不是逐个翻转）")
    checkEqual(ClipVisibility.nextHidden(for: [low.id, box.id, base.id], in: state), false,
               "选中的全藏着 → 按 V 全部放出来")

    // ---- 2. 进预览和成片的清单 ----
    checkEqual(state.renderedTextOverlays.map(\.id), [high.id], "藏起来的文字不进预览和成片")
    checkEqual(state.renderedShapes.map(\.id), [line.id], "藏起来的形状不进预览和成片")
    checkEqual(state.renderedFilters.map(\.id), [top.id], "藏起来的滤镜段不调色")
    checkEqual(state.activeFilters(at: 3).map(\.id), [top.id], "此刻生效的滤镜不算藏起来的（预览的 CI 链读它）")
    state.setHidden(false, ids: [low.id, base.id])
    checkEqual(state.renderedTextOverlays.map(\.id), [low.id, high.id], "放出来之后照叠放序：行号小的先贴")
    checkEqual(state.renderedFilters.map(\.id), [base.id, top.id], "放出来之后照生效顺序：层号小的先作用")

    // ---- 3. 存盘 ----
    var clean = TimelineState()
    clean.mainClips = [clip]
    clean.textOverlays = [low]
    clean.shapes = [line]
    clean.filters = [top]
    check(!clean.requiresFormatVersion22, "没藏过文字 / 形状 / 滤镜的工程不是 v22 数据（按需）")
    let path = root.appendingPathComponent("hidden-overlays.srtflowproj")
    try VideoEditProjectIO.save(clean, to: path)
    let cleanRaw = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
    let cleanTimeline = cleanRaw?["timeline"] as? [String: Any]
    for key in ["textOverlays", "shapes", "filters"] {
        let items = (cleanTimeline?[key] as? [[String: Any]]) ?? []
        check(!items.isEmpty && items.allSatisfy { $0["isHidden"] == nil }, "没藏的\(key)不写 isHidden 键（与判据同源）")
    }
    let cleanBack = try VideoEditProjectIO.load(from: path).timeline
    check(!cleanBack.textOverlays[0].isHidden && !cleanBack.shapes[0].isHidden && !cleanBack.filters[0].isHidden,
          "缺键读作 false（v21 及更早没有这个概念，那时都是显示的）")

    check(state.requiresFormatVersion22, "藏了文字 / 形状的工程 → v22 判据为真")
    try VideoEditProjectIO.save(state, to: path)
    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
    checkEqual(raw?["formatVersion"] as? Int, 23, "带隐藏的文字 / 形状 / 滤镜的工程写 latest（v23）")
    let back = try VideoEditProjectIO.load(from: path).timeline
    checkEqual(back.shapes.first { $0.id == box.id }?.isHidden, true, "往返不丢形状的隐藏")
    checkEqual(back.textOverlays.first { $0.id == low.id }?.isHidden, false, "放出来的文字往返后照旧显示")
    checkEqual(back.renderedShapes.map(\.id), state.renderedShapes.map(\.id), "往返后进成片的形状一样")
    checkEqual(back.renderedFilters.map(\.id), state.renderedFilters.map(\.id), "往返后生效的滤镜一样")
}
