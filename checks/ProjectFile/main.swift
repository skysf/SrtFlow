import Foundation
import SrtFlowCore

// 工程存盘 / 素材重链接的自检。编译方式见同目录的 run.sh。

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

let manager = FileManager.default
let root = manager.temporaryDirectory.appendingPathComponent("srtflow-projcheck-\(UUID().uuidString)")

func makeFile(_ url: URL, bytes: Int = 2048) {
    try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data(repeating: 7, count: bytes).write(to: url)
}

func timeline(mainMedia: [URL], subtitle: URL? = nil) -> TimelineState {
    var state = TimelineState()
    var cursor = 0.0
    for url in mainMedia {
        var clip = EditClip(sourceURL: url, sourceDuration: 12, timelineStart: cursor)
        clip.transitionAfter = .crossFade
        clip.placement = ClipPlacement(centerX: 0.4, centerY: 0.6, width: 0.5, height: 0.3)
        clip.rotationDegrees = 15
        clip.opacity = 0.8
        clip.flippedHorizontally = true
        clip.crop = ClipCrop(top: 0.1, leading: 0.05)
        var animation = ClipAnimation()
        let tol = KeyframeTrack.sourceTolerance(frameRate: .fps30, speed: clip.speed)
        animation.centerX.set(0.3, atSourceTime: 1, tolerance: tol)
        animation.centerX.set(0.7, atSourceTime: 3, tolerance: tol)
        animation.opacity.set(1, atSourceTime: 0, tolerance: tol)
        animation.opacity.set(0.2, atSourceTime: 4, tolerance: tol)
        clip.animation = animation
        clip.info = MediaInfo(
            duration: 12,
            displaySize: CGSize(width: 1920, height: 1080),
            frameRate: 30,
            videoCodec: "h264",
            audioCodec: "aac",
            hasAudio: true,
            audioCanCopyToMP4: true,
            fileBytes: 2048
        )
        state.mainClips.append(clip)
        cursor = clip.timelineEnd
    }
    state.subtitleURL = subtitle
    state.canvasRatio = .tall9x16
    state.shapes = [ShapeAnnotation(kind: .square, timelineStart: 1, width: 0.25)]
    return state
}

// MARK: - 1. 原样存取

do {
    let dir = root.appendingPathComponent("roundtrip")
    let media = dir.appendingPathComponent("a.mp4")
    makeFile(media)
    let project = dir.appendingPathComponent("p.srtflowproj")

    let original = timeline(mainMedia: [media])
    try VideoEditProjectIO.save(original, to: project)
    let result = try VideoEditProjectIO.load(from: project)

    checkEqual(result.timeline, original, "存下去再读回来，时间线应当完全一样")
    check(result.missingMedia.isEmpty, "素材都在原地，不该报丢失")
    check(!result.didRelink, "素材没动过，不该触发重链接")
    checkEqual(result.timeline.canvasRatio, .tall9x16, "画布比例要存住")
    checkEqual(result.timeline.shapes.count, 1, "形状标注要存住")
    checkEqual(result.timeline.mainClips.first?.transitionAfter, .crossFade, "转场要存住")
    checkEqual(result.timeline.mainClips.first?.info?.frameRate, 30, "探测信息要存住")
    checkEqual(
        result.timeline.mainClips.first?.placement,
        ClipPlacement(centerX: 0.4, centerY: 0.6, width: 0.5, height: 0.3),
        "预览里摆的位置/大小要存住"
    )
    checkEqual(result.timeline.mainClips.first?.rotationDegrees, 15, "旋转角要存住")
    checkEqual(result.timeline.mainClips.first?.opacity, 0.8, "不透明度要存住")
    checkEqual(result.timeline.mainClips.first?.flippedHorizontally, true, "翻转要存住")
    checkEqual(
        result.timeline.mainClips.first?.crop,
        ClipCrop(top: 0.1, leading: 0.05),
        "四边裁切要存住"
    )
    checkEqual(
        result.timeline.mainClips.first?.animation?.centerX.keys.count, 2,
        "关键帧轨要存住"
    )
    checkEqual(
        result.timeline.mainClips.first?.animation?.centerX.value(atSourceTime: 2), 0.5,
        "读回来的关键帧插值要一致"
    )
}

// MARK: - 1b. 乱序存盘的主轨 —— 打开时归一成时间顺序

// 老版本磁吸关掉的拖动只改 timelineStart 不重排数组，存出来的工程主轨
// 数组顺序 ≠ 时间顺序 —— A/B 合成轨按数组顺序插入会被挤歪（黑屏）。
// 打开工程必须治好这种文件。
do {
    let dir = root.appendingPathComponent("unordered-main")
    let media = dir.appendingPathComponent("a.mp4")
    makeFile(media)
    let project = dir.appendingPathComponent("p.srtflowproj")

    var disordered = timeline(mainMedia: [media])
    var late = disordered.mainClips[0]
    late = EditClip(sourceURL: late.sourceURL, sourceDuration: 4, timelineStart: 30, info: late.info)
    var early = disordered.mainClips[0]
    early = EditClip(sourceURL: early.sourceURL, sourceDuration: 4, timelineStart: 20, info: early.info)
    disordered.mainClips = [late, early]
    try VideoEditProjectIO.save(disordered, to: project)
    let result = try VideoEditProjectIO.load(from: project)

    checkEqual(
        result.timeline.mainClips.map(\.timelineStart), [20, 30],
        "乱序存盘的主轨打开时要按时间顺序归一"
    )
    checkEqual(
        Set(result.timeline.mainClips.map(\.id)), Set([late.id, early.id]),
        "归一只调顺序，不许丢段"
    )
}

// MARK: - 2. 素材改了名 —— 靠书签找回来

do {
    let dir = root.appendingPathComponent("renamed")
    let media = dir.appendingPathComponent("before.mp4")
    makeFile(media)
    let project = dir.appendingPathComponent("p.srtflowproj")
    try VideoEditProjectIO.save(timeline(mainMedia: [media]), to: project)

    let renamed = dir.appendingPathComponent("after.mp4")
    try manager.moveItem(at: media, to: renamed)

    let result = try VideoEditProjectIO.load(from: project)
    check(result.missingMedia.isEmpty, "改名后不该报丢失")
    check(result.didRelink, "改名后应当报告发生了重链接")
    checkEqual(
        result.timeline.mainClips.first?.sourceURL.lastPathComponent,
        "after.mp4",
        "引用应当指向改名后的文件"
    )
}

// MARK: - 3. 素材移去了别的文件夹 —— 还是靠书签

do {
    let dir = root.appendingPathComponent("moved")
    let media = dir.appendingPathComponent("clip.mp4")
    makeFile(media)
    let project = dir.appendingPathComponent("p.srtflowproj")
    try VideoEditProjectIO.save(timeline(mainMedia: [media]), to: project)

    // 挪到工程目录外面，名字也换掉：只有书签能找到它。
    let elsewhere = root.appendingPathComponent("far-away/deep/renamed-clip.mp4")
    try manager.createDirectory(at: elsewhere.deletingLastPathComponent(), withIntermediateDirectories: true)
    try manager.moveItem(at: media, to: elsewhere)

    let result = try VideoEditProjectIO.load(from: project)
    check(result.missingMedia.isEmpty, "移动 + 改名后不该报丢失")
    checkEqual(
        result.timeline.mainClips.first?.sourceURL.standardizedFileURL.path,
        elsewhere.standardizedFileURL.path,
        "引用应当指向移动后的新位置"
    )
}

// MARK: - 4. 工程和素材整个文件夹一起被拷走，原件删掉 —— 靠相对路径

do {
    let source = root.appendingPathComponent("bundle-a")
    let media = source.appendingPathComponent("footage/scene.mp4")
    makeFile(media)
    let project = source.appendingPathComponent("edit.srtflowproj")
    try VideoEditProjectIO.save(timeline(mainMedia: [media]), to: project)

    // 拷贝出一份（新 inode），再把原件整个删掉 —— 书签就失效了。
    let copy = root.appendingPathComponent("bundle-b")
    try manager.copyItem(at: source, to: copy)
    try manager.removeItem(at: source)

    let result = try VideoEditProjectIO.load(from: copy.appendingPathComponent("edit.srtflowproj"))
    check(result.missingMedia.isEmpty, "整个文件夹搬走后不该报丢失")
    check(result.didRelink, "路径变了，应当报告重链接")
    checkEqual(
        result.timeline.mainClips.first?.sourceURL.standardizedFileURL.path,
        copy.appendingPathComponent("footage/scene.mp4").standardizedFileURL.path,
        "引用应当指向拷贝出来的那份素材"
    )
}

