import Foundation

// MARK: - 从 Finder 导入素材的落点（纯值）
//
// 2026-09-22 产品决策：**拖到哪里就加到哪里；那个位置已经有素材了，就往上抬一轨**。
// 在那之前，不管指针落在时间线的哪儿，视频一律接在主轨末尾、音频一律落在播放头
// （`VideoEditProject.addMedia`），于是「拖进轨道」这件事在界面上根本不成立。
// 完整口径见 docs/plans/2026-09-22-media-file-drop.md。
//
// **为什么单独一个纯值文件**：落点是这套东西里唯一有分支的部分（梯子、冲突、
// 新开轨、多文件接龙），而它必须被自检钉住。被测代码在 SrtFlow 这个 app target
// 里、自检脚本是直接挑源文件编的（见 `scripts/check-project-file.sh` 开头），
// 不 import SwiftUI / AppKit 才编得动。接线在 `VideoEditMediaFileDrop.swift`。
//
// **画落点框和真落地共用 `mediaImportLandings`**：各算一遍必然分叉 —— 框画在这条
// 轨、素材落到另一条，是这个仓库反复踩的那一类错（`crossTrackLandingSpan`、
// `TimelineSnap.mainInsertion` 都是同一条教训的产物）。

/// 一段要导入的素材：时长，以及它该进画面轨还是声音轨。
///
/// 只有这两个字段是落点算法需要的 —— 具体是视频还是图片、从哪来，落点不关心。
struct MediaImportItem: Equatable, Sendable {
    var duration: Double
    var isAudio: Bool

    init(duration: Double, isAudio: Bool) {
        self.duration = duration
        self.isAudio = isAudio
    }
}

/// 一段导入素材的落点：几秒开始、落进哪条轨。
struct MediaImportLanding: Equatable, Sendable {
    var start: Double
    var duration: Double
    var target: TrackDropTarget

    var end: Double { start + duration }
}

extension TimelineState {

    /// 画面素材能落的轨，**从下往上**：主轨 → 上层轨 0…n-1 → 新开一条（画在最上面）。
    ///
    /// 梯子的顺序就是时间线上行的顺序（`VideoEditTimelineView.rows`：上层轨编号大的
    /// 画在上面），所以「往上抬一轨」= 在这个数组里往后走一格。
    ///
    /// **隐藏的轨不上梯子**（同 `place` 跳过 `isHidden`）：往一条看不见的轨上落素材，
    /// 用户看到的是「拖进去了，什么都没出现」。
    func videoImportLadder() -> [TrackDropTarget] {
        var ladder: [TrackDropTarget] = mainHidden ? [] : [.main]
        for index in overlayTracks.indices where !overlayTracks[index].isHidden {
            ladder.append(.overlay(index))
        }
        ladder.append(.newOverlayTop)
        return ladder
    }

    /// 声音素材能落的轨：音频轨 0…n-1 → 新开一条（长在最下面）。
    ///
    /// 注意方向和画面轨**是反的**：音频行按下标递增往下排，新轨 append 到数组末尾
    /// 就长在最下面。这不是疏忽 —— 音频轨没有叠放语义（混音是加法），行的上下只是
    /// 排列，"上方"对它不成立。见下面 `mediaImportLandings` 里试轨顺序那一段。
    func audioImportLadder() -> [TrackDropTarget] {
        var ladder: [TrackDropTarget] = []
        for index in audioTracks.indices where !audioTracks[index].isHidden {
            ladder.append(.audio(index))
        }
        ladder.append(.newAudioBottom)
        return ladder
    }

