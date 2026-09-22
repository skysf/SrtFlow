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

        var result: [MediaImportLanding] = []
        var cursor = max(0, firstStart)
        for item in items {
            // 0 长度的段在时间线上是个点：选不中、拖不动、删不掉。给个下限。
            let duration = max(Self.minimumImportedDuration, item.duration)
            guard let ladder = ladders[item.isAudio], !ladder.isEmpty else { continue }
            let pointed = preferred.flatMap { wanted in ladder.firstIndex { $0 == wanted } }

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
        // 这一次导入新开的那条轨。第二段也要落进**同一条**，不能一段开一条 ——
        // 落点算法把它们算在同一级梯子上（`newOverlayTop` / `newAudioBottom`
        // 在 `busy` 里是同一个下标），这里必须对得上。
        var freshOverlay: Int?
        var freshAudio: Int?
        var touchedMain = false

        for (clip, landing) in zip(clips, landings) {
            var placed = clip
            placed.timelineStart = landing.start
            switch landing.target {
            case .main:
                mainClips.append(placed)
                touchedMain = true
            case .overlay(let index):
                if overlayTracks.indices.contains(index) {
                    overlayTracks[index].clips.append(placed)
                    overlayTracks[index].clips.sort { $0.timelineStart < $1.timelineStart }
                } else {
                    overlayTracks.append(EditLane(clips: [placed]))
                    freshOverlay = overlayTracks.count - 1
                }
            case .newOverlayTop:
                if let index = freshOverlay {
                    overlayTracks[index].clips.append(placed)
                    overlayTracks[index].clips.sort { $0.timelineStart < $1.timelineStart }
                } else {
                    // 数组末尾 = 层级最高 = 显示在最上面一行（同 relocateClip）。
                    overlayTracks.append(EditLane(clips: [placed]))
                    freshOverlay = overlayTracks.count - 1
                }
            case .audio(let index):
                if audioTracks.indices.contains(index) {
                    audioTracks[index].clips.append(placed)
                    audioTracks[index].clips.sort { $0.timelineStart < $1.timelineStart }
                } else {
                    audioTracks.append(EditLane(clips: [placed]))
                    freshAudio = audioTracks.count - 1
                }
            case .newAudioBottom:
                if let index = freshAudio {
                    audioTracks[index].clips.append(placed)
                    audioTracks[index].clips.sort { $0.timelineStart < $1.timelineStart }
                } else {
                    audioTracks.append(EditLane(clips: [placed]))
                    freshAudio = audioTracks.count - 1
                }
            }
        }

        // 主轨「数组顺序 = 时间顺序」是硬不变量
        //（docs/architecture/timeline-drag-gestures.md）：上面是裸 append，往中间
        // 插的段会把顺序打乱 —— A/B 合成轨的插入游标只会前进，乱序当场黑屏
        //（docs/bugfixes/2026-08-08-main-track-array-order-black-frame.md）。
        if touchedMain { sortMainClipsByStart() }
    }

    /// 导入素材的最短时长。探测失败不会走到这里（那条路直接报错），这是给
    /// 0 长度的畸形文件兜底的。
    static let minimumImportedDuration = 0.1

    /// 某一级梯子上已经占着的区间。
    private func occupiedSpans(on target: TrackDropTarget) -> [TimelineSpan] {
        let clips: [EditClip]
        switch target {
        case .main:
            clips = mainClips
        case .overlay(let index):
            clips = overlayTracks.indices.contains(index) ? overlayTracks[index].clips : []
        case .audio(let index):
            clips = audioTracks.indices.contains(index) ? audioTracks[index].clips : []
        case .newOverlayTop, .newAudioBottom:
            clips = []
        }
        return clips.map { TimelineSpan(start: $0.timelineStart, end: $0.timelineEnd) }
    }

    /// 这一段放得进这条轨吗。判据和 `TimelineState.fits` 一字不差（1ms 容差：
    /// 首尾相接的两段不算重叠，浮点误差也不算）。
    private static func fits(start: Double, duration: Double, among busy: [TimelineSpan]) -> Bool {
        !busy.contains { $0.start < start + duration - 0.001 && start < $0.end - 0.001 }
    }
}