// MARK: - 5. 素材被拷到别处但换了目录结构 —— 靠同名搜索

do {
    let source = root.appendingPathComponent("searchable")
    let media = source.appendingPathComponent("raw/take1.mp4")
    makeFile(media)
    let project = source.appendingPathComponent("edit.srtflowproj")
    try VideoEditProjectIO.save(timeline(mainMedia: [media]), to: project)

    // 换个子目录名：相对路径 raw/take1.mp4 对不上了，但文件名和大小还在。
    try manager.moveItem(at: source.appendingPathComponent("raw"), to: source.appendingPathComponent("footage"))
    // 断开书签：删掉原文件，换一个同名同大小的新文件。
    let moved = source.appendingPathComponent("footage/take1.mp4")
    try manager.removeItem(at: moved)
    makeFile(moved)

    let result = try VideoEditProjectIO.load(from: project)
    check(result.missingMedia.isEmpty, "同名同大小的素材应当能搜到")
    checkEqual(
        result.timeline.mainClips.first?.sourceURL.lastPathComponent,
        "take1.mp4",
        "引用应当指向搜到的那个文件"
    )
}

// MARK: - 6. 素材真的没了 —— 老老实实报丢失

do {
    let dir = root.appendingPathComponent("missing")
    let media = dir.appendingPathComponent("gone.mp4")
    makeFile(media)
    let project = dir.appendingPathComponent("p.srtflowproj")
    try VideoEditProjectIO.save(timeline(mainMedia: [media]), to: project)
    try manager.removeItem(at: media)

    let result = try VideoEditProjectIO.load(from: project)
    checkEqual(result.missingMedia.count, 1, "找不到的素材要报出来")
    checkEqual(result.missingMedia.first?.lastPathComponent, "gone.mp4", "报出来的应当是丢失的那个")
    // 时间线本身还在，用户重新链接后就能接着剪。
    checkEqual(result.timeline.mainClips.count, 1, "素材丢了时间线也不能丢")
}

// MARK: - 7. 一批素材一起搬走，指认一个就该配上一窝（replaceMedia）

do {
    var state = TimelineState()
    let old1 = URL(fileURLWithPath: "/old/a.mp4")
    let old2 = URL(fileURLWithPath: "/old/b.mp4")
    state.mainClips = [
        EditClip(sourceURL: old1, sourceDuration: 5),
        EditClip(sourceURL: old2, sourceDuration: 5)
    ]
    state.subtitleURL = URL(fileURLWithPath: "/old/s.srt")
    state.replaceMedia(old1, with: URL(fileURLWithPath: "/new/a.mp4"))
    checkEqual(state.mainClips[0].sourceURL.path, "/new/a.mp4", "指定的那个要换掉")
    checkEqual(state.mainClips[1].sourceURL.path, "/old/b.mp4", "没指定的不该被动")
}

// MARK: - 8. 图片段存的是原图，不是缓存出来的静帧视频

do {
    let dir = root.appendingPathComponent("still")
    let image = dir.appendingPathComponent("logo.png")
    makeFile(image)
    let fakeCache = dir.appendingPathComponent("cache/generated.mp4")
    makeFile(fakeCache)

    var state = TimelineState()
    var clip = EditClip(sourceURL: fakeCache, sourceDuration: 5, stillImageURL: image)
    clip.needsStillConversion = false
    state.mainClips = [clip]

    checkEqual(state.mediaURLs.count, 1, "图片段只该登记一个素材")
    checkEqual(state.mediaURLs.first?.lastPathComponent, "logo.png", "登记的应当是原图而不是静帧视频")

    let project = dir.appendingPathComponent("p.srtflowproj")
    try VideoEditProjectIO.save(state, to: project)
    let result = try VideoEditProjectIO.load(from: project)
    // 缓存目录里没有对应的静帧，应当报出来等着重转。
    checkEqual(result.stillsToRegenerate.count, 1, "静帧缓存没了要报出来重转")
    checkEqual(result.timeline.mainClips.first?.needsStillConversion, true, "该标成待转换")
}

// MARK: - 9. 老工程缺字段也要能打开（宽容解码）

do {
    let dir = root.appendingPathComponent("lenient")
    try? manager.createDirectory(at: dir, withIntermediateDirectories: true)
    let project = dir.appendingPathComponent("old.srtflowproj")
    // 手写一份「上古版本」：没有 formatVersion、没有 media 表、剪辑只有最基本的字段，
    // 还有一个将来才会出现的未知转场值。
    let json = """
    {
      "timeline": {
        "mainClips": [
          { "sourceURL": "file:///nowhere/x.mp4", "sourceDuration": 8, "transitionAfter": "warpZoom" }
        ]
      }
    }
    """
    try Data(json.utf8).write(to: project)

    let result = try VideoEditProjectIO.load(from: project)
    checkEqual(result.timeline.mainClips.count, 1, "缺字段的老工程也要能打开")
    checkEqual(result.timeline.mainClips.first?.speed, 1, "缺的字段应当取默认值")
    checkEqual(result.timeline.mainClips.first?.transitionAfter, ClipTransition.none, "不认识的转场应当退回 none")
    checkEqual(result.timeline.canvasRatio, .auto, "缺的画布比例应当取默认值")
}

// MARK: - 10. 保存不能抹掉丢失素材的旧 bookmark
//
// 回归：以前每次保存都按当前 URL 重造全部 MediaRecord。素材此刻不可达时
// bookmarkData() 返回 nil，于是「还能定位到它」的那份书签被自己覆盖掉了；
// 而且随便哪个素材触发一次自动保存，就会连带抹掉**其他**丢失素材的线索。

do {
    let dir = root.appendingPathComponent("preserve-bookmark")
    let keeper = dir.appendingPathComponent("keeper.mp4")
    let vanisher = dir.appendingPathComponent("vanisher.mp4")
    makeFile(keeper)
    makeFile(vanisher, bytes: 4096)
    let project = dir.appendingPathComponent("p.srtflowproj")
    try VideoEditProjectIO.save(timeline(mainMedia: [keeper, vanisher]), to: project)

    // keeper 改名（书签能跟过去），vanisher 彻底消失。
    try manager.moveItem(at: keeper, to: dir.appendingPathComponent("keeper-renamed.mp4"))
    try manager.removeItem(at: vanisher)

    let loaded = try VideoEditProjectIO.load(from: project)
    checkEqual(loaded.missingMedia.count, 1, "只有 vanisher 该丢")
    check(loaded.didRelink, "keeper 改名后应触发重链接（进而触发回存）")
    let carried = loaded.records[vanisher.path]
    check(carried?.bookmark != nil, "载入结果里丢失素材的书签要留着")

    // 这就是 didRelink 之后 App 会做的那次回存。
    let after = try VideoEditProjectIO.save(
        loaded.timeline,
        to: project,
        knownRecords: loaded.records
    )
    check(after[vanisher.path]?.bookmark != nil, "回存不能把丢失素材的书签抹成 nil")
    checkEqual(after[vanisher.path]?.byteSize, 4096, "回存也要留住旧的大小信息")

    // 再从磁盘读一遍，确认书签真的写进文件了而不只是内存里。
    let reloaded = try VideoEditProjectIO.load(from: project)
    check(reloaded.records[vanisher.path]?.bookmark != nil, "写进文件的书签要还在")

    // 对照：不传 knownRecords 就是修复前的行为，书签会被抹掉。
    let naive = try VideoEditProjectIO.save(loaded.timeline, to: project)
    check(naive[vanisher.path]?.bookmark == nil, "对照组：不带旧记录保存确实会丢书签")
}

// MARK: - 11. 未来版本的工程要拒绝打开
//
// 硬打开的话，自动保存会把这版不认识的字段删掉，等于悄悄毁掉用户在新版里做的活。

