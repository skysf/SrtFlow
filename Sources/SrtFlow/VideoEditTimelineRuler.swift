import AppKit
import SwiftUI
import SrtFlowCore

// MARK: - 标尺
//
// 从 `VideoEditTimelineView.swift` 拆出来（拆分前 2101 行，远超仓库约 800 行的
// 警戒线）。标尺自己只管画刻度和把点击换算成 seek，播放头的竖线画在滚动内容那一层
// （`VideoEditTimelinePlayhead.swift`），把手（`TimelinePlayheadHandle`）跟着标尺钉住。
// 行高拖调原本也在这个文件里，2026-09-22 改成「一轨一个高度」时搬去了
// `VideoEditTimelineRowHeights.swift`（纯值）+ `VideoEditTimelineRowHeightDrag.swift`（接线）。
// 接线守卫 `checks/timeline-drag-wiring.sh` 按文件扫描，挪动这里的东西要同步改它。

// MARK: - 钉在视口顶上的标尺

/// 纵向滚动时标尺**不跟着走**：轨道多的时候，看下面那几条轨还得能看见时间。
///
/// 做法是加回一个纵向滚动量（轨道头列是减，因为它在滚动区外面）。这里和轨道头列
/// 是**仅有的两处**订阅 `TimelineScrollGeometry` 的地方 —— 时间线主体只用 `@State`
/// 持有它、不订阅，否则滚动的每一帧都要重建整棵时间线视图树
/// （docs/architecture/timeline-drag-gestures.md §5c）。
struct TimelinePinnedRuler: View, Equatable {
    let pps: Double
    let duration: Double
    /// 工程帧率：放大到一秒放不下两个标签时，刻度按帧走（`mm:ss:ff`）。
    let frameRate: ProjectFrameRate
    /// 行距：标尺的不透明底要盖住它，不然滚上来的块会从缝里露出来。
    let rowSpacing: Double
    /// 播放头的把手画在这儿而不是跟着竖线走：标尺是不透明的，纵向滚下去之后画在滚动内容
    /// 顶部的把手会被它盖住。**持有不订阅**：跟着时钟跳的只有把手（`TimelinePlayheadHandle`），
    /// 标尺本身不随播放一跳一跳重算（preview-perf-ratchet.md 第十二节）。
    let clock: PlayerClock
    @ObservedObject var geometry: TimelineScrollGeometry
    let onSeek: (Double, Bool) -> Void

    /// 按值比较（调用方套 `.equatable()`）：输入里有 `onSeek` 这个闭包，比不出「没变」的话
    /// 拖动每动一下时间线一重算，标尺就跟着重算、重画一遍（2026-09-24 实测）。闭包不用比：
    /// 它捕获的是时间线视图，读的是最新状态。滚动量走 `geometry` 的订阅，不经这里。
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pps == rhs.pps && lhs.duration == rhs.duration && lhs.frameRate == rhs.frameRate
            && lhs.rowSpacing == rhs.rowSpacing && lhs.clock === rhs.clock
            && lhs.geometry === rhs.geometry
    }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        TimelineRuler(pps: pps, duration: duration, frameRate: frameRate, onSeek: onSeek)
            // 滚动一帧这一层就重算一次（它订阅滚动量），刻度本身没变就别跟着重画。
            .equatable()
            // 播放头的把手：和标尺一起钉住。不吃事件 —— 标尺的 scrub 手势在它
            // 底下，挡住了就点不动播放头了。
            .overlay(alignment: .topLeading) {
                TimelinePlayheadHandle(clock: clock, pps: pps)
            }
            // 自带不透明底：它盖在滚上去的轨道行上面，透明的话会看见块从刻度
            // 底下穿过去。上面 2pt 是内容的 padding，下面一格是行距。
            .background(alignment: .top) {
                Color(nsColor: .windowBackgroundColor)
                    .frame(height: 26 + 2 + rowSpacing)
                    .offset(y: -2)
            }
            .offset(y: geometry.offset.y)
            // 盖在轨道行之上（VStack 按 zIndex 决定绘制与命中顺序）。
            .zIndex(50)
    }
}

/// 标尺上播放头的把手。只有它订阅时钟：播放每一跳重画这一个小圆角块，标尺的刻度不动。
/// 不吃事件 —— 标尺的 scrub 手势在它底下，挡住了就点不动播放头了。
struct TimelinePlayheadHandle: View {
    @ObservedObject var clock: PlayerClock
    let pps: Double

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        let playheadX = clock.time * pps
        RoundedRectangle(cornerRadius: 2)
            .fill(.white)
            .frame(width: 9, height: 14)
            .shadow(radius: 1)
            .offset(x: playheadX - 4.5)
            .allowsHitTesting(false)
    }
}

// MARK: - 标尺

/// `|00:00 · · · · |00:10 · · · ·` 的刻度条，可点、可拖着走播放头。
///
/// 放大到 4800pt/秒之后标尺能有几百万点宽：Canvas 的闭包**只画
/// `context.clipBoundingRect` 那一段**（整宽画的话每滚 128pt 就把整条刻度重算一遍，
/// 见 docs/architecture/audio-waveform.md）。放大到一秒放不下两个标签时，刻度改按帧走、
/// 标签写成 `mm:ss:ff`。
struct TimelineRuler: View, Equatable {
    let pps: Double
    let duration: Double
    let frameRate: ProjectFrameRate
    let onSeek: (Double, Bool) -> Void

    /// 刻度只由这三个值决定；闭包比不了也不用比（同 `TimelinePinnedRuler`）。
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pps == rhs.pps && lhs.duration == rhs.duration && lhs.frameRate == rhs.frameRate
    }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        Canvas { context, size in
            PerfCounters.canvas(Self.self)
            let scale = RulerScale.pick(pps: pps, frameRate: frameRate)
            let visible = context.clipBoundingRect
            // 左边多退一格：标签画在刻度线右边，刚滚出去的那个刻度的标签还露着半截。
            let first = max(0, Int((visible.minX / (scale.major * pps)).rounded(.down)) - 1)
            let last = Int((min(Double(size.width), visible.maxX) / (scale.major * pps)).rounded(.up))
            guard last >= first else { return }
            for index in first...last {
                let t = Double(index) * scale.major
                let x = t * pps
                context.draw(
                    Text("|" + scale.label(t, frameRate: frameRate))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary),
                    at: CGPoint(x: x + 2, y: size.height / 2),
                    anchor: .leading
                )
                guard scale.minorCount > 1 else { continue }
                for minor in 1..<scale.minorCount {
                    let mx = x + Double(minor) * scale.major / Double(scale.minorCount) * pps
                    let dot = Path(ellipseIn: CGRect(x: mx - 1, y: size.height / 2 - 1, width: 2, height: 2))
                    context.fill(dot, with: .color(.secondary.opacity(0.5)))
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    onSeek(value.location.x / pps, false)
                }
                .onEnded { value in
                    onSeek(value.location.x / pps, true)
                }
        )
    }
}
