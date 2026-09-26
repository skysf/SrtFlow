import Foundation

// MARK: - 粘贴的剪辑落到哪条轨（纯值）
//
// 管什么：一批剪辑粘贴时各落到哪条轨 —— 按「原来那条轨」分组，每组整组落在同一条轨上；撞上了就往上抬
// （画面）/ 换一条放得下的（声音），都放不下新开一条。然后真的放进去。
// 不管什么：时间（落点已经平移好了，`TimelinePaste`）、文字 / 滤镜 / 字幕 / 形状（各有各的行规矩）。
//
// 2026-09-26 用户拍板（docs/plans/2026-09-26-timeline-clipboard-and-zoom.md，第 1 题选 A）：
// 「和从 Finder 拖文件进来一样」—— 梯子、隐藏的轨不上梯子、画面往上抬、声音从头找，都是
// `mediaImportLandings` 那一套（VideoEditMediaImport.swift）。多出来的只有「一批里有好几组」：
// - 画面组从下往上落，**上面的组永远落在下面的组之上**（保住原来的叠放关系），需要新开的每组各开一条；
// - 声音组各自找一条放得下的、互不共用（没有叠放语义，但原来分在两条轨上的，粘出来也分开）。

/// 一段粘贴的剪辑落到哪。
enum ClipPasteTarget: Equatable {
    /// 现有的一条轨。
    case existing(TrackSlot)
    /// 这一次新开的第几条上层视频轨（从下往上排，全部在现有的上层轨之上）。
    case newOverlay(Int)
    /// 这一次新开的第几条音频轨（从上往下排，全部在现有的音频轨之下）。
    case newAudio(Int)
}

enum ClipPasteLanding {
    /// 落点算法要知道的一段：它原来在哪条轨、平移之后占哪一段时间。
    struct Item: Equatable {
        var lane: TimelineClipboardPayload.Lane
        var span: TimelineSpan
    }

    /// 每一段（和 `items` 一一对应）落到哪。
    ///
    /// - `pointing`：鼠标指着的那条轨。**这一类只有一组时**才用它（几组一起粘时各回各的轨，只拿落点定时间）；
    ///   指着的轨放不了这一类（视频指着音频轨）也不用。
    /// - 没指着就回原来那条轨（按轨道身份找；藏起来了、找不到 —— 跨工程 —— 画面从主轨起、声音从头找）。
    static func targets(for items: [Item], in state: TimelineState, pointing: TrackSlot?) -> [ClipPasteTarget] {
        var result = [ClipPasteTarget](repeating: .existing(.main), count: items.count)
        for audio in [false, true] {
            let groups = Dictionary(grouping: items.indices.filter { items[$0].lane.isAudio == audio }) { items[$0].lane }
                .sorted { $0.key.order < $1.key.order }
            guard !groups.isEmpty else { continue }
            let rungs = Array((audio ? state.audioImportLadder() : state.videoImportLadder()).dropLast())
            var busy = rungs.map { state.occupiedSpans(on: $0) }
            let pointed = groups.count == 1 ? pointing.flatMap { rungs.firstIndex(of: TrackDropTarget($0)) } : nil
            var floor = 0
            var used = Set<Int>()
            var fresh = 0
            for (lane, members) in groups {
                let spans = members.map { items[$0].span }
                let preferred = pointed ?? sourceRung(of: lane, among: rungs, in: state)
                let order: [Int]
                if audio {
                    order = (preferred.map { [$0] } ?? []) + rungs.indices.filter { $0 != preferred && !used.contains($0) }
                } else {
                    let start = max(preferred ?? 0, floor)
                    order = start < rungs.count ? Array(start..<rungs.count) : []
                }
                if let rung = order.first(where: { fits(spans, among: busy[$0]) }) {
                    busy[rung] += spans
                    used.insert(rung)
                    floor = rung + 1
                    for member in members { result[member] = .existing(slot(of: rungs[rung])) }
                } else {
                    for member in members { result[member] = audio ? .newAudio(fresh) : .newOverlay(fresh) }
                    fresh += 1
                    // 画面：这一组已经在最上面新开的那条了，后面（更靠上）的组只能接着往上新开。
                    floor = rungs.count
                }
            }
        }
        return result
    }