do {
    let dir = root.appendingPathComponent("future")
    try? manager.createDirectory(at: dir, withIntermediateDirectories: true)
    let project = dir.appendingPathComponent("future.srtflowproj")
    let json = """
    { "formatVersion": 99, "timeline": { "mainClips": [] }, "media": [] }
    """
    try Data(json.utf8).write(to: project)

    var rejected = false
    do {
        _ = try VideoEditProjectIO.load(from: project)
    } catch {
        rejected = true
    }
    check(rejected, "formatVersion 比当前大的工程必须拒绝打开")

    // 旧版本号（v1）照常能开 —— 新版读旧版永远宽容。
    let ok = dir.appendingPathComponent("ok.srtflowproj")
    try Data("""
    { "formatVersion": 1, "timeline": { "mainClips": [] }, "media": [] }
    """.utf8).write(to: ok)
    check((try? VideoEditProjectIO.load(from: ok)) != nil, "旧版本（v1）的工程要能打开")

    // 回归：新工程写盘必须带**基线**版本号，且 Transform 字段起码是 v2。
    // 写成 v1 的话，只认 v1 的旧版会照常打开，然后在下一次自动保存时把
    // placement/rotation/opacity/flip/crop 全部静默删光。
    let media = dir.appendingPathComponent("v2.mp4")
    makeFile(media)
    let saved = dir.appendingPathComponent("v2.srtflowproj")
    try VideoEditProjectIO.save(timeline(mainMedia: [media]), to: saved)
    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: saved)) as? [String: Any]
    // 契约已变（工程帧率落地后）：新版 writer 一律写 latest。
    // 原本这里守的是「普通工程别被无谓抬版本」，那个目的现在由「v1–v5 老文件
    // 仍然读得开」来守（见下方 for oldVersion 循环与 v5 老工程用例）。
    //
    // 数字**写死**，不引用 `latestFormatVersion`：拿常量跟自己比是自反断言，
    // 版本忘了升照样绿（2026-08-07 案例的教训）。升版本时这里要一起改。
    checkEqual(raw?["formatVersion"] as? Int, 6, "新版写盘一律用 v6")
    check(
        VideoEditProjectFile.baselineFormatVersion >= 3,
        "带关键帧动画字段的格式起码是 v3，旧版才会拒开而不是默默毁字段"
    )
}

// MARK: - 15. formatVersion 按需写入：v4 只留给真用了关联字幕的工程

do {
    let dir = root.appendingPathComponent("on-demand-v4")
    let media = dir.appendingPathComponent("a.mp4")
    makeFile(media)
    let project = dir.appendingPathComponent("p.srtflowproj")

    func savedVersion() throws -> Int? {
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: project)) as? [String: Any]
        return raw?["formatVersion"] as? Int
    }

    // 没碰过新功能的工程：写 v3，往返后还是 v3。
    var state = timeline(mainMedia: [media])
    let cueA = SubtitleCue(index: 1, start: 0, end: 2, text: "hello")
    let cueB = SubtitleCue(index: 2, start: 2, end: 4, text: "world")
    state.subtitle = SubtitleDocumentModel(cues: [cueA, cueB])
    try VideoEditProjectIO.save(state, to: project)
    checkEqual(try savedVersion(), 6, "只有原文轨的工程也写 v6（帧率/字幕布局无条件落盘）")

    var roundtrip = try VideoEditProjectIO.load(from: project).timeline
    try VideoEditProjectIO.save(roundtrip, to: project)
    checkEqual(try savedVersion(), 6, "往返后仍是 v6")
    // 往返不能丢原文轨 —— 这才是本用例真正要守的东西
    checkEqual(roundtrip.subtitle?.cues.count, 2, "往返不丢原文 cue")

    // 挂上译文轨：写 v4，且译文/meta 往返无损。
    var translationDoc = SubtitleDocumentModel(cues: [cueA, cueB])
    translationDoc.cues[0].text = "你好"
    translationDoc.cues[1].text = "世界"
    roundtrip.subtitleCompanion = SubtitleCompanion(
        translation: translationDoc,
        targetLanguage: "zh-Hans",
        sourceLanguage: "en",
        origin: .imported,
        cueMeta: [cueA.id: CueMeta(recognitionConfidence: 0.9, translationStale: true)]
    )
    try VideoEditProjectIO.save(roundtrip, to: project)
    checkEqual(try savedVersion(), 6, "带译文轨的工程写 v6（v4 的登记项已被 v5/v6 覆盖）")
    // requiresFormatVersion4 的登记判据本身仍要成立
    check(roundtrip.requiresFormatVersion4, "有 companion 数据时 v4 判据要为真")

    let loaded = try VideoEditProjectIO.load(from: project).timeline
    checkEqual(loaded.subtitleCompanion?.translation?.cues.count, 2, "译文轨要存住")
    checkEqual(loaded.subtitleCompanion?.translation?.cues.first?.id, cueA.id, "译文 cue 与原文共 ID")
    checkEqual(loaded.subtitleCompanion?.translation?.cues.first?.text, "你好", "译文文本要存住")
    checkEqual(loaded.subtitleCompanion?.targetLanguage, "zh-Hans", "目标语言要存住")
    checkEqual(loaded.subtitleCompanion?.cueMeta[cueA.id]?.recognitionConfidence, 0.9, "cueMeta 要存住")
    checkEqual(loaded.subtitleCompanion?.cueMeta[cueA.id]?.translationStale, true, "stale 标记要存住")

    // 字幕轨的眼睛（subtitleHidden，2026-08-09）：往返存住 + 缺键回退 false +
    // 可见性合同（预览/烧录共用 visible 变体，数据面不受影响）。
    var hiddenState = loaded
    hiddenState.subtitleHidden = true
    try VideoEditProjectIO.save(hiddenState, to: project)
    let hiddenLoaded = try VideoEditProjectIO.load(from: project).timeline
    checkEqual(hiddenLoaded.subtitleHidden, true, "subtitleHidden 往返要存住")
    check(hiddenLoaded.visibleSubtitleDocument(for: .original) == nil,
          "隐藏时 visible 变体必须为 nil（预览与烧录同一份合同）")
    check(hiddenLoaded.subtitleDocument(for: .original) != nil,
          "隐藏不动数据面（独立字幕文件导出仍可用）")
    var shownState = hiddenLoaded
    shownState.subtitleHidden = false
    check(shownState.visibleSubtitleDocument(for: .original) != nil,
          "显示时 visible 变体要给文档")
    // 工程级字幕布局覆盖（subtitleLayout）：往返无损；没设置就不落键。
    var layoutState = loaded
    layoutState.subtitleLayout = SubtitleLayout(
        marginLeft: 130, marginRight: 70, marginBottom: 210, fontScale: 1.25
    )
    try VideoEditProjectIO.save(layoutState, to: project)
    let layoutLoaded = try VideoEditProjectIO.load(from: project).timeline
    checkEqual(
        layoutLoaded.subtitleLayout,
        layoutState.subtitleLayout,
        "subtitleLayout 往返要无损"
    )
    try VideoEditProjectIO.save(loaded, to: project)
    let noLayout = try JSONSerialization.jsonObject(with: Data(contentsOf: project)) as? [String: Any]
    let noLayoutTimeline = noLayout?["timeline"] as? [String: Any]
    check(
        noLayoutTimeline?["subtitleLayout"] == nil,
        "没设置布局覆盖的工程不落 subtitleLayout 键"
    )

    // 旧工程没有这个键：必须回退 false，不许拒开。
    var rawJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: project)) as? [String: Any]
    if var timelineJSON = rawJSON?["timeline"] as? [String: Any] {
        timelineJSON.removeValue(forKey: "subtitleHidden")
        rawJSON?["timeline"] = timelineJSON
        try JSONSerialization.data(withJSONObject: rawJSON!).write(to: project)
        let legacy = try VideoEditProjectIO.load(from: project).timeline
        checkEqual(legacy.subtitleHidden, false, "旧工程缺 subtitleHidden 键回退 false")
    } else {
        check(false, "工程文件的 timeline 键结构变了，本用例需要跟进")
    }

    // 删光 v4 数据后仍然是 v6：帧率是**无条件**的 v5 字段（每个工程都有帧率，
    // 而 v4 及更早把帧率硬编码成 30），字幕布局/可见性是 v6 字段，所以新版
    // writer 一律写 latest，不再降级。
    var cleared = loaded
    cleared.subtitleCompanion = nil
    try VideoEditProjectIO.save(cleared, to: project)
    checkEqual(try savedVersion(), 6, "新版 writer 一律写 v6")

    // ---- 字幕布局/可见性的版本闸门（v6，2026-08-09 PR#22 复审）----
    //
    // 这里的数字**故意写死 6**，不引用 `latestFormatVersion`：拿常量跟自己比
    // 是自反断言，改坏了照样绿（2026-08-07 案例的教训）。要的是外部真值。
    //
    // 为什么必须升版本：subtitleLayout 决定字幕的位置/换行宽度/字号，
    // subtitleHidden 决定它烧不烧进成片。只认 v5 的旧版若照常打开这种工程，
    // 下一次自动保存会把两个键静默删光 —— 用户调好的排版和「不要烧字幕」的
    // 意图一起消失，且**导出画面**随之改变。
    let v6Project = dir.appendingPathComponent("v6-layout.srtflowproj")
    var v6State = timeline(mainMedia: [media])
    v6State.subtitle = SubtitleDocumentModel(cues: [cueA, cueB])
    v6State.subtitleLayout = SubtitleLayout(
        marginLeft: 140, marginRight: 60, marginBottom: 190, fontScale: 1.4
    )
    v6State.subtitleHidden = true
    try VideoEditProjectIO.save(v6State, to: v6Project)
    let v6Raw = try JSONSerialization.jsonObject(with: Data(contentsOf: v6Project)) as? [String: Any]
    checkEqual(v6Raw?["formatVersion"] as? Int, 6, "带字幕布局的工程必须写 v6")
    let v6Loaded = try VideoEditProjectIO.load(from: v6Project).timeline
    checkEqual(v6Loaded.subtitleLayout, v6State.subtitleLayout, "v6 往返：布局无损")
    checkEqual(v6Loaded.subtitleHidden, true, "v6 往返：隐藏状态无损")

    // v5 老工程（两个键都没有）照常打开，默认 layout=nil、hidden=false ——
    // 宽容读取的方向不许被版本闸门带坏。
    let v5Legacy = dir.appendingPathComponent("v5-legacy.srtflowproj")
    try Data("""
    { "formatVersion": 5, "timeline": { "mainClips": [], "frameRate": 30 }, "media": [] }
    """.utf8).write(to: v5Legacy)
    let legacyLoaded = try VideoEditProjectIO.load(from: v5Legacy).timeline
    checkEqual(legacyLoaded.subtitleLayout, nil, "v5 老工程缺 subtitleLayout 键 → nil")
    checkEqual(legacyLoaded.subtitleHidden, false, "v5 老工程缺 subtitleHidden 键 → false")
    checkEqual(legacyLoaded.frameRate, .fps30, "v5 老工程的既有字段照常读回")

    // 闸门另一侧：比 reader 上限更高的 v7 必须拒开。
    let v7 = dir.appendingPathComponent("v7.srtflowproj")
    try Data("""
    { "formatVersion": 7, "timeline": { "mainClips": [] }, "media": [] }
    """.utf8).write(to: v7)
    check((try? VideoEditProjectIO.load(from: v7)) == nil, "未来版本（v7）必须拒开")

    // ---- 工程帧率（v5，无条件）----
    //
    // 反例守卫：**默认 24 也必须显式落盘并写 v5**。
    // 若省略该键并降级成 v3，旧版会按硬编码的 30fps 打开 —— 同一文件在新旧版
    // 出不同成片，正是版本闸门要防的语义破坏。
    var fpsProject = cleared
    fpsProject.frameRate = .fps24
    try VideoEditProjectIO.save(fpsProject, to: project)
    checkEqual(try savedVersion(), 6, "默认 24fps 也要显式落盘，不能降级")
    let savedJSON = try String(contentsOf: project, encoding: .utf8)
    check(savedJSON.contains("\"frameRate\""), "默认 24fps 的键必须真的写进文件")
    checkEqual(try VideoEditProjectIO.load(from: project).timeline.frameRate, .fps24,
               "默认帧率要能原样读回")

    fpsProject.frameRate = .fps60
    try VideoEditProjectIO.save(fpsProject, to: project)
    checkEqual(try savedVersion(), 6, "非默认帧率同样写 latest")
    checkEqual(try VideoEditProjectIO.load(from: project).timeline.frameRate, .fps60, "帧率要存得住")

    // 只有**读**旧文件时才回退：v1–v4 没有帧率语义，按产品默认值 24 读。
    for oldVersion in [1, 3, 4] {
        let old = dir.appendingPathComponent("v\(oldVersion).srtflowproj")
        try Data("""
        { "formatVersion": \(oldVersion), "timeline": { "mainClips": [] }, "media": [] }
        """.utf8).write(to: old)
        checkEqual(try VideoEditProjectIO.load(from: old).timeline.frameRate, .fps24,
                   "v\(oldVersion) 缺帧率键时读回 24")
    }

    // 读盘规范化：孤儿译文 cue / 孤儿 meta（原文里没有的 ID）要被清掉。
    var dirty = cleared
    let ghost = SubtitleCue(index: 1, start: 9, end: 10, text: "幽灵")
    dirty.subtitleCompanion = SubtitleCompanion(
        translation: SubtitleDocumentModel(cues: [ghost]),
        cueMeta: [ghost.id: CueMeta(), cueA.id: CueMeta(translationStale: true)]
    )
    try VideoEditProjectIO.save(dirty, to: project)
    let normalized = try VideoEditProjectIO.load(from: project).timeline
    checkEqual(normalized.subtitleCompanion?.translation, nil, "失锚的译文 cue 读盘要清掉")
    checkEqual(normalized.subtitleCompanion?.cueMeta.count, 1, "孤儿 meta 读盘要清掉")
    check(normalized.subtitleCompanion?.cueMeta[cueA.id] != nil, "锚得上的 meta 要留下")
}

