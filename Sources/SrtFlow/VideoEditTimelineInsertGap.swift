import SwiftUI

// MARK: - 插入缝的视图侧：停顿计时、拉开动画、缝里那条线
//
// 纯值的几何（缝在哪、指针在不在缝上、拉开之后每一行挪到哪）在
// `VideoEditTimelineSeams.swift`，自检够得着；这里只有接线。
// 长期约束见 docs/architecture/timeline-drag-gestures.md §5h。
//
// **缝开没开是视图状态**（`VideoEditTimelineView.openSeam`），拖动过程中一个字都不写
// `TimelineState`（§0）：模型只在松手那一下改一次。

/// 在缝上停够时间才拉开（0.2 秒，用户拍板）。
///
/// 三种拖动（素材块、Finder 文件、音频库素材）共用这一个：指针停着不动时，拖动手势和拖放
/// 回调都不会再来一拍，停够了只能靠它自己回调。
@MainActor
final class TimelineSeamDwell {
    /// 拉开 / 合上缝的动画。被拖的块自己不在这个动画里 —— 它横着跟手（§2 第 1 条），
    /// 缝只在停够时间、或者指针离开时才动一次，两件事不在同一拍里。
    static let animation = Animation.easeOut(duration: 0.16)

    private var waiting: TimelineSeam?
    private var timer: Task<Void, Never>?
    /// 指针最后停在哪（滚动内容坐标）。拖放那两套停够之后按它重画落点框：停着的时候
    /// `dropUpdated` 不一定再来一拍（同 `MediaFileDrag.lastLocation` 那条）。
    var lastLocation: CGPoint?

    deinit {
        // deinit 可能不在主线程：只取消已经排上的计时，不碰别的状态（同 TimelineAutoScroller）。
        timer?.cancel()
    }

    /// 每一拍都喂：指针此刻压在哪条（关着的）缝上，nil = 不在任何缝上。
    ///
    /// 同一条缝重复喂**不**重新计时（指针在缝里横着挪不该一直拉不开）；换了缝或者离开，
    /// 前一次计时作废。停够了回调 `open`，由调用方拉开缝、改落点。
    func hover(_ seam: TimelineSeam?, open: @escaping @MainActor (TimelineSeam) -> Void) {
        guard seam != waiting else { return }
        cancel()
        guard let seam else { return }
        waiting = seam
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(TimelineSeams.dwellMilliseconds))
            guard let self, !Task.isCancelled, self.waiting == seam else { return }
            self.waiting = nil
            self.timer = nil
            open(seam)
        }
    }

    /// 这一轮拖动结束（松手、拖出去、视图消失）：计时作废。
    func cancel() {
        timer?.cancel()
        timer = nil
        waiting = nil
    }
}

// MARK: - 行的排布：缝开着 / 关着

extension VideoEditTimelineView {

    /// 此刻拉开的缝垫在哪。
    struct GapPlacement: Equatable {
        /// 缝下面那一行（轨道行和轨道头列都给它上面垫 `TimelineSeams.gapExtra`）。
        /// nil = 没有缝，或者缝在最后一行下面。
        var rowID: String?
        /// 缝在最后一行下面：没有行可垫，内容整体在底下多留一段。
        var atEnd = false
        /// 缝的上沿（内容坐标）：插入线和缩略框按它画。
        var top: Double?
    }

    var gapPlacement: GapPlacement {
        guard let seam = openSeam else { return GapPlacement() }
        let specs = rows
        let seamRows = specs.map(\.seamRow)
        guard let below = TimelineSeams.gapBefore(seam, in: seamRows) else { return GapPlacement() }
        return GapPlacement(
            rowID: below < specs.count ? specs[below].id : nil,
            atEnd: below >= specs.count,
            top: TimelineSeams.openGap(seam, rows: seamRows)?.top
        )
    }

    /// 按某条缝开着（`open` = nil 就是全关着）时的排布。
    ///
    /// 位置**只**从 `TimelineSeams.layout` 来：VStack 实际怎么排（第一行上方 inset、
    /// 行距 spacing、缝下面那一行多垫 gapExtra）和它一一对应，画框、命中判定、轨道头列
    /// 三处因此永远对得上。
    func rowLayouts(open: TimelineSeam?) -> [RowLayout] {
        Self.layouts(of: rows, open: open)
    }

    /// 同上，给拿着一份 `rows` 的拖放代理用（文件、音频库）：它们要在「缝开着」和
    /// 「缝关着」两种排布之间现算，不能只拿渲染那一刻的那一份。
    static func layouts(of rows: [RowSpec], open: TimelineSeam?) -> [RowLayout] {
        let seamRows = rows.map(\.seamRow)
        let gapBefore = open.flatMap { TimelineSeams.gapBefore($0, in: seamRows) }
        let spans = TimelineSeams.layout(seamRows, gapBefore: gapBefore)
        return zip(rows, spans).map { spec, span in
            RowLayout(spec: spec, minY: span.minY, midY: span.midY, maxY: span.maxY)
        }
    }
}

/// 拉开的缝里那条插入线：横贯内容区，骑在缝的正中（缩略落点框也骑在这条线上）。不拦事件。
///
/// 只在缝拉开时才存在：平时不在视图树里，不给时钟每跳一下的重算添账
/// （docs/architecture/preview-perf-ratchet.md）。
struct TimelineInsertLine: View {
    /// 拉开的缝的上沿（`TimelineSeams.openGap`）。
    let gapTop: Double
    let width: Double

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Color.teal)
            .frame(width: width, height: 3)
            .offset(y: gapTop + TimelineSeams.gapHeight / 2 - 1.5)
            .allowsHitTesting(false)
    }
}