    /// 一次导入（可能是多个文件）落在哪。
    ///
    /// - `firstStart`：第一段的起点（拖放是指针算出来的，⌘V 是播放头）。
    /// - `preferred`：指针指着的那条轨。`nil` = 没指到任何轨（拖到标尺、
    ///   字幕/形状/文字/滤镜行，或者走 ⌘V 根本没有指针）。
    ///
    /// 三条规则，都是 2026-09-22 用户拍板的：
    ///
    /// 1. **多段首尾相接**从 `firstStart` 往后铺，不是全部叠在同一个起点。
    /// 2. **画面撞上了就往上抬一轨**：从指针那条轨起，沿梯子逐条试，第一条放得下的
    ///    就是落点；都放不下就新开一条在最上面。
    /// 3. **纵向退回默认轨**：指针指着的行放不了这种素材（把 mp4 拖到音频轨、拖到
    ///    字幕行……），横向照用指针的 x，纵向从梯子最底下重新找。
    ///
    /// 2026-09-24 加的第四条：`preferred` 是**拉开的插入缝**（`.insertOverlay` /
    /// `.insertAudio`）时，类型和这条缝对得上的段全部落进缝里新开的那**一条**轨，
    /// 首尾相接（新轨是空的，撞不上）；类型对不上的按上面三条落（同第 3 条：横向照用
    /// 指针，纵向退回这一类的默认轨）。见 docs/plans/2026-09-24-track-insert-and-reorder.md。
    func mediaImportLandings(
        _ items: [MediaImportItem],
        firstStart: Double,
        preferring preferred: TrackDropTarget?
    ) -> [MediaImportLanding] {
        let ladders = [false: videoImportLadder(), true: audioImportLadder()]
        // 每一级梯子上已经占着的区间。**同一次导入里先落下的段也要记账** ——
        // 否则三个文件会各自开一条新轨（它们都看到「最上面那条是空的」），
        // 或者两段挤进同一条轨的同一个空档。
        var busy = ladders.mapValues { $0.map { rung in occupiedSpans(on: rung) } }
        // 缝不在梯子上：对不上类型的那些段，当作「没指到任何轨」。
        let pointedTarget = preferred?.insertion == nil ? preferred : nil

        var result: [MediaImportLanding] = []
        var cursor = max(0, firstStart)
        for item in items {
            // 0 长度的段在时间线上是个点：选不中、拖不动、删不掉。给个下限。
            let duration = max(Self.minimumImportedDuration, item.duration)
            if let preferred, preferred.insertion?.audio == item.isAudio {
                // 落进拉开的缝：同一条新轨，首尾相接（`insertImported` 按落点只开一条）。
                result.append(MediaImportLanding(start: cursor, duration: duration, target: preferred))
                cursor += duration
                continue
            }
            guard let ladder = ladders[item.isAudio], !ladder.isEmpty else { continue }
            let pointed = pointedTarget.flatMap { wanted in ladder.firstIndex { $0 == wanted } }

            // 试轨的顺序。
            //
            // - **画面**：从指针那条轨往上逐条试。梯子最后一级是「新开一条」，
            //   它永远是空的，所以一定有落点。
            // - **声音**：指名的那条放得下就用它，放不下**退回从头找** —— 和按 `+`
            //   （`TimelineState.place`）、和音频库拖放（`addLibraryAudio`）完全
            //   同一套规矩。"往上抬"对音频轨没有意义，见 `audioImportLadder`。
            let order: [Int]
            if item.isAudio {
                if let pointed {
                    order = [pointed] + ladder.indices.filter { $0 != pointed }
                } else {
                    order = Array(ladder.indices)
                }
            } else {
                order = Array((pointed ?? 0)..<ladder.count)
            }

            guard var lanes = busy[item.isAudio], lanes.count == ladder.count else { continue }
            let rung = order.first { Self.fits(start: cursor, duration: duration, among: lanes[$0]) }
                ?? ladder.count - 1
            lanes[rung].append(TimelineSpan(start: cursor, end: cursor + duration))
            busy[item.isAudio] = lanes

            result.append(
                MediaImportLanding(start: cursor, duration: duration, target: ladder[rung])
            )
            cursor += duration
        }
        return result
    }