// MARK: - 14. 关键帧锚在源时间：插值、变速、分割语义

do {
    // 容差分空间：这些用例都是 speed=1，用 30fps 半帧（等于迁移前写死的 1/60），
    // 行为与迁移前一致。带 speed 的用例另见下方。
    let tol = KeyframeTrack.sourceTolerance(frameRate: .fps30, speed: 1)
    var track = KeyframeTrack()
    track.set(10, atSourceTime: 1, tolerance: tol)
    track.set(30, atSourceTime: 3, tolerance: tol)
    checkEqual(track.value(atSourceTime: 2), 20, "两帧中点线性插值")
    checkEqual(track.value(atSourceTime: 0), 10, "首帧之前夹紧")
    checkEqual(track.value(atSourceTime: 9), 30, "末帧之后夹紧")
    track.set(99, atSourceTime: 3.001, tolerance: tol)
    checkEqual(track.keys.count, 2, "半帧内重写是替换不是堆积")
    checkEqual(track.value(atSourceTime: 3), 99, "替换后取新值")
    track.remove(atSourceTime: 1, tolerance: tol)
    checkEqual(track.keys.count, 1, "按时刻删除")

    // 变速：源锚定 → 时间线映射跟着速度换算。
    var clip = EditClip(sourceURL: URL(fileURLWithPath: "/m/a.mp4"), sourceDuration: 8, speed: 2, timelineStart: 5)
    var animation = ClipAnimation()
    // speed=2 → source 空间容差是工程半帧的两倍
    let speedTol = KeyframeTrack.sourceTolerance(frameRate: .fps30, speed: clip.speed)
    animation.opacity.set(1, atSourceTime: 0, tolerance: speedTol)
    animation.opacity.set(0, atSourceTime: 8, tolerance: speedTol)
    clip.animation = animation
    // 2 倍速：时间线 5+2=7s 处对应源 4s → 不透明度 0.5。
    checkEqual(clip.animatedOpacity(atTimeline: 7), 0.5, "变速下按源时间取动画值")

    // 分割语义：两半带同一份轨，接缝处数值连续。
    var state = TimelineState()
    state.mainClips = [clip]
    // 手工模拟 split 的右半构造（split 是 VideoEditProject 的私有函数，这里
    // 只验证「源锚定 ⇒ 连续」这条性质本身）。
    var left = clip
    left.sourceDuration = 4
    var right = clip
    right.sourceStart = 4
    right.sourceDuration = 4
    right.timelineStart = 7
    checkEqual(
        left.animatedOpacity(atTimeline: 7), right.animatedOpacity(atTimeline: 7),
        "分割接缝两侧动画值必须连续"
    )
}

// MARK: - 12. 重链接图片之后要重新对静帧
//
// 回归：重链接只换了 stillImageURL，sourceURL 还指着那份多半已经不存在的静帧
// 缓存。不重新对一次的话，这个片段会永远停在「待转换」，导出时被静默排除。

do {
    var state = TimelineState()
    let oldImage = URL(fileURLWithPath: "/old/logo.png")
    let newImage = URL(fileURLWithPath: "/new/logo.png")
    var clip = EditClip(
        sourceURL: URL(fileURLWithPath: "/caches/stale-still.mp4"),
        sourceDuration: 5,
        stillImageURL: oldImage
    )
    clip.needsStillConversion = false
    state.mainClips = [clip]

    state.replaceMedia(oldImage, with: newImage)
    checkEqual(state.mainClips[0].stillImageURL, newImage, "重链接要换掉原图路径")

    let pending = VideoEditProjectIO.refreshStillClips(in: &state)
    checkEqual(pending.map(\.image), [newImage], "新原图没有静帧缓存，应当报出来重转")
    checkEqual(state.mainClips[0].needsStillConversion, true, "对不上缓存就该标成待转换")
    // 没有 info（或 info 在照片上限之内）时按照片政策重转。
    checkEqual(pending.first?.nativeResolution, false, "普通图片段按照片政策重转")
}

