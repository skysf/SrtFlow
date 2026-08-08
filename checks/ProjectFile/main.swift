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
    // 契约已变（工程帧率落地后）：新版 writer 一律写 latest（v5）。
    // 原本这里守的是「普通工程别被无谓抬版本」，那个目的现在由「v1–v4 老文件
    // 仍然读得开」来守（见下方 for oldVersion 循环）。
    checkEqual(
        raw?["formatVersion"] as? Int,
        VideoEditProjectFile.latestFormatVersion,
        "新版写盘一律用最新格式版本"
    )
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
    checkEqual(try savedVersion(), 5, "只有原文轨的工程也写 v5（帧率无条件落盘）")

    var roundtrip = try VideoEditProjectIO.load(from: project).timeline
    try VideoEditProjectIO.save(roundtrip, to: project)
    checkEqual(try savedVersion(), 5, "往返后仍是 v5")
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
    checkEqual(try savedVersion(), 5, "带译文轨的工程写 v5（v4 的登记项已被 v5 覆盖）")
    // requiresFormatVersion4 的登记判据本身仍要成立
    check(roundtrip.requiresFormatVersion4, "有 companion 数据时 v4 判据要为真")

    let loaded = try VideoEditProjectIO.load(from: project).timeline
    checkEqual(loaded.subtitleCompanion?.translation?.cues.count, 2, "译文轨要存住")
    checkEqual(loaded.subtitleCompanion?.translation?.cues.first?.id, cueA.id, "译文 cue 与原文共 ID")
    checkEqual(loaded.subtitleCompanion?.translation?.cues.first?.text, "你好", "译文文本要存住")
    checkEqual(loaded.subtitleCompanion?.targetLanguage, "zh-Hans", "目标语言要存住")
    checkEqual(loaded.subtitleCompanion?.cueMeta[cueA.id]?.recognitionConfidence, 0.9, "cueMeta 要存住")
    checkEqual(loaded.subtitleCompanion?.cueMeta[cueA.id]?.translationStale, true, "stale 标记要存住")

    // 删光 v4 数据后仍然是 v5：帧率是**无条件**的 v5 字段（每个工程都有帧率，
    // 而 v4 及更早把帧率硬编码成 30），所以新版 writer 一律写 v5，不再降级。
    var cleared = loaded
    cleared.subtitleCompanion = nil
    try VideoEditProjectIO.save(cleared, to: project)
    checkEqual(try savedVersion(), 5, "新版 writer 一律写 v5（帧率无条件落盘）")

    // v5 文件本版能开；v6 拒开（闸门以 reader 上限比较）。
    check(VideoEditProjectFile.latestFormatVersion == 5, "reader 上限应是 v5")
    let v6 = dir.appendingPathComponent("v6.srtflowproj")
    try Data("""
    { "formatVersion": 6, "timeline": { "mainClips": [] }, "media": [] }
    """.utf8).write(to: v6)
    check((try? VideoEditProjectIO.load(from: v6)) == nil, "未来版本（v6）必须拒开")

    // ---- 工程帧率（v5，无条件）----
    //
    // 反例守卫：**默认 24 也必须显式落盘并写 v5**。
    // 若省略该键并降级成 v3，旧版会按硬编码的 30fps 打开 —— 同一文件在新旧版
    // 出不同成片，正是版本闸门要防的语义破坏。
    var fpsProject = cleared
    fpsProject.frameRate = .fps24
    try VideoEditProjectIO.save(fpsProject, to: project)
    checkEqual(try savedVersion(), 5, "默认 24fps 也要写 v5，不能降级")
    let savedJSON = try String(contentsOf: project, encoding: .utf8)
    check(savedJSON.contains("\"frameRate\""), "默认 24fps 的键必须真的写进文件")
    checkEqual(try VideoEditProjectIO.load(from: project).timeline.frameRate, .fps24,
               "默认帧率要能原样读回")

    fpsProject.frameRate = .fps60
    try VideoEditProjectIO.save(fpsProject, to: project)
    checkEqual(try savedVersion(), 5, "非默认帧率同样是 v5")
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

try? manager.removeItem(at: root)

print("\(checks) checks, \(failures) failures")
if failures == 0 { print("All checks passed") }
exit(failures == 0 ? 0 : 1)