    /// 把探测好的素材按 `mediaImportLandings` 算出来的落点放进时间线。
    ///
    /// `clips` 和 `landings` 一一对应（多出来的一边被忽略）。
    mutating func insertImported(_ clips: [EditClip], at landings: [MediaImportLanding]) {
        // 落点里的「第几条轨」是按**这一批落地之前**的排布算的。这一批里要是在缝里
        // 新插了一条轨（2026-09-24 起有这种落点），后面的下标就会错位 —— 所以先把
        // 下标翻成轨道身份，再动数组。
        let overlayIDs = overlayTracks.map(\.id)
        let audioIDs = audioTracks.map(\.id)
        // 这一次导入新开的轨，按落点记。同一个落点的第二段也要落进**同一条**，不能
        // 一段开一条 —— 落点算法把它们算在同一级梯子上 / 同一条缝里，这里必须对得上。
        var fresh: [TrackDropTarget: UUID] = [:]
        var touchedMain = false

        for (clip, landing) in zip(clips, landings) {
            var placed = clip
            placed.timelineStart = landing.start
            switch landing.target {
            case .main:
                mainClips.append(placed)
                touchedMain = true
            case .overlay(let index) where overlayIDs.indices.contains(index):
                appendImported(placed, toLane: overlayIDs[index], audio: false)
            case .audio(let index) where audioIDs.indices.contains(index):
                appendImported(placed, toLane: audioIDs[index], audio: true)
            case .overlay, .newOverlayTop:
                // 指到的轨号已经不在了，和「最上面新开一条」走同一条路。
                // 数组末尾 = 层级最高 = 显示在最上面一行（同 relocateClip）。
                if let id = fresh[.newOverlayTop] {
                    appendImported(placed, toLane: id, audio: false)
                } else {
                    fresh[.newOverlayTop] = insertLane(audio: false, at: overlayTracks.count, clips: [placed])
                }
            case .audio, .newAudioBottom:
                if let id = fresh[.newAudioBottom] {
                    appendImported(placed, toLane: id, audio: true)
                } else {
                    fresh[.newAudioBottom] = insertLane(audio: true, at: audioTracks.count, clips: [placed])
                }
            case .insertOverlay(let index), .insertAudio(let index):
                let audio = landing.target.insertion?.audio == true
                if let id = fresh[landing.target] {
                    appendImported(placed, toLane: id, audio: audio)
                } else {
                    fresh[landing.target] = insertLane(audio: audio, at: index, clips: [placed])
                }
            }
        }

        // 主轨「数组顺序 = 时间顺序」是硬不变量
        //（docs/architecture/timeline-drag-gestures.md）：上面是裸 append，往中间
        // 插的段会把顺序打乱 —— A/B 合成轨的插入游标只会前进，乱序当场黑屏
        //（docs/bugfixes/2026-08-08-main-track-array-order-black-frame.md）。
        if touchedMain { sortMainClipsByStart() }
    }

    /// 磁吸开着时，这批落点**最后**会落在哪。
    ///
    /// 落地走的是 `perform { insertImported }`，而 `perform` 在磁吸开着时收尾会
    /// `packMain()` —— 落主轨的段会被拼到故事线末尾，不在指针底下。落点框要是照
    /// `mediaImportLandings` 的原样画，就是「框在这儿、素材落到那儿」。
    ///
    /// 所以在副本上把落地那两步原样走一遍（同一个 `insertImported`、同一个
    /// `packMain`），读回每一段的起点 —— 不另写一份「磁吸会把它挪到哪」的推算，
    /// 各算一份迟早分叉。没有段落主轨时原样返回。
    func landingsAfterMagnet(_ landings: [MediaImportLanding]) -> [MediaImportLanding] {
        guard landings.contains(where: { $0.target == .main }) else { return landings }
        var simulated = self
        let stand = URL(fileURLWithPath: "/dev/null")
        let placeholders = landings.map { EditClip(sourceURL: stand, sourceDuration: $0.duration) }
        simulated.insertImported(placeholders, at: landings)
        simulated.packMain()
        return zip(placeholders, landings).map { placeholder, landing in
            var landed = landing
            if let clip = simulated.clip(with: placeholder.id) { landed.start = clip.timelineStart }
            return landed
        }
    }