// MARK: - 12b. 定格帧重转时要保住原生分辨率
//
// 回归：定格帧是不缩放转的（Retina 录屏定格不能糊）。缓存被系统清掉后重转时，
// 政策必须跟着走，否则会被悄悄按「照片」政策压到 1080p。判据是存进工程文件的
// 静帧尺寸 —— 超过照片上限就说明当初是按原生尺寸转的。

do {
    var state = TimelineState()
    let frame = URL(fileURLWithPath: "/project/clip-freeze-00m03s21.png")
    var clip = EditClip(
        sourceURL: URL(fileURLWithPath: "/caches/gone-still.mp4"),
        sourceDuration: 2,
        info: MediaInfo(
            duration: 60,
            displaySize: CGSize(width: 3456, height: 2234),
            frameRate: 2,
            videoCodec: "h264",
            audioCodec: nil,
            hasAudio: false,
            audioCanCopyToMP4: false,
            fileBytes: 1024
        ),
        stillImageURL: frame
    )
    clip.needsStillConversion = false
    state.mainClips = [clip]

    let pending = VideoEditProjectIO.refreshStillClips(in: &state)
    checkEqual(pending.map(\.image), [frame], "静帧缓存没了要报出来重转")
    checkEqual(pending.first?.nativeResolution, true, "超过照片上限的静帧要按原生尺寸重转")
}

// MARK: - 12c. 同一张 PNG 既当定格素材又当普通图片时，两条政策不能串线
//
// 回归：用户完全可能把工程文件夹里那张定格 PNG 再拖进时间线当普通图片。
// 那就是同一个 stillImageURL、两条分辨率政策。重转任务必须按 (图, 政策) 分成
// 两项，否则后跑完的那项会把两边都改成自己的产物，另一半拿到错误分辨率的静帧。

do {
    var state = TimelineState()
    let shared = URL(fileURLWithPath: "/project/shot-freeze-00m01s00.png")

    func stillClip(width: Double, height: Double) -> EditClip {
        var clip = EditClip(
            sourceURL: URL(fileURLWithPath: "/caches/gone-\(Int(width)).mp4"),
            sourceDuration: 2,
            info: MediaInfo(
                duration: 60,
                displaySize: CGSize(width: width, height: height),
                frameRate: 2,
                videoCodec: "h264",
                audioCodec: nil,
                hasAudio: false,
                audioCanCopyToMP4: false,
                fileBytes: 1024
            ),
            stillImageURL: shared
        )
        clip.needsStillConversion = false
        return clip
    }

    // 一段是定格（原生 2560×1440），一段是同一张图当普通照片拖进来（1080p）。
    state.mainClips = [stillClip(width: 2560, height: 1440), stillClip(width: 1920, height: 1080)]

    let pending = VideoEditProjectIO.refreshStillClips(in: &state)
    checkEqual(pending.count, 2, "同一张图的两条政策要分成两项重转任务")
    checkEqual(Set(pending.map(\.image)), [shared], "两项指的是同一张原图")
    checkEqual(Set(pending.map(\.nativeResolution)), [true, false], "两项的政策必须一原生一照片")

    // 落地只更新同政策的段：把「原生」那项的产物接上去，照片那段必须一动不动。
    let nativeVideo = URL(fileURLWithPath: "/caches/fresh-native.mp4")
    VideoEditProjectIO.attachStill(nativeVideo, forImage: shared, nativeResolution: true, in: &state)
    checkEqual(state.mainClips[0].sourceURL, nativeVideo, "原生政策的段要接上原生产物")
    checkEqual(state.mainClips[0].needsStillConversion, false, "接上了就不再是待转换")
    check(state.mainClips[1].sourceURL != nativeVideo,
          "照片政策的段绝不能被原生产物顶掉（否则分辨率和 info 都对不上）")
    checkEqual(state.mainClips[1].needsStillConversion, true, "照片政策的段仍在等自己那项")

    let photoVideo = URL(fileURLWithPath: "/caches/fresh-photo.mp4")
    VideoEditProjectIO.attachStill(photoVideo, forImage: shared, nativeResolution: false, in: &state)
    checkEqual(state.mainClips[1].sourceURL, photoVideo, "照片政策的段接自己那项")
    checkEqual(state.mainClips[0].sourceURL, nativeVideo, "原生那段不受第二项影响")
}

// MARK: - 12d. 两份缓存同时存在时，命中要按政策路由
//
// 回归：以前 cachedStillVideo「两条都查、原生优先」，同一张 PNG 被两种政策共用时
// 照片段也会拿到原生版本。这里真造两份缓存文件，钉住各走各的。

do {
    let image = root.appendingPathComponent("shared-cache-probe.png")
    makeFile(image, bytes: 4096)

    guard let nativePath = StillImageClipFactory.cacheFileURL(for: image, nativeResolution: true),
          let photoPath = StillImageClipFactory.cacheFileURL(for: image, nativeResolution: false) else {
        check(false, "拿不到缓存路径")
        exit(1)
    }
    check(nativePath != photoPath, "两条政策的缓存文件名必须不同，否则会互相覆盖")

    // 先只造原生那份：照片政策必须查不到（以前会错误命中原生）。
    makeFile(nativePath, bytes: 128)
    defer { try? manager.removeItem(at: nativePath) }
    checkEqual(StillImageClipFactory.cachedStillVideo(for: image, nativeResolution: true), nativePath,
               "原生政策命中原生缓存")
    checkEqual(StillImageClipFactory.cachedStillVideo(for: image, nativeResolution: false), nil,
               "只有原生缓存时，照片政策必须判定为缺失并重转")

    // 两份都在：各走各的。
    makeFile(photoPath, bytes: 128)
    defer { try? manager.removeItem(at: photoPath) }
    checkEqual(StillImageClipFactory.cachedStillVideo(for: image, nativeResolution: false), photoPath,
               "照片政策命中照片缓存")
    checkEqual(StillImageClipFactory.cachedStillVideo(for: image, nativeResolution: true), nativePath,
               "原生政策仍命中原生缓存")
}

// MARK: - 13. 选中导出：画中画升主轨要丢自由摆放
//
// 回归：只选画中画导出时它会被升为主轨（约定是「导出单个视频＝完整画面」），
// 升轨时不清 placement 的话，导出器继续走黑底 overlay 分支——出来是黑底小窗。

do {
    let place = ClipPlacement(centerX: 0.8, centerY: 0.2, width: 0.3, height: 0.3)
    var state = TimelineState()
    let main = EditClip(sourceURL: URL(fileURLWithPath: "/m/main.mp4"), sourceDuration: 10)
    var pip = EditClip(sourceURL: URL(fileURLWithPath: "/m/pip.mp4"), sourceDuration: 5, timelineStart: 2)
    pip.placement = place
    pip.rotationDegrees = 30
    pip.opacity = 0.5
    pip.flippedVertically = true
    pip.crop = ClipCrop(trailing: 0.2)
    var pip2 = EditClip(sourceURL: URL(fileURLWithPath: "/m/pip2.mp4"), sourceDuration: 4, timelineStart: 3)
    pip2.placement = place
    state.mainClips = [main]
    state.overlayTracks = [EditLane(clips: [pip]), EditLane(clips: [pip2])]

    // 只选一条画中画：升主轨、平移到 0、丢摆放。
    let solo = state.selectionForExport(ids: [pip.id])
    checkEqual(solo.mainClips.map(\.id), [pip.id], "只选画中画时它应升为主轨")
    check(solo.overlayTracks.isEmpty, "升完不该剩空画中画轨")
    checkEqual(solo.mainClips.first?.placement, nil, "升主轨必须丢自由摆放，否则导出是黑底小窗")
    checkEqual(solo.mainClips.first?.timelineStart, 0, "选中导出要平移到 0 起点")
    checkEqual(solo.mainClips.first?.rotationDegrees, 0, "升主轨要丢旋转（相对完整画面的属性）")
    checkEqual(solo.mainClips.first?.opacity, 1, "升主轨要丢不透明度（对黑底没有意义）")
    checkEqual(solo.mainClips.first?.flippedVertically, true, "翻转是内容属性，升主轨要保留")
    checkEqual(solo.mainClips.first?.crop, ClipCrop(trailing: 0.2), "裁切是内容属性，升主轨要保留")

    // 画中画和主轨一起选：不升轨的画中画保持摆放（所见即所得）。
    let both = state.selectionForExport(ids: [main.id, pip.id])
    checkEqual(both.mainClips.map(\.id), [main.id], "主轨还在就不升画中画")
    checkEqual(both.overlayTracks.first?.clips.first?.placement, place, "没升轨的画中画要保留摆放")

    // 只选两条画中画：最下面那条升主轨丢摆放，另一条留在画中画轨保留摆放。
    let pips = state.selectionForExport(ids: [pip.id, pip2.id])
    checkEqual(pips.mainClips.map(\.id), [pip.id], "升的是最下面那条画中画轨")
    checkEqual(pips.mainClips.first?.placement, nil, "升主轨的那条要丢摆放")
    checkEqual(pips.overlayTracks.first?.clips.first?.placement, place, "另一条画中画的摆放不该被牵连")
}

