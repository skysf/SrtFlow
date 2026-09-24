import CoreGraphics
import Foundation
import SrtFlowCore

// 从 Finder 拖文件进轨道 / ⌘V 粘贴进轨道的**落点**自检。全是纯值变换，
// 不碰 AVFoundation / ffmpeg / 磁盘。编译方式见 scripts/check-media-import.sh。
//
// 产品口径：docs/plans/2026-09-22-media-file-drop.md
// 长期约束：docs/architecture/timeline-drag-gestures.md（主轨数组顺序 = 时间顺序）

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

func checkClose(_ actual: Double, _ expected: Double, _ message: String, line: Int = #line) {
    checks += 1
    if abs(actual - expected) > 0.001 {
        failures += 1
        print("FAIL [line \(line)] \(message): got \(actual), expected \(expected)")
    }
}

/// 取第 `index` 项，越界返回 nil。
///
/// **自检里一律用它，别写裸下标**：实现坏掉时落点会跑到别的轨上，裸下标当场
/// trap，同一轮里其余的失败就全被吞了 —— 守卫要能把话说完。
extension Array {
    func at(_ index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

let media = URL(fileURLWithPath: "/tmp/srtflow-media-import-check/source.mp4")
let tune = URL(fileURLWithPath: "/tmp/srtflow-media-import-check/tune.m4a")

func clip(start: Double, duration: Double) -> EditClip {
    EditClip(sourceURL: media, sourceDuration: duration, timelineStart: start)
}

func audioClip(start: Double, duration: Double) -> EditClip {
    EditClip(
        sourceURL: tune, isAudioOnly: true, sourceDuration: duration,
        timelineStart: start, audioAssetDuration: duration
    )
}

func video(_ duration: Double) -> MediaImportItem {
    MediaImportItem(duration: duration, isAudio: false)
}

func sound(_ duration: Double) -> MediaImportItem {
    MediaImportItem(duration: duration, isAudio: true)
}

// MARK: - 1. 拖到哪里就加到哪里

do {
    var state = TimelineState()
    state.mainClips = [clip(start: 0, duration: 6)]
    let landings = state.mediaImportLandings([video(8)], firstStart: 20, preferring: .main)
    checkEqual(landings.count, 1, "一个文件一个落点")
    checkClose((landings.at(0)?.start ?? -1), 20, "空着的地方：落点就是指针算出来的起点")
    checkEqual(landings.at(0)?.target, .main, "主轨放得下就落主轨")
}

do {
    // 落点在时间线开头之前（指针贴着左边缘、素材又长）：夹到 0，不进负时间。
    var state = TimelineState()
    let landings = state.mediaImportLandings([video(8)], firstStart: -3, preferring: .main)
    checkClose((landings.at(0)?.start ?? -1), 0, "起点夹在 0：时间线上没有负时刻")
    state.mainClips = []
}

// MARK: - 2. 那个位置已经有素材了 → 往上抬一轨

do {
    var state = TimelineState()
    state.mainClips = [clip(start: 0, duration: 30)]
    let landings = state.mediaImportLandings([video(8)], firstStart: 10, preferring: .main)
    checkClose((landings.at(0)?.start ?? -1), 10, "抬一轨**不改时间**：横向还是落在指针那儿")
    checkEqual(landings.at(0)?.target, .newOverlayTop, "主轨占着、又没有上层轨 → 新开一条在最上面")
}

do {
    // 主轨占着，但已经有一条空的上层轨 → 落进它，而不是再开一条。
    var state = TimelineState()
    state.mainClips = [clip(start: 0, duration: 30)]
    state.overlayTracks = [EditLane(clips: [])]
    let landings = state.mediaImportLandings([video(8)], firstStart: 10, preferring: .main)
    checkEqual(landings.at(0)?.target, .overlay(0), "上层轨 0 空着 → 落它，别开新轨")
}

do {
    // 主轨和 overlay 0 都占着 → 继续往上，落 overlay 1。
    var state = TimelineState()
    state.mainClips = [clip(start: 0, duration: 30)]
    state.overlayTracks = [
        EditLane(clips: [clip(start: 5, duration: 20)]),
        EditLane(clips: []),
    ]
    let landings = state.mediaImportLandings([video(8)], firstStart: 10, preferring: .main)
    checkEqual(landings.at(0)?.target, .overlay(1), "一层层往上找，第一条放得下的就是落点")
}

do {
    // 指针指在 overlay 0 上：**从那一条往上找**，不回头去看主轨
    //（主轨在它下面，"上方"是有方向的）。
    var state = TimelineState()
    state.mainClips = []
    state.overlayTracks = [EditLane(clips: [clip(start: 0, duration: 30)])]
    let landings = state.mediaImportLandings([video(8)], firstStart: 10, preferring: .overlay(0))
    checkEqual(landings.at(0)?.target, .newOverlayTop,
               "指着 overlay 0 且它占着 → 往上开新轨，不回落到空着的主轨")
}

do {
    // 隐藏的轨不参与：看不见的轨上落一段素材 = 素材凭空消失。
    var state = TimelineState()
    state.mainClips = [clip(start: 0, duration: 30)]
    state.overlayTracks = [EditLane(clips: [], isHidden: true)]
    let landings = state.mediaImportLandings([video(8)], firstStart: 10, preferring: .main)
    checkEqual(landings.at(0)?.target, .newOverlayTop, "藏起来的空轨不算落点，跳过它开新轨")

    var hiddenMain = TimelineState()
    hiddenMain.mainHidden = true
    let onHidden = hiddenMain.mediaImportLandings([video(8)], firstStart: 10, preferring: .main)
    checkEqual(onHidden.at(0)?.target, .newOverlayTop, "主轨整条藏着时也不许往它上面落")
}

// MARK: - 3. 多个文件首尾相接

do {
    var state = TimelineState()
    let landings = state.mediaImportLandings(
        [video(8), video(8), video(8)], firstStart: 10, preferring: .main
    )
    checkEqual(landings.count, 3, "三个文件三个落点")
    checkClose((landings.at(0)?.start ?? -1), 10, "第一段落在指针处")
    checkClose((landings.at(1)?.start ?? -1), 18, "第二段接在第一段尾巴上")
    checkClose((landings.at(2)?.start ?? -1), 26, "第三段接在第二段尾巴上")
    check(landings.allSatisfy { $0.target == .main }, "主轨一路空着 → 三段都在主轨")
    state.mainClips = []
}

do {
    // 铺的过程中撞上已有素材：撞上的那几段各自抬一轨，没撞上的留在原轨。
    var state = TimelineState()
    state.mainClips = [clip(start: 20, duration: 10)]
    let landings = state.mediaImportLandings(
        [video(8), video(8), video(8)], firstStart: 10, preferring: .main
    )
    checkEqual(landings.at(0)?.target, .main, "10–18 没碰到 20 那一段 → 留主轨")
    checkEqual(landings.at(1)?.target, .newOverlayTop, "18–26 撞上了 → 抬一轨")
    checkEqual(landings.at(2)?.target, .newOverlayTop, "26–34 也撞上了（那段到 30）→ 同样抬上去")
    check(landings.at(1)?.target == landings.at(2)?.target,
          "**同一次导入只开一条新轨**：两段都上去，不是一段开一条")
}

do {
    // 首尾相接的两段彼此不算冲突（1ms 容差同 TimelineState.fits）。
    let state = TimelineState()
    let landings = state.mediaImportLandings(
        [video(5), video(5)], firstStart: 0, preferring: .main
    )
    check(landings.allSatisfy { $0.target == .main },
          "第二段的起点正好是第一段的终点，不该被判成重叠")
}

// MARK: - 4. 类型不匹配：横向照用，纵向退回默认轨

do {
    // 把视频指到音频轨那一行。
    var state = TimelineState()
    state.audioTracks = [EditLane(clips: [])]
    let landings = state.mediaImportLandings([video(8)], firstStart: 12, preferring: .audio(0))
    checkClose((landings.at(0)?.start ?? -1), 12, "横向照用指针的 x")
    checkEqual(landings.at(0)?.target, .main, "纵向退回画面的默认轨（主轨）")
}

do {
    // 把音频指到视频轨那一行。
    var state = TimelineState()
    state.audioTracks = [EditLane(clips: [])]
    let landings = state.mediaImportLandings([sound(8)], firstStart: 12, preferring: .main)
    checkClose((landings.at(0)?.start ?? -1), 12, "横向照用指针的 x")
    checkEqual(landings.at(0)?.target, .audio(0), "纵向退回声音的默认轨")
}

do {
    // 指针不在任何轨上（标尺、字幕 / 形状 / 文字 / 滤镜行，以及 ⌘V 根本没有指针）。
    let state = TimelineState()
    let landings = state.mediaImportLandings(
        [video(4), sound(4)], firstStart: 7, preferring: nil
    )
    checkEqual(landings.at(0)?.target, .main, "没指到轨：画面进主轨")
    checkEqual(landings.at(1)?.target, .newAudioBottom, "没指到轨：声音自己找一条，没有就新开")
    checkClose((landings.at(1)?.start ?? -1), 11, "两段仍然首尾相接（类型不同也照排）")
}

// MARK: - 5. 音频轨：放不下退回从头找，新轨长在最下面
//
// 方向和画面轨**是反的**，这是刻意的：音频轨没有叠放语义（混音是加法），
// 行的上下只是排列。规则和按 `+`、和音频库拖放（addLibraryAudio）完全一致。

do {
    var state = TimelineState()
    state.audioTracks = [
        EditLane(clips: []),
        EditLane(clips: [audioClip(start: 0, duration: 30)]),
    ]
    let landings = state.mediaImportLandings([sound(8)], firstStart: 10, preferring: .audio(1))
    checkEqual(landings.at(0)?.target, .audio(0),
               "指名的那条放不下 → **退回从头找**，不是往下开新轨")
}

do {
    var state = TimelineState()
    state.audioTracks = [EditLane(clips: [audioClip(start: 0, duration: 30)])]
    let landings = state.mediaImportLandings([sound(8)], firstStart: 10, preferring: .audio(0))
    checkEqual(landings.at(0)?.target, .newAudioBottom, "都放不下 → 新开一条在最下面")
}

// MARK: - 6. 落地：插进去之后主轨仍然「数组顺序 = 时间顺序」
//
// 这是硬不变量（docs/architecture/timeline-drag-gestures.md）：A/B 合成轨的
// 插入游标只会前进，乱序当场黑屏
// （docs/bugfixes/2026-08-08-main-track-array-order-black-frame.md）。
// 拖进轨道是**新增的**一个「往 mainClips 中间插段」的入口，所以必须在这里钉住。

do {
    var state = TimelineState()
    state.mainClips = [clip(start: 0, duration: 5), clip(start: 40, duration: 5)]
    let landings = state.mediaImportLandings([video(8)], firstStart: 10, preferring: .main)
    state.insertImported([clip(start: 0, duration: 8)], at: landings)
    checkEqual(state.mainClips.count, 3, "插进去了")
    let starts = state.mainClips.map(\.timelineStart)
    checkEqual(starts, [0, 10, 40], "数组顺序必须跟着时间走（插在中间也是）")
}

do {
    // 落点写进段里：insertImported 负责把 timelineStart 改成落点算出来的值，
    // 调用方给的那个起点不算数。
    var state = TimelineState()
    let landings = state.mediaImportLandings([video(8)], firstStart: 13, preferring: .main)
    state.insertImported([clip(start: 999, duration: 8)], at: landings)
    checkClose(state.mainClips.at(0)?.timelineStart ?? -1, 13, "段的起点 = 落点，不是传进来的那个 999")
}

do {
    // 两段都要新开上层轨 → 落地时也只开一条（和落点算法算的对得上）。
    var state = TimelineState()
    state.mainClips = [clip(start: 0, duration: 40)]
    let landings = state.mediaImportLandings(
        [video(8), video(8)], firstStart: 10, preferring: .main
    )
    state.insertImported(
        [clip(start: 0, duration: 8), clip(start: 0, duration: 8)], at: landings
    )
    checkEqual(state.overlayTracks.count, 1, "只新开一条上层轨")
    checkEqual(state.overlayTracks.at(0)?.clips.count, 2, "两段都落进那一条")
    checkEqual(state.overlayTracks.at(0)?.clips.map(\.timelineStart), [10, 18], "轨内按时间排好")
}

do {
    // 新开的上层轨落在数组**末尾** = 画在最上面（同 relocateClip 的
    // .newOverlayTop）。开在中间会把已有轨的叠放次序改掉。
    var state = TimelineState()
    state.mainClips = [clip(start: 0, duration: 40)]
    let existing = EditLane(clips: [clip(start: 0, duration: 40)])
    state.overlayTracks = [existing]
    let landings = state.mediaImportLandings([video(8)], firstStart: 10, preferring: .main)
    state.insertImported([clip(start: 0, duration: 8)], at: landings)
    checkEqual(state.overlayTracks.count, 2, "开了第二条上层轨")
    checkEqual(state.overlayTracks.at(0)?.id, existing.id, "原来那条还在原位（叠放次序没被动）")
    checkEqual(state.overlayTracks.at(1)?.clips.count, 1, "新素材在最上面那条")
}

do {
    // 音频同理：新轨 append 到末尾 = 画在最下面。
    var state = TimelineState()
    let existing = EditLane(clips: [audioClip(start: 0, duration: 40)])
    state.audioTracks = [existing]
    let landings = state.mediaImportLandings([sound(8)], firstStart: 10, preferring: .audio(0))
    state.insertImported([audioClip(start: 0, duration: 8)], at: landings)
    checkEqual(state.audioTracks.count, 2, "开了第二条音频轨")
    checkEqual(state.audioTracks.at(0)?.id, existing.id, "原来那条还在原位")
}

// MARK: - 7. 畸形输入

do {
    var state = TimelineState()
    let landings = state.mediaImportLandings([], firstStart: 10, preferring: .main)
    check(landings.isEmpty, "没有文件就没有落点")
    state.insertImported([], at: [])
    check(state.mainClips.isEmpty, "空落地不该动时间线")
}

do {
    // 0 长度的畸形素材：给个下限，别在时间线上留一个选不中、删不掉的点。
    let state = TimelineState()
    let landings = state.mediaImportLandings([video(0)], firstStart: 10, preferring: .main)
    check((landings.at(0)?.duration ?? -1) >= TimelineState.minimumImportedDuration,
          "0 长度被抬到下限，得到 \((landings.at(0)?.duration ?? -1))")
}

do {
    // clips 比 landings 多（理论上不该发生）：多出来的忽略掉，不要越界崩溃。
    var state = TimelineState()
    let landings = state.mediaImportLandings([video(4)], firstStart: 0, preferring: .main)
    state.insertImported(
        [clip(start: 0, duration: 4), clip(start: 0, duration: 4)], at: landings
    )
    checkEqual(state.mainClips.count, 1, "按较短的一边配对，不越界")
}

// MARK: - 8. 磁吸开着时，落点框画在拼完之后的位置
//
// 落地走 `perform { insertImported }`，磁吸开着时 `perform` 收尾会 `packMain()`：
// 落主轨的段会被拼到故事线末尾。框要是照 `mediaImportLandings` 原样画，就是
// 「框在指针底下、素材落到主轨末尾」。

do {
    var state = TimelineState()
    state.mainClips = [clip(start: 0, duration: 10)]
    let raw = state.mediaImportLandings([video(8)], firstStart: 30, preferring: .main)
    checkEqual(raw.at(0)?.target, .main, "30 秒处主轨空着 → 落主轨")
    let shown = state.landingsAfterMagnet(raw)
    checkClose(shown.at(0)?.start ?? -1, 10, "磁吸：框画在拼完之后的位置（接在主轨末尾），不是指针处的 30")
    // 和真落地对账：同一份落点走 insertImported + packMain，结果必须和框一致。
    var landed = state
    landed.insertImported([clip(start: 0, duration: 8)], at: raw)
    landed.packMain()
    checkClose(landed.mainClips.at(1)?.timelineStart ?? -1, shown.at(0)?.start ?? -2,
               "框和落地对得上")
}

do {
    // 没有段落主轨（撞上了、抬到上层轨）：磁吸不动它，原样返回。
    var state = TimelineState()
    state.mainClips = [clip(start: 0, duration: 30)]
    let raw = state.mediaImportLandings([video(8)], firstStart: 10, preferring: .main)
    checkEqual(raw.at(0)?.target, .newOverlayTop, "主轨占着 → 抬轨")
    checkEqual(state.landingsAfterMagnet(raw), raw, "不落主轨时磁吸不改落点")
}

do {
    // 多段都落主轨：拼完之后首尾相接，接在已有素材后面。
    var state = TimelineState()
    state.mainClips = [clip(start: 0, duration: 10)]
    let raw = state.mediaImportLandings([video(4), video(6)], firstStart: 20, preferring: .main)
    let shown = state.landingsAfterMagnet(raw)
    checkClose(shown.at(0)?.start ?? -1, 10, "第一段接在主轨末尾 10")
    checkClose(shown.at(1)?.start ?? -1, 14, "第二段接在第一段后面 14")
}

// MARK: - 9. 拖进拉开的插入缝（2026-09-24，docs/plans/2026-09-24-track-insert-and-reorder.md）
//
// 类型和缝对得上的段全部落进缝里新开的那**一条**轨，首尾相接；对不上的照原来的规则落
// （横向照用指针，纵向退回这一类的默认轨）。

do {
    // 两条上层轨之间的缝，一次拖进两个视频：同一条新轨，首尾相接，别的轨原样。
    var state = TimelineState()
    state.mainClips = [clip(start: 0, duration: 30)]
    let low = EditLane(clips: [clip(start: 0, duration: 30)])
    let high = EditLane(clips: [clip(start: 0, duration: 30)])
    state.overlayTracks = [low, high]
    let landings = state.mediaImportLandings([video(5), video(3)], firstStart: 4,
                                             preferring: .insertOverlay(at: 1))
    checkEqual(landings.map(\.target), [.insertOverlay(at: 1), .insertOverlay(at: 1)],
               "两段都落进这条缝（不因为别的轨撞上就抬走）")
    checkClose(landings.at(0)?.start ?? -1, 4, "第一段从指针处开始")
    checkClose(landings.at(1)?.start ?? -1, 9, "第二段接在后面")

    var next = state
    let a = clip(start: 0, duration: 5)
    let b = clip(start: 0, duration: 3)
    next.insertImported([a, b], at: landings)
    checkEqual(next.overlayTracks.count, 3, "只新开了**一条**轨")
    checkEqual(next.overlayTracks.at(0)?.id, low.id, "缝下面那条轨原样在下面")
    checkEqual(next.overlayTracks.at(2)?.id, high.id, "缝上面那条轨原样在上面")
    checkEqual(next.overlayTracks.at(1)?.clips.map(\.id), [a.id, b.id], "两段都在缝里那条新轨上")
    checkClose(next.clip(with: b.id)?.timelineStart ?? -1, 9, "落地的起点 = 落点算的起点")
}

do {
    // 视频 + 音频一起拖进音频缝：音频进缝里的新轨；视频对不上，照原规则落主轨（放得下）。
    var state = TimelineState()
    let first = EditLane(clips: [audioClip(start: 0, duration: 20)])
    let second = EditLane(clips: [audioClip(start: 0, duration: 20)])
    state.audioTracks = [first, second]
    let landings = state.mediaImportLandings([video(4), sound(6)], firstStart: 2,
                                             preferring: .insertAudio(at: 1))
    checkEqual(landings.at(0)?.target, .main, "视频对不上音频缝：退回画面梯子最底下（主轨放得下）")
    checkEqual(landings.at(1)?.target, .insertAudio(at: 1), "音频进缝里的新轨")
    checkClose(landings.at(1)?.start ?? -1, 6, "照样首尾相接（接在视频后面）")

    var next = state
    let v = clip(start: 0, duration: 4)
    let s = audioClip(start: 0, duration: 6)
    next.insertImported([v, s], at: landings)
    checkEqual(next.audioTracks.map(\.id).first, first.id, "上面那条音频轨不动")
    checkEqual(next.audioTracks.map(\.id).last, second.id, "下面那条音频轨不动")
    checkEqual(next.audioTracks.at(1)?.clips.map(\.id), [s.id], "音频落在两条中间的新轨上")
    checkEqual(next.mainClips.map(\.id), [v.id], "视频落在主轨")
}

do {
    // 音频拖进**视频缝**：对不上，按音频的老规矩（指名的放不下就从头找，都放不下最下面新开）。
    var state = TimelineState()
    state.audioTracks = [EditLane(clips: [audioClip(start: 0, duration: 20)])]
    let landings = state.mediaImportLandings([sound(5)], firstStart: 3, preferring: .insertOverlay(at: 0))
    checkEqual(landings.at(0)?.target, .newAudioBottom, "唯一那条音频轨占着 → 最下面新开一条")
}

do {
    // 音频库：缝里 → 在缝的位置新开；指名的放得下 → 那条；放不下 → `place`。
    var state = TimelineState()
    let top = EditLane(clips: [audioClip(start: 0, duration: 10)])
    let bottom = EditLane(clips: [audioClip(start: 20, duration: 10)])
    state.audioTracks = [top, bottom]

    var inserted = state
    let song = audioClip(start: 2, duration: 30)
    inserted.placeLibraryAudio(song, laneIndex: nil, insertAt: 1)
    checkEqual(inserted.audioTracks.count, 3, "拖进缝：多一条音频轨")
    checkEqual(inserted.audioTracks.at(1)?.clips.map(\.id), [song.id], "新轨夹在两条之间")
    checkEqual(inserted.audioTracks.at(2)?.id, bottom.id, "下面那条原样在下面")

    var named = state
    let short = audioClip(start: 12, duration: 5)
    named.placeLibraryAudio(short, laneIndex: 0, insertAt: nil)
    checkEqual(named.audioTracks.at(0)?.clips.last?.id, short.id, "指名的那条放得下：放那条")

    var bumped = state
    let clash = audioClip(start: 5, duration: 5)
    bumped.placeLibraryAudio(clash, laneIndex: 0, insertAt: nil)
    checkEqual(bumped.audioTracks.at(0)?.clips.count, 1, "指名的那条放不下：不硬塞")
    checkEqual(bumped.audioTracks.at(1)?.clips.first?.id, clash.id, "交给 place：第二条放得下")
}

// MARK: - 收尾

print("MediaImport checks: \(checks) 项，失败 \(failures) 项")
if failures > 0 {
    exit(1)
}
print("OK")