    /// 音频库素材落在哪条音频轨（拖放、按 `+` 共用）。
    ///
    /// - `insertAt`：拖放时指针在**拉开的插入缝**里 → 在缝的位置新开一条（2026-09-24）；
    /// - `laneIndex`：指名的那条放得下就放那条 —— **放不下时不硬塞**，叠在别的块上会让
    ///   两段同时出声，而用户看到的是一条轨上两个块重叠在一起；
    /// - 其余交给 `place`：第一条放得下的，都放不下在最下面新开一条（和按 `+` 同一套）。
    ///
    /// 从 `VideoEditProject.addLibraryAudio` 挪出来的纯值版，自检够得着它
    /// （`scripts/check-media-import.sh`）。
    mutating func placeLibraryAudio(_ clip: EditClip, laneIndex: Int?, insertAt: Int?) {
        if let insertAt {
            insertLane(audio: true, at: insertAt, clips: [clip])
            return
        }
        if let laneIndex, audioTracks.indices.contains(laneIndex),
           !audioTracks[laneIndex].isHidden,
           audioTracks[laneIndex].clips.allSatisfy({
               $0.timelineStart >= clip.timelineEnd - 0.001
                   || clip.timelineStart >= $0.timelineEnd - 0.001
           }) {
            audioTracks[laneIndex].clips.append(clip)
            audioTracks[laneIndex].clips.sort { $0.timelineStart < $1.timelineStart }
        } else {
            _ = place(clip, intoAudio: true)
        }
    }

    /// 导入素材的最短时长。探测失败不会走到这里（那条路直接报错），这是给
    /// 0 长度的畸形文件兜底的。
    static let minimumImportedDuration = 0.1

    /// 某一级梯子上已经占着的区间（粘贴的落点也用它，`ClipPasteLanding`）。
    func occupiedSpans(on target: TrackDropTarget) -> [TimelineSpan] {
        let clips: [EditClip]
        switch target {
        case .main:
            clips = mainClips
        case .overlay(let index):
            clips = overlayTracks.indices.contains(index) ? overlayTracks[index].clips : []
        case .audio(let index):
            clips = audioTracks.indices.contains(index) ? audioTracks[index].clips : []
        case .newOverlayTop, .newAudioBottom, .insertOverlay, .insertAudio:
            clips = []
        }
        return clips.map { TimelineSpan(start: $0.timelineStart, end: $0.timelineEnd) }
    }

    /// 往一条现有的轨（按身份找）上放一段，轨里保持按时间排（粘贴也走它，`insertPasted`）。
    mutating func appendImported(_ clip: EditClip, toLane id: UUID, audio: Bool) {
        if audio {
            guard let index = audioTracks.firstIndex(where: { $0.id == id }) else { return }
            audioTracks[index].clips.append(clip)
            audioTracks[index].clips.sort { $0.timelineStart < $1.timelineStart }
        } else {
            guard let index = overlayTracks.firstIndex(where: { $0.id == id }) else { return }
            overlayTracks[index].clips.append(clip)
            overlayTracks[index].clips.sort { $0.timelineStart < $1.timelineStart }
        }
    }

    /// 这一段放得进这条轨吗。判据和 `TimelineState.fits` 一字不差（1ms 容差：
    /// 首尾相接的两段不算重叠，浮点误差也不算）。粘贴的落点也用它（`ClipPasteLanding`）。
    static func fits(start: Double, duration: Double, among busy: [TimelineSpan]) -> Bool {
        !busy.contains { $0.start < start + duration - 0.001 && start < $0.end - 0.001 }
    }
}