// MARK: - 16. 运行中重核对（relocateMedia）：工程开着时素材被改名/挪走
//
// 回归：以前四层线索只在**打开工程**时跑。运行中把素材改名+移动后，预览重建
// 按死路径加载失败、整段静默变黑（轨道缩略图是缓存看着正常），且 missingMedia
// 永远不更新 —— 用户以为是变速把视频弄坏了。relocateMedia 就是给运行中重核对
// 用的同一套线索。

do {
    let dir = root.appendingPathComponent("runtime-relocate")
    let media = dir.appendingPathComponent("live.mp4")
    makeFile(media)
    let project = dir.appendingPathComponent("p.srtflowproj")
    // 存一次盘拿到内存里的定位表 —— 这就是工程开着时 mediaRecords 的状态。
    let records = try VideoEditProjectIO.save(timeline(mainMedia: [media]), to: project)

    // 用户在访达里改名 + 挪去别的文件夹（同一个卷）。
    let renamed = root.appendingPathComponent("runtime-elsewhere/renamed-live.mp4")
    try manager.createDirectory(
        at: renamed.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try manager.moveItem(at: media, to: renamed)

    let outcome = VideoEditProjectIO.relocateMedia(
        urls: [media],
        records: records,
        projectDirectory: dir
    )
    checkEqual(
        outcome.moved[media]?.standardizedFileURL.path,
        renamed.standardizedFileURL.path,
        "运行中改名+移动要靠书签跟过去"
    )
    check(outcome.missing.isEmpty, "跟上了就不算丢失")

    // 未命名工程（还没有工程目录）：书签这层不依赖工程位置，照样要能跟。
    let untitled = VideoEditProjectIO.relocateMedia(
        urls: [media],
        records: records,
        projectDirectory: nil
    )
    checkEqual(
        untitled.moved[media]?.standardizedFileURL.path,
        renamed.standardizedFileURL.path,
        "没有工程目录时书签线索也要生效"
    )

    // 真没了：报 missing，不许乱配。
    try manager.removeItem(at: renamed)
    let gone = VideoEditProjectIO.relocateMedia(urls: [media], records: records, projectDirectory: dir)
    check(gone.moved.isEmpty, "文件删了不该报找回")
    checkEqual(gone.missing, [media], "文件删了要老实报丢失")

    // 原地没动：两个名单都空 —— 这是高频路径，不能有任何动静。
    let still = dir.appendingPathComponent("still-here.mp4")
    makeFile(still)
    let quiet = VideoEditProjectIO.relocateMedia(urls: [still], records: [:], projectDirectory: dir)
    check(quiet.moved.isEmpty && quiet.missing.isEmpty, "原地未动的素材不该有任何动静")
}

// MARK: - 20. 字幕生成的可听快照：metadata 只许问真正会响的素材
//
// 回归（PR#22 复审 P1）：`metadataLanguageTag` 曾经自己扫
// `mainClips + audioTracks` —— 不看 mainHidden、不看 lane.isHidden、
// 不看 mute/volume，还整个漏掉带声音的 overlay。反例是「隐藏的英文主轨 +
// 可听的日文 overlay」：英文 metadata 当上了最高优先级候选（唯一允许触发
// 模型下载的那个），探针却抽的是日文 overlay —— 两份互相矛盾的输入。
//
// 这里守的**不是一个新纯函数算得对不对**，而是生产代码的取数路径：
// `TranscriptionTask.detectSourceLocale` 只从 `SubtitleAudibleClips`
// 拿素材（它连 TimelineState 参数都不再收），所以这两个函数上的断言就是
// 生产接线上的断言。

do {
    let dir = root.appendingPathComponent("audible-snapshot")
    func clip(_ name: String, hasAudio: Bool = true) -> EditClip {
        let url = dir.appendingPathComponent(name)
        makeFile(url)
        var c = EditClip(sourceURL: url, sourceDuration: 10, timelineStart: 0)
        c.info = MediaInfo(
            duration: 10,
            displaySize: CGSize(width: 1920, height: 1080),
            frameRate: 30,
            videoCodec: "h264",
            audioCodec: "aac",
            hasAudio: hasAudio,
            audioCanCopyToMP4: true,
            fileBytes: 2048
        )
        return c
    }

    // 反例场景：主轨（英文）整轨隐藏，可听的是 overlay（日文）与一条音频轨。
    var state = TimelineState()
    let hiddenMain = clip("hidden-main-en.mp4")
    state.mainClips = [hiddenMain]
    state.mainHidden = true
    let audibleOverlay = clip("overlay-ja.mp4")
    state.overlayTracks = [EditLane(clips: [audibleOverlay])]
    let audibleAudio = clip("music.m4a")
    state.audioTracks = [EditLane(clips: [audibleAudio])]

    let clips = SubtitleAudibleClips.soundClips(in: state)
    let ids = clips.map(\.clipID)
    check(!ids.contains(hiddenMain.id), "隐藏主轨的素材不进可听快照")
    check(ids.contains(audibleOverlay.id), "带声音的 overlay 必须进可听快照")
    check(ids.contains(audibleAudio.id), "可听音频轨必须进可听快照")

    let probeOrder = SubtitleAudibleClips.probeOrder(in: clips)
    guard let firstProbe = probeOrder.first else {
        check(false, "有可听素材时必须有探针候选")
        fatalError("unreachable")
    }
    // 候选顺序与实际 probe 来源一致：metadata 第一个问的就是探针那一段。
    checkEqual(firstProbe.clipID, audibleOverlay.id, "探针候选从可听快照第一段真实存在的素材起")
    let order = SubtitleAudibleClips.metadataOrder(in: clips, probe: firstProbe)
    checkEqual(order.first?.clipID, firstProbe.clipID, "metadata 查询顺序必须以探针素材打头")
    checkEqual(order.count, clips.count, "metadata 顺序覆盖整份可听快照，不重不漏")
    check(!order.contains { $0.clipID == hiddenMain.id }, "隐藏主轨的 metadata 不许参与检测")
    checkEqual(Set(order.map(\.clipID)), Set(ids), "metadata 顺序是可听快照的一个排列（不许自己找素材）")

    // 静音 / 零音量 / 隐藏 lane 同样出局 —— 与预览、导出同一份可听合同。
    var muted = TimelineState()
    var mutedClip = clip("muted.mp4")
    mutedClip.isMuted = true
    var zeroVolume = clip("zero-volume.mp4")
    zeroVolume.volume = 0
    muted.mainClips = [mutedClip, zeroVolume]
    muted.overlayTracks = [EditLane(clips: [clip("hidden-lane.mp4")], isHidden: true)]
    check(SubtitleAudibleClips.soundClips(in: muted).isEmpty,
          "静音/零音量/隐藏 lane 的素材一个都不该进可听快照")
    check(SubtitleAudibleClips.probeOrder(in: []).isEmpty, "空快照没有探针候选")

    // 「有没有声音」只认 EditClip.hasAudio —— 与 CompositionBuilder 同一属性。
    // 回归（PR#22 复审第二轮）：这里曾经写成「info 存在且 hasAudio 为假才排除」，
    // 于是 info == nil 被当成有声音。宽容解码读回来的老工程、探测还没回来的
    // 导入中素材全是 info == nil —— 用户**听不到**的段落照样进快照被转写。
    var infoless = TimelineState()
    var unknownVideo = clip("unknown-info.mp4")
    unknownVideo.info = nil                       // 视频，探测信息未知
    let noAudioVideo = clip("no-audio.mp4", hasAudio: false)
    var audioOnlyNoInfo = clip("voice-only.m4a")
    audioOnlyNoInfo.info = nil                    // 纯音频 clip 的 info 常年为 nil
    audioOnlyNoInfo.isAudioOnly = true
    infoless.mainClips = [unknownVideo, noAudioVideo]
    infoless.audioTracks = [EditLane(clips: [audioOnlyNoInfo])]
    let infolessIDs = SubtitleAudibleClips.soundClips(in: infoless).map(\.clipID)
    check(!infolessIDs.contains(unknownVideo.id),
          "info == nil 的视频不算可听（与 CompositionBuilder 同一份 hasAudio 合同）")
    check(!infolessIDs.contains(noAudioVideo.id), "info 明说没有音轨的视频不算可听")
    check(infolessIDs.contains(audioOnlyNoInfo.id),
          "isAudioOnly 的 clip 即使 info == nil 也算可听（2026-08-06 的回退仍在）")
    check(unknownVideo.hasAudio == false && audioOnlyNoInfo.hasAudio,
          "EditClip.hasAudio 本身的语义没被改坏")

    // 文件真不在磁盘上的素材抽不出音频，不许被选成探针。
    var ghostState = TimelineState()
    var ghost = clip("ghost.mp4")
    try? manager.removeItem(at: ghost.sourceURL)
    let realOne = clip("real.mp4")
    ghostState.mainClips = [ghost, realOne]
    let ghostClips = SubtitleAudibleClips.soundClips(in: ghostState)
    checkEqual(ghostClips.count, 2, "文件不在也仍进快照（转写阶段另有跳过逻辑）")
    checkEqual(SubtitleAudibleClips.probeOrder(in: ghostClips).first?.clipID, realOne.id,
               "探针候选跳过磁盘上不存在的素材")
    ghost.volume = 1  // 消掉未使用告警的同时保持 ghost 可写
}

// MARK: - 20b. 探针必须**真抽一次**才算数（不是「文件存在」就当可读）
//
// 回归（PR#22 复审第二轮 P2）：探针原来只挑「第一段文件存在的素材」，抽取失败
// 就整个 Auto-detect 失败。第一段完全可能是无音轨的视频或半截文件，而后面就
// 跟着一条正常音频轨 —— 用户手里明明有可用的声音，却被告知检测不了。
//
// 错误分流照 collectWindows 的责任面：素材的错换下一段，基础设施错误和取消上抛。

do {
    let dir = root.appendingPathComponent("probe-retry")
    func soundClip(_ name: String) -> SubtitleAudibleClips.SoundClip {
        let url = dir.appendingPathComponent(name)
        makeFile(url)
        return SubtitleAudibleClips.SoundClip(
            clipID: UUID(), name: name, url: url, fingerprint: name,
            knownAssetDuration: 30, sourceStart: 2, sourceDuration: 30,
            timelineStart: 0, speed: 1, laneRank: 0
        )
    }
    let broken = soundClip("broken.mp4")
    let good = soundClip("good.m4a")
    let third = soundClip("third.m4a")

    struct Boom: Error {}

    // 第一段读不了 → 顺延到第二段，并把跳过的记下来。
    let picked = try await SubtitleAudibleClips.selectProbe(
        in: [broken, good, third], probeSeconds: 20
    ) { clip, _ in
        if clip.clipID == broken.clipID {
            throw AudioWindowReader.ReadError(message: "no audio track")
        }
        return clip.url
    }
    checkEqual(picked?.clip.clipID, good.clipID, "第一段读不出音频时探针顺延到下一段")
    checkEqual(picked?.skipped.count, 1, "跳过的素材要记下来")
    checkEqual(picked?.skipped.first?.name, "broken.mp4", "跳过记录带素材名")
    // 抽取区间按 clip 自己的源起点 + 探针时长截断。
    checkEqual(picked?.range.start, 2, "探针区间从 clip 的源起点开始")
    checkEqual(picked?.range.end, 22, "探针区间按 probeSeconds 截断")

    // 全都读不了 → nil（调用方报「素材读不了，请重新链接」）。
    let none = try await SubtitleAudibleClips.selectProbe(
        in: [broken, good], probeSeconds: 20
    ) { _, _ in throw AudioWindowReader.ReadError(message: "nope") }
    check(none == nil, "全部候选都读不出音频时返回 nil")

    // 基础设施错误不许被当成「这段素材不行」吞掉 —— 必须整体失败。
    var rethrew = false
    do {
        _ = try await SubtitleAudibleClips.selectProbe(
            in: [broken, good], probeSeconds: 20
        ) { _, _ in throw AudioWindowReader.InfrastructureError(message: "disk full") }
    } catch is AudioWindowReader.InfrastructureError {
        rethrew = true
    } catch {}
    check(rethrew, "基础设施错误必须直穿，不许伪装成「素材不可读」")

    // 取消同样直穿。
    var cancelled = false
    do {
        _ = try await SubtitleAudibleClips.selectProbe(
            in: [broken, good], probeSeconds: 20
        ) { _, _ in throw CancellationError() }
    } catch is CancellationError {
        cancelled = true
    } catch {}
    check(cancelled, "取消必须直穿")

    // 第一段就能读时不该有任何跳过记录，也不该多试。
    var attempts = 0
    let straight = try await SubtitleAudibleClips.selectProbe(
        in: [good, third], probeSeconds: 20
    ) { clip, _ in attempts += 1; return clip.url }
    checkEqual(attempts, 1, "第一段能读就不再往下试")
    check(straight?.skipped.isEmpty == true, "没跳过任何素材时记录为空")
    _ = Boom.self

    // ---- 取消不许被跳过逻辑洗成「素材都读不了」（PR#22 复审第三轮 P2）----
    //
    // 跳过逻辑天生要吞错误。用户按 Stop 之后，剩下的候选照样各抛一个 ReadError，
    // 全被吞掉就走到 return nil，调用方翻成「素材都读不了」——终态从 .cancelled
    // 变成 .failed，用户明明是自己取消的。

    // ① 任务自己的取消通道（生产是 token.isCancelled）：抽取器抛的仍是
    //    **ReadError**，判别点就在这里 —— 结果必须是 CancellationError。
    var tokenCancelled = false
    var tokenAttempts = 0
    var tokenOutcome: Error?
    do {
        _ = try await SubtitleAudibleClips.selectProbe(
            in: [broken, good, third], probeSeconds: 20,
            isCancelled: { tokenCancelled }
        ) { _, _ in
            tokenAttempts += 1
            tokenCancelled = true   // 用户在第一段抽取期间按了 Stop
            throw AudioWindowReader.ReadError(message: "no audio track")
        }
    } catch {
        tokenOutcome = error
    }
    check(tokenOutcome is CancellationError,
          "取消期间的 ReadError 必须归成 CancellationError，不许被吞掉继续找")
    checkEqual(tokenAttempts, 1, "取消之后不许再试下一段")

    // ② 结构化取消（Task.isCancelled）：同样不许被 ReadError 洗掉。
    //    在闭包里就地取消当前任务 —— 比「先建 Task 再 cancel」确定得多。
    var structuredAttempts = 0
    let structured = await Task { () -> Error? in
        do {
            _ = try await SubtitleAudibleClips.selectProbe(
                in: [broken, good, third], probeSeconds: 20
            ) { _, _ in
                structuredAttempts += 1
                withUnsafeCurrentTask { $0?.cancel() }
                throw AudioWindowReader.ReadError(message: "no audio track")
            }
            return nil
        } catch {
            return error
        }
    }.value
    check(structured is CancellationError,
          "结构化取消期间的 ReadError 同样要归成 CancellationError")
    checkEqual(structuredAttempts, 1, "结构化取消之后不许再试下一段")

    // ③ **最后一段**失败的同时取消：不许走到 return nil。
    //    这条把「顺序错误」整个消掉 —— nil 的含义收窄成「确实全读不出音频」，
    //    调用方再把 nil 翻成 TaskError 就永远不会冤枉取消。
    var lateCancelled = false
    var lateOutcome: Error?
    var sawNil = false
    do {
        let result = try await SubtitleAudibleClips.selectProbe(
            in: [broken], probeSeconds: 20, isCancelled: { lateCancelled }
        ) { _, _ in
            lateCancelled = true    // 唯一一段失败的同时用户按了 Stop
            throw AudioWindowReader.ReadError(message: "no audio track")
        }
        sawNil = result == nil
    } catch {
        lateOutcome = error
    }
    check(lateOutcome is CancellationError, "最后一段失败时若已取消，必须抛取消而不是返回 nil")
    check(!sawNil, "取消状态下不许把 nil 交给调用方（会被翻成「素材都读不了」）")

    // ④ 进门就已经取消：一次抽取都不许发起（探针是 20s 音频，白跑很贵），
    //    而且必须抛取消 —— 哪怕素材完全读得出来。
    var preAttempts = 0
    var preOutcome: Error?
    do {
        _ = try await SubtitleAudibleClips.selectProbe(
            in: [good, third], probeSeconds: 20, isCancelled: { true }
        ) { clip, _ in preAttempts += 1; return clip.url }
    } catch {
        preOutcome = error
    }
    check(preOutcome is CancellationError, "进门已取消时必须直接抛取消")
    checkEqual(preAttempts, 0, "进门已取消时一次抽取都不许发起")

    // 反过来：没有取消时，全失败仍然是 nil（调用方照旧报「素材读不了」）。
    let genuinelyUnreadable = try await SubtitleAudibleClips.selectProbe(
        in: [broken, good], probeSeconds: 20
    ) { _, _ in throw AudioWindowReader.ReadError(message: "nope") }
    check(genuinelyUnreadable == nil, "没取消时全失败仍是 nil，不许伪装成取消")
}

// MARK: - 20c. 真实媒体：无音轨的视频 → 后面的音频素材仍要能当探针
//
// 上面那组用注入的抽取器验分流**策略**；这一组把生产的
// `AudioWindowReader.extract` 真接上去，喂 ffmpeg 现造的两个文件：
// 一个**真的没有音轨**的 mp4，和一段真的有声音的 m4a。
// 之前的守卫用 makeFile（重复字节的假文件）恰好抓不到这个回归 —— 假文件
// 连「文件存在」这一关都过不了真实解码，测不出「存在 ≠ 可读」。

do {
    guard let mediaPath = ProcessInfo.processInfo.environment["SRTFLOW_CHECK_MEDIA"] else {
        // 静默跳过 = 假绿。没有素材就明确失败。
        check(false, "缺 SRTFLOW_CHECK_MEDIA：真实媒体探针守卫无法运行（脚本该现造素材）")
        fatalError("missing SRTFLOW_CHECK_MEDIA")
    }
    let mediaDir = URL(fileURLWithPath: mediaPath, isDirectory: true)
    let silentVideo = mediaDir.appendingPathComponent("silent-no-audio.mp4")
    let realAudio = mediaDir.appendingPathComponent("real-voice.m4a")
    check(manager.fileExists(atPath: silentVideo.path), "无音轨视频素材要在")
    check(manager.fileExists(atPath: realAudio.path), "有声音的素材要在")

    func soundClip(_ url: URL) -> SubtitleAudibleClips.SoundClip {
        SubtitleAudibleClips.SoundClip(
            clipID: UUID(), name: url.lastPathComponent, url: url,
            fingerprint: url.path, knownAssetDuration: 5,
            sourceStart: 0, sourceDuration: 5, timelineStart: 0, speed: 1, laneRank: 0
        )
    }
    let noAudio = soundClip(silentVideo)
    let voice = soundClip(realAudio)

    // 「文件存在」这一关两个都过 —— 正是本回归的关键：光看存在分不出好坏。
    checkEqual(
        SubtitleAudibleClips.probeOrder(in: [noAudio, voice]).map(\.clipID),
        [noAudio.clipID, voice.clipID],
        "两个文件都存在，probeOrder 分不出谁可读（所以必须真抽一次）"
    )

    let outDir = root.appendingPathComponent("probe-real")
    try manager.createDirectory(at: outDir, withIntermediateDirectories: true)
    let selection = try await SubtitleAudibleClips.selectProbe(
        in: [noAudio, voice], probeSeconds: 20
    ) { clip, range in
        try await AudioWindowReader.extract(
            assetURL: clip.url, range: range, into: outDir, isCancelled: { false }
        )
    }
    checkEqual(selection?.clip.clipID, voice.clipID,
               "真实媒体：无音轨的视频被跳过，探针落到后面的音频素材")
    checkEqual(selection?.skipped.count, 1, "真实媒体：无音轨视频要进跳过记录")
    let extracted = selection.map { manager.fileExists(atPath: $0.file.path) } ?? false
    check(extracted, "真实媒体：探针 CAF 要真的写出来")
    let size = selection.flatMap {
        (try? manager.attributesOfItem(atPath: $0.file.path)[.size] as? NSNumber)??.intValue
    } ?? 0
    check(size > 4096, "真实媒体：探针 CAF 不该是个空壳（实测 \(size) 字节）")

    // 反向：只有无音轨的视频时必须返回 nil，不许硬凑一个探针出来。
    let onlyBroken = try await SubtitleAudibleClips.selectProbe(
        in: [noAudio], probeSeconds: 20
    ) { clip, range in
        try await AudioWindowReader.extract(
            assetURL: clip.url, range: range, into: outDir, isCancelled: { false }
        )
    }
    check(onlyBroken == nil, "真实媒体：全是无音轨素材时定不出探针")
}

// MARK: - 21. 三类选择互斥：剪辑 / 形状 / 字幕 cue
//
// 回归（PR#22 复审 P2）：互斥曾经散在两个 didSet 和一个入口函数里，漏了
// 「选 cue 不清形状」和「选形状不清 cue」两条边 —— 先点形状再点 cue，
// 预览上同时挂两套框。规则现在全在 `EditSelection` 里（字段 private(set)，
// 只能走这几个 mutating 方法），VideoEditProject 的三个属性只是它的门面。

do {
    let clipA = UUID(), clipB = UUID(), shape = UUID(), cue = UUID(), otherCue = UUID()

    // clip → 清形状 + cue
    var s = EditSelection()
    s.selectShape(shape)
    s.selectClips([clipA, clipB])
    checkEqual(s.clipIDs, [clipA, clipB], "选剪辑要生效")
    checkEqual(s.shapeID, nil, "选剪辑清形状")
    checkEqual(s.subtitleCueID, nil, "选剪辑清字幕 cue")

    // shape → 清剪辑 + cue（原来漏的边之一）
    s = EditSelection()
    s.selectSubtitleCue(cue)
    s.selectShape(shape)
    checkEqual(s.shapeID, shape, "选形状要生效")
    checkEqual(s.subtitleCueID, nil, "选形状必须清字幕 cue（cue→shape 方向）")
    checkEqual(s.clipIDs, [], "选形状清剪辑")

    // cue → 清剪辑 + 形状（原来漏的边之二）
    s = EditSelection()
    s.selectShape(shape)
    s.selectSubtitleCue(cue)
    checkEqual(s.subtitleCueID, cue, "选 cue 要生效")
    checkEqual(s.shapeID, nil, "选 cue 必须清形状（shape→cue 方向）")
    s.selectClips([clipA])
    s.selectSubtitleCue(cue)
    checkEqual(s.clipIDs, [], "选 cue 清剪辑")

    // 取消不算改选：⌘点减到空不该顺手抹掉别的类别。
    s = EditSelection()
    s.selectSubtitleCue(cue)
    s.selectClips([])
    checkEqual(s.subtitleCueID, cue, "把剪辑选择清空不等于改选，别动 cue")
    s.selectShape(nil)
    checkEqual(s.subtitleCueID, cue, "把形状选择清空同理")

    // 切工程：三类一起清（closeCurrentDocument 调的就是它）。
    s = EditSelection()
    s.selectClips([clipA])
    s.selectShape(shape)
    s.selectSubtitleCue(cue)
    s.clear()
    check(s.clipIDs.isEmpty && s.shapeID == nil && s.subtitleCueID == nil,
          "clear() 必须三类一起清（切工程/点空白）")

    // 删除或换掉字幕轨：旧 cue 身份对不上就摘掉选择，别留悬空拖框。
    s = EditSelection()
    s.selectSubtitleCue(cue)
    s.pruneSubtitleCue { $0 == otherCue }
    checkEqual(s.subtitleCueID, nil, "字幕轨换成新 cue 身份后要摘掉旧选择")
    s.selectSubtitleCue(cue)
    s.pruneSubtitleCue { $0 == cue }
    checkEqual(s.subtitleCueID, cue, "cue 还在就别乱摘")

    // 撤销把剪辑撤没了同理。
    s = EditSelection()
    s.selectClips([clipA, clipB])
    s.pruneClips { $0 == clipA }
    checkEqual(s.clipIDs, [clipA], "撤销后不存在的剪辑要从选择里摘掉")
}

try? manager.removeItem(at: root)

print("\(checks) checks, \(failures) failures")
if failures == 0 { print("All checks passed") }
exit(failures == 0 ? 0 : 1)
