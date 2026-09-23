import Foundation

// MARK: - 28. 音量曲线与推子：取值、编辑、折线表、分割、存盘按需写键与 v19 登记
//
// 长期约束见 docs/architecture/audio-volume-curve.md 与 docs/architecture/audio-mixer.md。
// 这里只测纯值：两条管线真的把曲线 / 推子做出来了，由 scripts/check-audio-fade.sh
// 的「音量曲线与推子」那一组量真实包络。

func checkVolumeCurveAndMixer(root: URL) throws {
    let media = root.appendingPathComponent("curve.m4a")
    try Data("x".utf8).write(to: media)

    func audioClip(start: Double = 0, duration: Double = 10, speed: Double = 1) -> EditClip {
        EditClip(sourceURL: media, isAudioOnly: true, sourceDuration: duration,
                 speed: speed, timelineStart: start, audioAssetDuration: 60)
    }
    func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { abs(a - b) <= tolerance }

    // ---- 取值：dB 线性插值，两端外夹紧 ----
    var clip = audioClip()
    let tol = VolumeCurveEditing.sourceTolerance(speed: 1)
    clip.volumeCurve.set(0, atSourceTime: 1, tolerance: tol)
    clip.volumeCurve.set(-20, atSourceTime: 3, tolerance: tol)
    check(near(clip.volumeLineDecibels(atTimeline: 2), -10), "两点之间按 dB 线性插值（中点 −10 dB）")
    check(near(clip.clipGain(atTimeline: 2), pow(10, -10.0 / 20), 1e-9), "增益是 dB 换回来的线性幅度")
    check(near(clip.volumeLineDecibels(atTimeline: 0.2), 0), "第一个点之前夹在第一个点的值上")
    check(near(clip.volumeLineDecibels(atTimeline: 9), -20), "最后一个点之后夹在最后一个点的值上")
    clip.volume = 1.7
    check(near(clip.clipGain(atTimeline: 9), pow(10, -20.0 / 20), 1e-9), "有曲线时 volume 不参与（曲线取代它）")
    clip.isMuted = true
    checkEqual(clip.clipGain(atTimeline: 2), 0, "静音的段增益是 0，不管曲线")

    // ---- 波形画的「听到的声音」：段增益 × 渐变 × 轨道推子 ----
    var heard = audioClip(start: 2, duration: 10)
    heard.volume = 0.5
    heard.fadeInDuration = 2
    check(near(heard.heardGain(atTimeline: 3, trackGain: 1), 0.25), "渐入一半处 = 0.5 × 0.5")
    check(near(heard.heardGain(atTimeline: 8, trackGain: 2), 1.0), "渐变之后乘上推子（0.5 × 2）")
    heard.isMuted = true
    checkEqual(heard.heardGain(atTimeline: 8, trackGain: 2), 0, "静音的段画成一条线")

    // ---- 加点不改变声音：第一个点取当前的 volume ----
    var flat = audioClip()
    flat.volume = 0.5
    let before = (0..<50).map { flat.clipGain(atTimeline: Double($0) * 0.2) }
    flat.addVolumePoint(atTimeline: 4)
    checkEqual(flat.volumeCurve.keys.count, 1, "加了一个点")
    let after = (0..<50).map { flat.clipGain(atTimeline: Double($0) * 0.2) }
    check(zip(before, after).allSatisfy { near($0, $1, 1e-9) }, "加第一个点前后，整段的声音一处都不变")
    flat.addVolumePoint(atTimeline: 8)
    check(zip(before, (0..<50).map { flat.clipGain(atTimeline: Double($0) * 0.2) })
        .allSatisfy { near($0, $1, 1e-9) }, "加第二个点也不改变声音（取的是此刻线上的值）")

    // ---- 删最后一个点：值固化进 volume，线原地不动 ----
    var single = audioClip()
    single.volumeCurve.set(-12, atSourceTime: 5, tolerance: tol)
    single.removeVolumePoint(at: 0)
    check(single.volumeCurve.isEmpty, "删光了")
    check(near(single.volume, pow(10, -12.0 / 20), 1e-9), "删掉最后一个点时它的值固化进 volume")

    // ---- 挪点：夹在邻点之间、段的窗口之内，dB 夹进合法区间 ----
    var moving = audioClip(start: 0, duration: 10)
    moving.volumeCurve = KeyframeTrack(keys: [
        Keyframe(time: 2, value: 0), Keyframe(time: 5, value: -6), Keyframe(time: 8, value: 0),
    ])
    moving.moveVolumePoint(at: 1, toTimeline: 9.5, decibels: 40)
    let movedKey = moving.volumeCurve.keys[1]
    check(movedKey.time < 8 && movedKey.time > 7.99, "往右拖过了邻点也只能停在邻点左边（不许悄悄换顺序）")
    check(near(movedKey.value, AudioGain.maximumDB), "dB 夹在上限 +6.02")
    moving.moveVolumePoint(at: 0, toTimeline: -3, decibels: -200)
    check(near(moving.volumeCurve.keys[0].time, 0), "往左拖出段外停在段的起点")
    check(near(moving.volumeCurve.keys[0].value, AudioGain.minimumDB), "dB 夹在下限（−∞）")

    // ---- 拖一段线：下面是哪两个点 ----
    var segments = audioClip()
    checkEqual(segments.volumeSegmentIndices(atTimeline: 3), [], "没有点 = 整条水平线（改 volume）")
    segments.volumeCurve = KeyframeTrack(keys: [Keyframe(time: 2, value: 0), Keyframe(time: 6, value: -10)])
    checkEqual(segments.volumeSegmentIndices(atTimeline: 1), [0], "第一个点之前只动第一个点")
    checkEqual(segments.volumeSegmentIndices(atTimeline: 4), [0, 1], "两点之间动两端")
    checkEqual(segments.volumeSegmentIndices(atTimeline: 9), [1], "最后一个点之后只动最后一个点")

    // ---- 平移：每个点各自夹紧，且手势从起手那一份算（不叠加）----
    var origin = segments
    origin.volumeCurve = KeyframeTrack(keys: [Keyframe(time: 2, value: 4), Keyframe(time: 6, value: -10)])
    var shifted = origin
    shifted.shiftWholeVolume(byDecibels: 5)
    check(near(shifted.volumeCurve.keys[0].value, AudioGain.maximumDB), "顶到上限的点停住")
    check(near(shifted.volumeCurve.keys[1].value, -5), "其余的点照走")
    var back = origin
    back.shiftWholeVolume(byDecibels: 0)
    checkEqual(back.volumeCurve, origin.volumeCurve, "从起手那一份算回 0 dB 就是原样")
    var flatShift = audioClip()
    flatShift.shiftWholeVolume(byDecibels: -6)
    check(near(AudioGain.decibels(fromLinear: flatShift.volume), -6, 1e-9), "没曲线时平移的是 volume")

    // ---- 折线表：两条管线共用的那一张 ----
    var ramp = audioClip(start: 3, duration: 10)
    ramp.volumeCurve = KeyframeTrack(keys: [
        Keyframe(time: 1, value: 0), Keyframe(time: 4, value: -40), Keyframe(time: 6, value: 3),
    ])
    let points = VolumeCurveSampling.breakpoints(for: ramp)
    check(near(points.first?.time ?? -1, 0) && near(points.last?.time ?? -1, 10), "折线从段起点铺到段终点")
    check(zip(points, points.dropFirst()).allSatisfy { $1.time > $0.time }, "折线的时刻严格递增")
    let steps = zip(points, points.dropFirst()).map {
        abs(AudioGain.decibels(fromLinear: $1.gain) - AudioGain.decibels(fromLinear: $0.gain))
    }
    check(steps.allSatisfy { $0 <= VolumeCurveSampling.maxDecibelStep + 1e-6 },
          "相邻折点之间不超过 1.5 dB（弦的误差才有上界）")
    var worst = 0.0
    for index in 0...1000 {
        let offset = 10.0 * Double(index) / 1000
        let exact = ramp.clipGain(atTimeline: ramp.timelineStart + offset)
        let chord = VolumeCurveSampling.gain(at: offset, in: points)
        guard exact > AudioGain.linear(fromDecibels: -45) else { continue }
        worst = max(worst, abs(20 * log10(chord / exact)))
    }
    check(worst < 0.05, "折线与 dB 曲线最多差 0.05 dB（量到 \(worst)）")

    // 变速：点锚在源时间上，2 倍速下源 4s 落在时间线偏移 2s。
    var fast = audioClip(duration: 10, speed: 2)
    fast.volumeCurve = KeyframeTrack(keys: [Keyframe(time: 4, value: -30)])
    fast.volumeCurve.set(0, atSourceTime: 0, tolerance: tol)
    check(near(fast.volumeLineDecibels(atTimeline: 2), -30), "2 倍速的段，源 4s 的点落在时间线 2s")
    check(near(fast.volumeLineDecibels(atTimeline: 1), -15), "变速后仍按时间线上的直线插值")

    // ---- 分割：两半各带一份完整曲线，切口两边的线连续 ----
    var splitState = TimelineState()
    var cut = audioClip(duration: 10)
    cut.volumeCurve = KeyframeTrack(keys: [Keyframe(time: 2, value: 0), Keyframe(time: 8, value: -24)])
    splitState.audioTracks = [EditLane(clips: [cut])]
    splitState.split(clipID: cut.id, at: 5)
    let halves = splitState.audioTracks[0].clips
    checkEqual(halves.count, 2, "切成了两段")
    if halves.count == 2 {
        check(near(halves[0].volumeLineDecibels(atTimeline: 5), halves[1].volumeLineDecibels(atTimeline: 5)),
              "切口两边的线接得上（右半带着同一份曲线）")
        checkEqual(halves[1].volumeCurve, cut.volumeCurve, "右半拿到完整的一份点")
    }

    // ---- 分离音频：曲线和渐变跟着声音走 ----
    var video = EditClip(sourceURL: media, sourceDuration: 10, timelineStart: 2)
    video.volume = 0.8
    video.fadeInDuration = 1.5
    video.volumeCurve = cut.volumeCurve
    let detached = video.detachedAudio(linkGroup: UUID())
    checkEqual(detached.volumeCurve, video.volumeCurve, "分离出来的声音带着曲线")
    checkEqual(detached.fadeInDuration, 1.5, "分离出来的声音带着渐入")
    checkEqual(detached.volume, 0.8, "分离出来的声音带着音量")
    checkEqual(detached.isAudioOnly, true, "分离出来的是纯声音段")

    // ---- 块上那条线的几何：纵轴 dB 线性、折点、抓点 ----
    let h = 60.0
    check(near(VolumeCurveLayout.y(forDecibels: AudioGain.maximumDB, height: h), VolumeCurveLayout.inset),
          "+6 dB 在顶上（留 inset）")
    check(near(VolumeCurveLayout.y(forDecibels: AudioGain.minimumDB, height: h), h - VolumeCurveLayout.inset),
          "−∞ 在底下（留 inset）")
    for db in [-60.0, -30, -12, -6, 0, 3, AudioGain.maximumDB] {
        let y = VolumeCurveLayout.y(forDecibels: db, height: h)
        check(near(VolumeCurveLayout.decibels(forY: y, height: h), db, 1e-9), "y ↔ dB 往返（\(db) dB）")
    }
    check(near(VolumeCurveLayout.decibels(forY: -100, height: h), AudioGain.maximumDB), "拖出顶上夹在 +6 dB")
    var drawn = audioClip(start: 5, duration: 10)
    check(VolumeCurveLayout.vertices(for: drawn, pps: 10, height: h).count == 2, "没有点 = 两端一条水平线")
    drawn.volumeCurve = KeyframeTrack(keys: [Keyframe(time: 2, value: 0), Keyframe(time: 30, value: -20)])
    let vertices = VolumeCurveLayout.vertices(for: drawn, pps: 10, height: h)
    checkEqual(vertices.map(\.x), [0, 20, 100], "折点：段两端 + 段内的点（段外那个点只影响插值，不画）")
    let handles = VolumeCurveLayout.handles(for: drawn, pps: 10, height: h)
    checkEqual(handles.map(\.index), [0], "只有段内的点能抓")
    checkEqual(VolumeCurveLayout.handle(at: CGPoint(x: 23, y: handles[0].point.y + 2), clip: drawn, pps: 10, height: h),
               0, "离点 7pt 以内算抓住它")
    checkEqual(VolumeCurveLayout.handle(at: CGPoint(x: 40, y: handles[0].point.y), clip: drawn, pps: 10, height: h),
               nil, "离得远就是线（拖一段）而不是点")

    // ---- 三处共用的 dB 刻度（检查器滑杆 / 音量线 / 推子）----
    checkEqual(AudioGain.scaleFraction(forDecibels: AudioGain.minimumDB), 0, "−∞ 在刻度的最左 / 最下")
    checkEqual(AudioGain.scaleFraction(forDecibels: AudioGain.maximumDB), 1, "+6 dB 在刻度的最右 / 最上")
    check(near(AudioGain.decibels(forScaleFraction: AudioGain.scaleFraction(forDecibels: -12)), -12, 1e-9),
          "刻度往返（−12 dB）")
    checkEqual(AudioGain.decibels(forScaleFraction: 7), AudioGain.maximumDB, "出了刻度夹在两头")

    // ---- 命中区：点的正中间必须点得中（2026-09-23 实机案例）----
    // 点的圆心就压在线上；圆若是 append 进描边路径（而不是 union），重叠处的环绕数正负
    // 抵消成 0，每个点的正中间都点不中。
    // 照实机那条线造：五个点、有平段有斜段，两个点落在段的两头。
    var hitClip = audioClip(start: 5, duration: 10)
    hitClip.volumeCurve = KeyframeTrack(keys: [
        Keyframe(time: 0, value: 0), Keyframe(time: 3, value: -12), Keyframe(time: 5, value: -12),
        Keyframe(time: 7, value: -3), Keyframe(time: 10, value: 0),
    ])
    let hitVertices = VolumeCurveLayout.vertices(for: hitClip, pps: 10, height: h)
    let hitHandles = VolumeCurveLayout.handles(for: hitClip, pps: 10, height: h).map(\.point)
    let hitPath = VolumeCurveLayout.hitPath(vertices: hitVertices, handles: hitHandles)
    checkEqual(hitHandles.count, 5, "命中区用例里五个点都在段内")
    for handle in hitHandles {
        check(hitPath.contains(handle), "点的正中间点得中（\(handle)）")
        check(hitPath.contains(CGPoint(x: handle.x + 3, y: handle.y + 3)), "点的小圆里点得中")
    }
    for vertex in hitVertices {
        check(hitPath.contains(vertex), "线的每个折点上点得中（\(vertex)）")
    }
    let mid = CGPoint(x: (hitVertices[0].x + hitVertices[1].x) / 2, y: (hitVertices[0].y + hitVertices[1].y) / 2)
    check(hitPath.contains(mid), "线段中间点得中")
    check(hitPath.contains(CGPoint(x: mid.x, y: mid.y + VolumeCurveLayout.lineHitRadius - 1)),
          "离线 4pt 以内算点在线上")
    check(!hitPath.contains(CGPoint(x: mid.x, y: mid.y + 20)), "离线 20pt 不算（块的别处照旧归块）")

    // ---- 拖点：跟着指针挪同样的量，不瞬移到指针底下（2026-09-23 实机案例）----
    // 偏着抓（按在点右下 5pt 处）：没挪 = 点原地不动；纯竖着拖 = 时间一丝不动；
    // 横着拖 10pt = 刚好晚 1 秒（pps 10），不是跳到指针底下再算。
    let p1 = hitClip.volumeCurve.keys[1]
    let still = VolumeCurveLayout.dragging(hitClip, point: 1, by: .zero, pps: 10, height: h, lockTime: false)
    checkEqual(still.volumeCurve, hitClip.volumeCurve, "按下没挪：点原地不动（值和时间都一丝不差）")
    let lifted = VolumeCurveLayout.dragging(hitClip, point: 1, by: CGSize(width: 0, height: -10),
                                            pps: 10, height: h, lockTime: false)
    checkEqual(lifted.volumeCurve.keys[1].time, p1.time, "纯竖着拖：时间一丝不动")
    let perPoint = (AudioGain.maximumDB - AudioGain.minimumDB) / (h - 2 * VolumeCurveLayout.inset)
    check(near(lifted.volumeCurve.keys[1].value, p1.value + 10 * perPoint, 1e-9),
          "竖着拖 10pt = 抬 10pt 对应的 dB（量到 \(lifted.volumeCurve.keys[1].value)）")
    let later = VolumeCurveLayout.dragging(hitClip, point: 1, by: CGSize(width: 10, height: 0),
                                           pps: 10, height: h, lockTime: false)
    check(near(later.volumeCurve.keys[1].time, p1.time + 1, 1e-9), "横着拖 10pt = 晚 1 秒（pps 10）")
    checkEqual(later.volumeCurve.keys[1].value, p1.value, "纯横着拖：值一丝不动")
    let locked = VolumeCurveLayout.dragging(hitClip, point: 1, by: CGSize(width: 30, height: -10),
                                            pps: 10, height: h, lockTime: true)
    checkEqual(locked.volumeCurve.keys[1].time, p1.time, "⇧ 拖：时间钉住")
    check(near(locked.volumeCurve.keys[1].value, lifted.volumeCurve.keys[1].value, 1e-9), "⇧ 拖：值照改")
    let squeezed = VolumeCurveLayout.dragging(hitClip, point: 1, by: CGSize(width: 500, height: 0),
                                              pps: 10, height: h, lockTime: false)
    check(squeezed.volumeCurve.keys[1].time < hitClip.volumeCurve.keys[2].time,
          "拖过了下一个点也越不过去（顺序不变，下标稳定）")

    // ---- 推子：取值口与夹紧 ----
    var mixer = TimelineState()
    let voice = audioClip()
    let music = audioClip()
    mixer.mainClips = [EditClip(sourceURL: media, sourceDuration: 4, timelineStart: 0)]
    mixer.audioTracks = [EditLane(clips: [voice]), EditLane(clips: [music])]
    mixer.setTrackVolume(0.5, for: .audio(1))
    mixer.setTrackVolume(7, for: .main)
    mixer.setTrackVolume(0.3, for: .audio(9))
    checkEqual(mixer.trackVolume(for: .audio(1)), 0.5, "写进了第二条音频轨")
    checkEqual(mixer.trackVolume(for: .audio(0)), 1, "第一条不受影响")
    checkEqual(mixer.mainVolume, AudioGain.maximumLinear, "超过 +6 dB 夹在上限")
    checkEqual(mixer.trackVolume(containingClip: music.id), 0.5, "按段找到它所在那条轨的推子")
    checkEqual(mixer.trackVolume(containingClip: UUID()), 1, "找不到的段按 0 dB")

    // ---- 只动了曲线 / 推子 = 只换 audioMix，不重建预览 ----
    var curveEdit = mixer
    curveEdit.audioTracks[0].clips[0].volumeCurve.set(-6, atSourceTime: 1, tolerance: tol)
    check(curveEdit.differsOnlyInAudioMix(from: mixer), "改曲线只换 audioMix（画面不闪）")
    var faderEdit = mixer
    faderEdit.masterVolume = 0.7
    faderEdit.audioTracks[0].volume = 0.2
    check(faderEdit.differsOnlyInAudioMix(from: mixer), "拖推子只换 audioMix（画面不闪）")
    var structural = mixer
    structural.audioTracks[0].clips[0].timelineStart = 3
    check(!structural.differsOnlyInAudioMix(from: mixer), "挪位置仍然要重建")

    // ---- 选段导出：推子跟着轨走（含升上来当主轨的那条）----
    var withOverlay = TimelineState()
    var upper = EditClip(sourceURL: media, sourceDuration: 4, timelineStart: 1)
    upper.info = MediaInfo(duration: 4, displaySize: CGSize(width: 320, height: 180), frameRate: 30,
                           videoCodec: "h264", audioCodec: "aac", hasAudio: true,
                           audioCanCopyToMP4: true, fileBytes: 1)
    withOverlay.overlayTracks = [EditLane(clips: [upper], volume: 0.25)]
    withOverlay.audioTracks = [EditLane(clips: [voice], volume: 1.5)]
    withOverlay.masterVolume = 0.8
    let sub = withOverlay.selectionForExport(ids: [upper.id, voice.id])
    checkEqual(sub.mainVolume, 0.25, "升成主轨的那条带着自己的推子")
    checkEqual(sub.audioTracks.first?.volume, 1.5, "音频轨的推子跟着走")
    checkEqual(sub.masterVolume, 0.8, "总推子跟着走")

    // ---- 存盘：按需写键、往返保真、v19 登记 ----
    var clean = TimelineState()
    clean.audioTracks = [EditLane(clips: [audioClip()])]
    check(!clean.requiresFormatVersion19, "没画曲线、推子都在 0 dB 的工程不是 v19 数据（按需）")

    let file = root.appendingPathComponent("curve.srtflowproj")
    try VideoEditProjectIO.save(clean, to: file)
    let cleanText = try String(contentsOf: file, encoding: .utf8)
    check(!cleanText.contains("volumeCurve"), "没画曲线的段不写 volumeCurve 键")
    check(!cleanText.contains("masterVolume") && !cleanText.contains("mainVolume"),
          "推子没动过不写推子的键")
    let cleanRaw = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
    let cleanLane = ((cleanRaw?["timeline"] as? [String: Any])?["audioTracks"] as? [[String: Any]])?.first
    check(cleanLane != nil && cleanLane?["volume"] == nil, "轨道推子没动过不写键")

    var rich = clean
    rich.audioTracks[0].clips[0].volumeCurve = ramp.volumeCurve
    check(rich.requiresFormatVersion19, "画了曲线 → v19（旧版会把曲线抹掉，成片的声音跟着变）")
    var faderOnly = clean
    faderOnly.audioTracks[0].volume = 0.4
    check(faderOnly.requiresFormatVersion19, "只动了轨道推子也是 v19")
    var masterOnly = clean
    masterOnly.masterVolume = 1.2
    check(masterOnly.requiresFormatVersion19, "只动了总推子也是 v19")
    rich.audioTracks[0].volume = 0.4
    rich.mainVolume = 0.6
    rich.masterVolume = 1.2
    try VideoEditProjectIO.save(rich, to: file)
    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
    // 数字写死 19，不引用 latestFormatVersion：拿常量跟自己比是自反断言。
    checkEqual(raw?["formatVersion"] as? Int, 19, "带曲线 / 推子的工程写 v19")
    let loaded = try VideoEditProjectIO.load(from: file).timeline
    checkEqual(loaded.audioTracks.first?.clips.first?.volumeCurve, ramp.volumeCurve, "曲线往返保真")
    checkEqual(loaded.audioTracks.first?.volume, 0.4, "轨道推子往返保真")
    checkEqual(loaded.mainVolume, 0.6, "主轨推子往返保真")
    checkEqual(loaded.masterVolume, 1.2, "总推子往返保真")
    check(loaded.requiresFormatVersion19, "往返后仍是 v19 数据")

    // 外部改坏的 JSON：越界的 dB 夹回来、越界的推子夹回来，工程照常打开。
    let hostile = root.appendingPathComponent("curve-hostile.srtflowproj")
    try Data("""
    {
      "formatVersion": 19,
      "savedAt": "2026-09-23T10:00:00Z",
      "timeline": {
        "mainClips": [],
        "masterVolume": 9,
        "audioTracks": [
          { "volume": -3,
            "clips": [ { "id": "\(UUID().uuidString)", "sourceURL": "file:///tmp/x.m4a",
                         "isAudioOnly": true, "sourceStart": 0, "sourceDuration": 10,
                         "speed": 1, "timelineStart": 0, "isMuted": false, "volume": 1,
                         "volumeCurve": { "keys": [ { "time": 1, "value": 40 },
                                                    { "time": 2, "value": -200 } ] } } ] }
        ]
      },
      "media": []
    }
    """.utf8).write(to: hostile)
    let repaired = try? VideoEditProjectIO.load(from: hostile).timeline
    let repairedKeys = repaired?.audioTracks.first?.clips.first?.volumeCurve.keys ?? []
    checkEqual(repairedKeys.map(\.value), [AudioGain.maximumDB, AudioGain.minimumDB], "越界的 dB 夹回合法区间")
    checkEqual(repaired?.masterVolume, AudioGain.maximumLinear, "越界的总推子夹回上限")
    checkEqual(repaired?.audioTracks.first?.volume, 0, "负的推子夹成静音")

    // 老工程（v18，没有这些键）→ 推子都是 0 dB、没有曲线。
    let legacy = root.appendingPathComponent("curve-v18.srtflowproj")
    try Data("""
    { "formatVersion": 18, "savedAt": "2026-09-01T10:00:00Z",
      "timeline": { "mainClips": [], "audioTracks": [ { "clips": [] } ] }, "media": [] }
    """.utf8).write(to: legacy)
    let old = try? VideoEditProjectIO.load(from: legacy).timeline
    checkEqual(old?.masterVolume, 1, "v18 老工程的总推子是 0 dB")
    checkEqual(old?.mainVolume, 1, "v18 老工程的主轨推子是 0 dB")
    checkEqual(old?.audioTracks.first?.volume, 1, "v18 老工程的轨道推子是 0 dB")
    check(old?.requiresFormatVersion19 == false, "v18 老工程读进来不该自己变成 v19 数据")
}
