import Foundation

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

    // 当前版本号照常能开。
    let ok = dir.appendingPathComponent("ok.srtflowproj")
    try Data("""
    { "formatVersion": 1, "timeline": { "mainClips": [] }, "media": [] }
    """.utf8).write(to: ok)
    check((try? VideoEditProjectIO.load(from: ok)) != nil, "当前版本的工程要能打开")
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
    checkEqual(pending, [newImage], "新原图没有静帧缓存，应当报出来重转")
    checkEqual(state.mainClips[0].needsStillConversion, true, "对不上缓存就该标成待转换")
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

try? manager.removeItem(at: root)

print("\(checks) checks, \(failures) failures")
if failures == 0 { print("All checks passed") }
exit(failures == 0 ? 0 : 1)
