import Foundation
import SrtFlowCore

// MARK: - 40. 标记：所有块 + 标尺（VideoEditClipMarker.swift、VideoEditMarkerTargets.swift、EditSelection.rulerSelected）
//
// 2026-09-30 用户拍板：轨道里所有块（文字 / 形状 / 滤镜段）都能打标记，标尺也能；点标尺 = 选中标尺，
// 之后 M 打在标尺上。这里钉：叠层类块的锚定（离起点多少秒；挪窝跟着走、裁头留在原处、裁出窗口藏不删）、
// 标尺锚在时间线上（片尾以后也算）；TimelineState 按归属增删改查与选择判据、容差按速度；M 的落点；
// 标尺选中的互斥（不算「有东西可删」）；存盘往返 + v28 按需登记。长期约束：docs/architecture/clip-markers.md。

func checkMarkersEverywhere(root: URL) throws {
    let tol = KeyframeTrack.sourceTolerance(frameRate: .fps30, speed: 1)
    let media = root.appendingPathComponent("markers-everywhere.mov")
    makeFile(media)

    // ---- 叠层类的块：锚在离起点多少秒 ----
    var text = TextOverlay(text: "t", timelineStart: 10, duration: 6)
    check(text.addMarker(atTimeline: 12, color: .red, tolerance: tol) != nil, "文字块上在 12 秒打一枚")
    checkEqual(text.markers.first?.sourceTime, 2, "记的是离块起点 2 秒")
    checkEqual(text.markers.first.map(text.timelineTime(of:)), 12, "换算回时间线是 12 秒")
    check(text.addMarker(atTimeline: 12.01, color: .red, tolerance: tol) == nil, "同一帧上不叠第二枚")
    check(text.addMarker(atTimeline: 20, color: .red, tolerance: tol) == nil, "块外面打不上")
    text.timelineStart = 30
    checkEqual(text.markers.first.map(text.timelineTime(of:)), 32, "挪窝：标记跟着块走")
    text.timelineStart += 1; text.duration -= 1; text.keepMarkersInPlace(afterLeadingTrim: 1)
    checkEqual(text.markers.first?.sourceTime, 1, "裁头 1 秒后离起点 1 秒")
    checkEqual(text.markers.first.map(text.timelineTime(of:)), 32, "……所以还在时间线 32 秒（裁头不挪标记）")
    text.timelineStart += 3; text.duration -= 3; text.keepMarkersInPlace(afterLeadingTrim: 3)
    checkEqual(text.visibleMarkers.count, 0, "裁过头了就不画")
    checkEqual(text.markers.count, 1, "但不删（撤销裁切要能回来）")
    text.timelineStart -= 3; text.duration += 3; text.keepMarkersInPlace(afterLeadingTrim: -3)
    checkEqual(text.visibleMarkers.count, 1, "拉回来又画出来了")
    text.duration = 1
    checkEqual(text.markers.first?.sourceTime, 1, "裁尾不改标记")
    checkEqual(text.visibleMarkers.count, 1, "1 秒处正好在窗口边上（半毫秒容差）还画")

    var shape = ShapeAnnotation(kind: .rectangle, timelineStart: 5, duration: 4)
    check(shape.addMarker(atTimeline: 7, color: .blue, tolerance: tol) != nil, "形状块也能打")
    checkEqual(shape.markers.first?.sourceTime, 2, "形状同样记离起点多少秒")
    var filter = FilterClip(preset: .coldIron, timelineStart: 2, duration: 3)
    check(filter.addMarker(atTimeline: 4.5, color: .green, tolerance: tol) != nil, "滤镜段也能打")
    checkEqual(filter.markers.first?.sourceTime, 2.5, "滤镜段同样记离起点多少秒")
    checkEqual(shape.visibleMarkers.count + filter.visibleMarkers.count, 2, "都在窗口里")

    // ---- 标尺：锚在时间线上 ----
    var ruler = RulerMarkerHost(markers: [])
    check(ruler.addMarker(atTimeline: 123.4, color: .green, tolerance: tol) != nil, "标尺上任何时刻都能打（片尾以后也算）")
    checkEqual(ruler.markers.first?.sourceTime, 123.4, "标尺标记记的就是时间线秒数")
    checkEqual(ruler.markers.first.map(ruler.timelineTime(of:)), 123.4, "换算是恒等")
    check(ruler.addMarker(atTimeline: -1, color: .green, tolerance: tol) == nil, "0 以前打不上")

    // ---- TimelineState 按归属增删改查 ----
    var state = TimelineState()
    let clip = EditClip(sourceURL: media, sourceDuration: 10)
    state.mainClips = [clip]
    let t = TextOverlay(text: "a", timelineStart: 1, duration: 3)
    let sh = ShapeAnnotation(kind: .line, timelineStart: 1, duration: 3)
    let f = FilterClip(preset: .coldIron, timelineStart: 1, duration: 3)
    state.textOverlays = [t]; state.shapes = [sh]; state.filters = [f]
    let owners: [MarkerOwner] = [.clip(clip.id), .text(t.id), .shape(sh.id), .filter(f.id), .ruler]
    let refs = owners.compactMap {
        state.addMarker(to: $0, atTimeline: 2, color: .orange, tolerance: state.markerTolerance(for: $0))
    }
    checkEqual(refs.count, 5, "五种归属各打上一枚")
    checkEqual(refs.map(\.owner), owners, "引用带着归属")
    for ref in refs {
        check(state.isMarkerSelectable(ref), "刚打上的都能选中：\(ref.owner)")
        state.updateMarker(ref) { $0.text = "n"; $0.color = .yellow }
        checkEqual(state.marker(ref)?.text, "n", "备注写得进去：\(ref.owner)")
        checkEqual(state.marker(ref)?.color, .yellow, "颜色换得掉：\(ref.owner)")
    }
    checkEqual(state.rulerMarkers.count, 1, "标尺的那枚落在 rulerMarkers 里")
    check(state.hasClipMarkers && state.hasMarkersBeyondClips, "两份「有没有标记」都为真")
    state.textOverlays = []
    check(!state.isMarkerSelectable(refs[1]) && state.marker(refs[1]) == nil, "文字删掉了，它的标记就选不中、也查不到")
    state.removeMarker(refs[4])
    checkEqual(state.rulerMarkers.count, 0, "删标尺标记要真的删掉")
    check(!state.isMarkerSelectable(refs[4]), "删掉之后选择判据为假")
    state.removeMarker(refs[2]); state.removeMarker(refs[3])
    check(!state.hasMarkersBeyondClips && state.hasClipMarkers, "文字 / 形状 / 滤镜 / 标尺都没了就不算「素材段以外有标记」")
    state.updateMarker(refs[4]) { $0.text = "ghost" }
    checkEqual(state.rulerMarkers.count, 0, "改一枚已经不在的标记什么都不做")

    // ---- 容差按速度（只有素材段有变速） ----
    var fast = EditClip(sourceURL: media, sourceDuration: 10)
    fast.speed = 2
    state.mainClips = [fast]
    checkEqual(state.markerTolerance(for: .clip(fast.id)),
               KeyframeTrack.sourceTolerance(frameRate: state.frameRate, speed: 2), "素材段的容差按它的速度")
    checkEqual(state.markerTolerance(for: .ruler),
               KeyframeTrack.sourceTolerance(frameRate: state.frameRate, speed: 1), "标尺按 1 倍速")

    // ---- 选择：标尺选中 ----
    var s = EditSelection()
    s.selectClips([clip.id])
    s.selectRuler()
    check(s.rulerSelected, "选标尺要生效")
    checkEqual(s.clipIDs, [], "选标尺清剪辑（选中什么就只有它）")
    check(s.isEmpty, "标尺不算「有东西可删」：⌫ 和垃圾桶照旧不理")
    s.selectText(t.id)
    check(!s.rulerSelected, "点块取消标尺选中")
    s.selectRuler()
    s.selectMarker(MarkerRef(owner: .ruler, markerID: UUID()))
    check(!s.rulerSelected && s.markerRef != nil, "选标记也清掉标尺选中（M 看的是标记的归属）")
    s.selectRuler()
    s.selectBox(clips: [], shapes: [], texts: [], cues: [], filters: [])
    check(!s.rulerSelected, "框选（哪怕是空框）/ ⌘A 清掉标尺选中")
    s.selectRuler(); s.clear()
    check(!s.rulerSelected, "点空白清掉")
    s.selectRuler(); s.selectClips([])
    check(s.rulerSelected, "把剪辑选择清空不等于改选，别动标尺")

    // ---- M 的落点 ----
    var st = TimelineState()
    let main = EditClip(sourceURL: media, sourceDuration: 10)
    let upper = EditClip(sourceURL: media, sourceDuration: 10)
    st.mainClips = [main]; st.overlayTracks = [EditLane(clips: [upper])]
    let tx = TextOverlay(text: "a", timelineStart: 2, duration: 3)
    let shp = ShapeAnnotation(kind: .rectangle, timelineStart: 2, duration: 3)
    let fl = FilterClip(preset: .coldIron, timelineStart: 2, duration: 3)
    st.textOverlays = [tx]; st.shapes = [shp]; st.filters = [fl]
    var sel = EditSelection()
    func targets(_ time: Double) -> [MarkerOwner] { MarkerTargets.atPlayhead(time, selection: sel, state: st) }
    checkEqual(targets(3), [.clip(main.id)], "什么都没选：主轨播放头下那段")
    checkEqual(targets(12), [], "播放头下没有段：哪儿都不打（按钮灰）")
    sel.selectTexts([tx.id])
    checkEqual(targets(3), [.text(tx.id)], "选中的文字被播放头穿过：打文字")
    checkEqual(targets(8), [.clip(main.id)], "选中的文字不在播放头下：退回主轨那段")
    sel.selectShapes([shp.id])
    checkEqual(targets(3), [.shape(shp.id)], "选中的形状：打形状")
    sel.selectFilters([fl.id])
    checkEqual(targets(3), [.filter(fl.id)], "选中的滤镜段：打滤镜段")
    sel.selectClips([upper.id])
    checkEqual(targets(3), [.clip(upper.id)], "选中上层轨那段：打它，不退回主轨")
    sel.selectBox(clips: [main.id, upper.id], shapes: [shp.id], texts: [tx.id], cues: [], filters: [fl.id])
    checkEqual(Set(targets(3)), Set([.clip(main.id), .clip(upper.id), .text(tx.id), .shape(shp.id), .filter(fl.id)]),
               "框选的一片：被播放头穿过的每一块各打一枚")
    sel.selectRuler()
    checkEqual(targets(3), [.ruler], "标尺选中着：只打标尺，哪怕播放头下有段")
    checkEqual(targets(99), [.ruler], "标尺选中着：片尾以后也打（按钮亮）")
    sel.selectMarker(MarkerRef(owner: .ruler, markerID: UUID()))
    checkEqual(targets(3), [.ruler], "选中的是一枚标尺标记：也算标尺")
    sel.selectMarker(MarkerRef(owner: .clip(main.id), markerID: UUID()))
    checkEqual(targets(3), [.clip(main.id)], "选中的是块上的标记：按老规矩退回主轨那段")

    // ---- 存盘往返 + v28 按需登记 ----
    let project = root.appendingPathComponent("markers-everywhere.srtflowproj")
    var save = TimelineState()
    save.mainClips = [EditClip(sourceURL: media, sourceDuration: 10)]
    save.textOverlays = [TextOverlay(text: "a", timelineStart: 1, duration: 3)]
    save.shapes = [ShapeAnnotation(kind: .rectangle, timelineStart: 1, duration: 3)]
    save.filters = [FilterClip(preset: .coldIron, timelineStart: 1, duration: 3)]
    check(!save.requiresFormatVersion28, "没打过就不是 v28 数据")
    try VideoEditProjectIO.save(save, to: project)
    let cleanJSON = try String(contentsOf: project, encoding: .utf8)
    check(!cleanJSON.contains("\"markers\"") && !cleanJSON.contains("\"rulerMarkers\""),
          "一枚都没有：文字 / 形状 / 滤镜不写 markers 键、工程不写 rulerMarkers 键")
    save.update(save.mainClips[0].id) { $0.addMarker(atTimeline: 1, color: .red, tolerance: tol) }
    check(save.requiresFormatVersion8 && !save.requiresFormatVersion28, "只有素材段上有：是 v8 数据、不是 v28")
    let beyond: [MarkerOwner] = [.text(save.textOverlays[0].id), .shape(save.shapes[0].id), .filter(save.filters[0].id), .ruler]
    for owner in beyond {
        var one = save
        check(one.addMarker(to: owner, atTimeline: 2, color: .purple, tolerance: tol) != nil, "打得上：\(owner)")
        check(one.requiresFormatVersion28, "\(owner) 上有标记 → v28 判据为真（旧版打开会把它抹掉）")
    }
    for owner in beyond {
        let ref = save.addMarker(to: owner, atTimeline: 2, color: .purple, tolerance: tol)
        if let ref { save.updateMarker(ref) { $0.text = "重点 \(owner)" } }
    }
    try VideoEditProjectIO.save(save, to: project)
    let json = try String(contentsOf: project, encoding: .utf8)
    check(json.range(of: #""formatVersion"\s*:\s*30"#, options: .regularExpression) != nil, "写出去的是 latest（v30）")
    let loaded = try VideoEditProjectIO.load(from: project).timeline
    let pairs: [(String, [ClipMarker], [ClipMarker])] = [
        ("文字", save.textOverlays[0].markers, loaded.textOverlays.first?.markers ?? []),
        ("形状", save.shapes[0].markers, loaded.shapes.first?.markers ?? []),
        ("滤镜", save.filters[0].markers, loaded.filters.first?.markers ?? []),
        ("标尺", save.rulerMarkers, loaded.rulerMarkers),
    ]
    for (name, before, after) in pairs {
        checkEqual(after, before, "\(name)上的标记往返存住（位置、颜色、备注、身份）")
    }
    var stripped = loaded
    for owner in beyond { stripped.updateMarkers(of: owner) { $0 = [] } }
    check(!stripped.requiresFormatVersion28 && stripped.requiresFormatVersion8, "标尺以外都删光的工程要能退回非 v28（按需登记）")
}