    /// 原来那条轨在梯子上的位置；那条轨藏起来了、这个工程里没有（跨工程）就是 nil。
    private static func sourceRung(
        of lane: TimelineClipboardPayload.Lane, among rungs: [TrackDropTarget], in state: TimelineState
    ) -> Int? {
        switch lane {
        case .main:
            return rungs.firstIndex(of: .main)
        case .overlay(let id, _):
            return state.overlayTracks.firstIndex { $0.id == id }.flatMap { rungs.firstIndex(of: .overlay($0)) }
        case .audio(let id, _):
            return state.audioTracks.firstIndex { $0.id == id }.flatMap { rungs.firstIndex(of: .audio($0)) }
        }
    }

    /// 这一组整组放得进这条轨吗（判据同拖文件：1ms 容差，首尾相接不算重叠）。
    private static func fits(_ spans: [TimelineSpan], among busy: [TimelineSpan]) -> Bool {
        spans.allSatisfy { TimelineState.fits(start: $0.start, duration: $0.duration, among: busy) }
    }

    private static func slot(of rung: TrackDropTarget) -> TrackSlot {
        switch rung {
        case .overlay(let index): return .overlay(index)
        case .audio(let index): return .audio(index)
        default: return .main
        }
    }
}

extension TimelineState {
    /// 把粘贴的剪辑按 `ClipPasteLanding.targets` 放进时间线（`clips` 和 `targets` 一一对应）。
    ///
    /// 新开的轨先按编号开好（上层轨接在最上面、音频轨接在最下面），再往里放；主轨是裸 append，收尾排一次
    /// （「数组顺序 = 时间顺序」是硬不变量，docs/architecture/timeline-drag-gestures.md）。
    /// 落到主轨以外的段去掉转场：转场只有主轨有语义（跨轨拖动同一条规矩）。
    mutating func insertPasted(_ clips: [EditClip], at targets: [ClipPasteTarget]) {
        let overlayIDs = overlayTracks.map(\.id)
        let audioIDs = audioTracks.map(\.id)
        var freshOverlay: [Int: UUID] = [:]
        var freshAudio: [Int: UUID] = [:]
        for target in targets {
            if case .newOverlay(let k) = target, freshOverlay[k] == nil {
                freshOverlay[k] = insertLane(audio: false, at: overlayTracks.count, clips: [])
            }
            if case .newAudio(let k) = target, freshAudio[k] == nil {
                freshAudio[k] = insertLane(audio: true, at: audioTracks.count, clips: [])
            }
        }
        var touchedMain = false
        for (clip, target) in zip(clips, targets) {
            var placed = clip
            if target != .existing(.main) { placed.transitionAfter = .none }
            switch target {
            case .existing(.main):
                mainClips.append(placed)
                touchedMain = true
            case .existing(.overlay(let index)) where overlayIDs.indices.contains(index):
                appendImported(placed, toLane: overlayIDs[index], audio: false)
            case .existing(.audio(let index)) where audioIDs.indices.contains(index):
                appendImported(placed, toLane: audioIDs[index], audio: true)
            case .newOverlay(let k):
                if let id = freshOverlay[k] { appendImported(placed, toLane: id, audio: false) }
            case .newAudio(let k):
                if let id = freshAudio[k] { appendImported(placed, toLane: id, audio: true) }
            case .existing:
                // 指到的轨号已经不在了（不会发生：落点和放进去是同一份状态），当成新开一条。
                _ = place(placed, intoAudio: placed.isAudioOnly)
            }
        }
        if touchedMain { sortMainClipsByStart() }
    }
}
