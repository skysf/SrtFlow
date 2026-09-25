import Foundation

// 从 main.swift 搬出来（2026-09-24，那个文件是登记过的老超标文件，只许降不许涨）：第 27 组，
// 轨道行高。编译方式见 scripts/check-project-file.sh。

func checkRowHeights(root: URL) throws {
    let dir = root.appendingPathComponent("rowheights")
    let media = dir.appendingPathComponent("a.mp4")
    makeFile(media)
    let project = dir.appendingPathComponent("p.srtflowproj")

    // ---- 夹紧：两类各自的区间，不可调的类一律拒绝 ----
    checkEqual(TrackRowKind(.main), .video, "主轨算视频轨")
    checkEqual(TrackRowKind(.overlay(0)), .video, "上层轨和主轨同一类（对等）")
    checkEqual(TrackRowKind(.audio(0)), .audio, "音频轨自成一类")
    checkEqual(TrackRowKind(nil), .other, "没有 slot 的行不可调")
    checkEqual(TrackRowKind.video.clamped(1000), 200, "视频轨行高上限 200")
    checkEqual(TrackRowKind.video.clamped(0), 28, "视频轨行高下限 28")
    checkEqual(TrackRowKind.audio.clamped(1000), 200, "音频轨行高上限 200")
    checkEqual(TrackRowKind.audio.clamped(0), 20, "音频轨行高下限 20")
    check(TrackRowKind.other.clamped(50) == nil,
          "字幕/文字/形状/滤镜行不可调：行高和块高是一对硬编码常量，框选的命中判据靠那个差")
    check(TrackRowKind.video.clamped(.nan) == nil, "NaN 不许落进行高")
    check(TrackRowKind.video.clamped(.infinity) == nil, "inf 不许落进行高")

    // ---- 没调过的轨回落到这一类的默认值 ----
    var heights = TimelineRowHeights()
    checkEqual(heights.height(for: .main, fallback: 54), 54, "没调过就走默认高度")
    checkEqual(heights.height(for: nil, fallback: 54), 54, "不可调的行也得拿到一个能用的高度")
    heights.set(300, for: .main, kind: .video)
    checkEqual(heights.main, 200, "写入口就该夹紧，别让越界值存进工程")
    heights.set(70, for: .main, kind: .other)
    checkEqual(heights.main, 200, "不可调的类写不进去")

    // ---- 三条轨各调各的：拖一条不许动到另一条 ----
    var state = timeline(mainMedia: [media])
    let audioA = EditLane(clips: [EditClip(sourceURL: media, isAudioOnly: true, sourceDuration: 8)])
    let audioB = EditLane(clips: [EditClip(sourceURL: media, isAudioOnly: true, sourceDuration: 8)])
    state.audioTracks = [audioA, audioB]
    checkEqual(TimelineRowHeights.key(for: .audio(0), in: state), .lane(audioA.id),
               "行 → 键走的是轨道身份（UUID），不是行号")
    checkEqual(TimelineRowHeights.key(for: .audio(1), in: state), .lane(audioB.id),
               "第二条轨要拿到自己的身份，不是第一条的")
    check(TimelineRowHeights.key(for: .audio(5), in: state) == nil, "越界的行没有键")
    check(TimelineRowHeights.key(for: nil, in: state) == nil, "没有 slot 的行没有键")

    var perTrack = TimelineRowHeights()
    perTrack.set(88, for: .lane(audioA.id), kind: .audio)
    checkEqual(perTrack.height(for: .lane(audioA.id), fallback: 34), 88, "调过的那条用自己的高度")
    checkEqual(perTrack.height(for: .lane(audioB.id), fallback: 34), 34,
               "同类的另一条不许跟着动 —— 这正是 2026-09-22 要修掉的毛病")
    checkEqual(perTrack.height(for: .main, fallback: 54), 54, "主轨更不该跟着音频轨动")

    // ---- 存盘往返 ----
    perTrack.set(96, for: .main, kind: .video)
    try VideoEditProjectIO.save(state, to: project, rowHeights: perTrack)
    let loaded = try VideoEditProjectIO.load(from: project)
    checkEqual(loaded.rowHeights.main, 96, "主轨行高要存住")
    checkEqual(loaded.rowHeights.height(for: .lane(audioA.id), fallback: 34), 88,
               "每条轨的行高都要存住")
    checkEqual(loaded.rowHeights.height(for: .lane(audioB.id), fallback: 34), 34,
               "没调过的轨读回来还是没调过")

    // ---- 键绑身份：删掉前一条轨，后一条不许继承它的高度 ----
    var shortened = state
    shortened.audioTracks.removeFirst()          // 剩下的 B 现在是 .audio(0)
    let afterDelete = dir.appendingPathComponent("after-delete.srtflowproj")
    try VideoEditProjectIO.save(shortened, to: afterDelete, rowHeights: perTrack)
    let reloaded = try VideoEditProjectIO.load(from: afterDelete)
    checkEqual(TimelineRowHeights.key(for: .audio(0), in: shortened), .lane(audioB.id),
               "删掉中间一条轨之后，行号变了、身份没变")
    checkEqual(reloaded.rowHeights.height(for: .lane(audioB.id), fallback: 34), 34,
               "删掉上面那条轨，剩下的轨不许继承它的高度（键绑身份不绑行号）")
    check(reloaded.rowHeights.lanes[audioA.id] == nil, "删掉的轨不该留在工程文件里")

    // 裁剪只作用在写盘那一份拷贝上：内存里的条目要留着，
    // 否则「删一条轨 → 自动保存 → ⌘Z 撤回来」高度就没了。
    checkEqual(perTrack.lanes[audioA.id], 88, "裁剪不许回写调用方手里的那份")
    checkEqual(perTrack.pruned(keeping: []).lanes.count, 0, "裁剪本身要真的丢掉死条目")
    checkEqual(perTrack.pruned(keeping: []).main, 96, "主轨不是 lane，裁剪不许把它一起丢了")

    // ---- 老工程：没有这个键，读回来是空的（全部走默认值）----
    let legacy = dir.appendingPathComponent("legacy.srtflowproj")
    try VideoEditProjectIO.save(state, to: legacy)
    let legacyText = try String(contentsOf: legacy, encoding: .utf8)
    check(!legacyText.contains("rowHeights"),
          "没人调过行高的工程不该多出这个键（按需写键）")
    let legacyLoaded = try VideoEditProjectIO.load(from: legacy)
    check(legacyLoaded.rowHeights.isEmpty, "老工程读回来是空的 = 全部走默认值")
    checkEqual(legacyLoaded.rowHeights.height(for: .main, fallback: 54), 54,
               "老工程打开就是老样子")
}
