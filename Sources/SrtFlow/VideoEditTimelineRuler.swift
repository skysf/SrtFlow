import AppKit
import SwiftUI

// MARK: - 标尺与行高拖调
//
// 从 `VideoEditTimelineView.swift` 拆出来（拆分前 2101 行，远超仓库约 800 行的
// 警戒线）。标尺自己只管画刻度和把点击换算成 seek，播放头画在滚动内容那一层。
// 接线守卫 `checks/timeline-drag-wiring.sh` 按文件扫描，挪动这里的东西要同步改它。

// MARK: - 钉在视口顶上的标尺

/// 纵向滚动时标尺**不跟着走**：轨道多的时候，看下面那几条轨还得能看见时间。
///
/// 做法是加回一个纵向滚动量（轨道头列是减，因为它在滚动区外面）。这里和轨道头列
/// 是**仅有的两处**订阅 `TimelineScrollGeometry` 的地方 —— 时间线主体只用 `@State`
/// 持有它、不订阅，否则滚动的每一帧都要重建整棵时间线视图树
/// （docs/architecture/timeline-drag-gestures.md §5c）。
struct TimelinePinnedRuler: View {
    let pps: Double
    let duration: Double
    /// 行距：标尺的不透明底要盖住它，不然滚上来的块会从缝里露出来。
    let rowSpacing: Double
    /// 播放头此刻在内容坐标里的 x。把手画在这儿而不是跟着竖线走：标尺是不透明
    /// 的，纵向滚下去之后画在滚动内容顶部的把手会被它盖住。
    let playheadX: Double
    @ObservedObject var geometry: TimelineScrollGeometry
    let onSeek: (Double, Bool) -> Void

    var body: some View {
        TimelineRuler(pps: pps, duration: duration, onSeek: onSeek)
            // 播放头的把手：和标尺一起钉住。不吃事件 —— 标尺的 scrub 手势在它
            // 底下，挡住了就点不动播放头了。
            .overlay(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.white)
                    .frame(width: 9, height: 14)
                    .shadow(radius: 1)
                    .offset(x: playheadX - 4.5)
                    .allowsHitTesting(false)
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

// MARK: - 行高拖调

/// 轨道行的类别，行高各记各的。
enum TrackRowKind {
    /// 主轨和上层轨合成一类：行高共用一个值，拖哪条都一起动。
    case video, audio, other
}

/// 轨道头图标上的上下拖：调那一类轨道的行高。
struct RowHeightDragModifier: ViewModifier {
    let kind: TrackRowKind
    @ObservedObject var project: VideoEditProject
    @Binding var base: Double?

    func body(content: Content) -> some View {
        if kind == .other {
            content
        } else {
            content
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            if base == nil { base = current }
                            apply((base ?? current) + value.translation.height)
                        }
                        .onEnded { _ in base = nil }
                )
                .onHover { inside in
                    if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                }
                .instantHelp("Drag up or down to resize this kind of track")
        }
    }

    private var current: Double {
        switch kind {
        case .video: return project.videoRowHeight
        case .audio: return project.audioRowHeight
        case .other: return 0
        }
    }

    private func apply(_ height: Double) {
        switch kind {
        case .video: project.videoRowHeight = min(max(height, 28), 120)
        case .audio: project.audioRowHeight = min(max(height, 20), 100)
        case .other: break
        }
    }
}

// MARK: - 标尺

/// `|00:00 · · · · |00:10 · · · ·` 的刻度条，可点、可拖着走播放头。
struct TimelineRuler: View {
    let pps: Double
    let duration: Double
    let onSeek: (Double, Bool) -> Void

    var body: some View {
        Canvas { context, size in
            let major = majorStep
            let minor = major / 5
            var t: Double = 0
            while t * pps < size.width {
                let x = t * pps
                let isMajor = t.truncatingRemainder(dividingBy: major) < 0.0001
                    || major - t.truncatingRemainder(dividingBy: major) < 0.0001
                if isMajor {
                    context.draw(
                        Text("|" + label(t))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary),
                        at: CGPoint(x: x + 2, y: size.height / 2),
                        anchor: .leading
                    )
                } else {
                    let dot = Path(ellipseIn: CGRect(x: x - 1, y: size.height / 2 - 1, width: 2, height: 2))
                    context.fill(dot, with: .color(.secondary.opacity(0.5)))
                }
                t += minor
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

    /// 主刻度间隔按缩放挑，保证相邻标签不打架。
    private var majorStep: Double {
        let candidates: [Double] = [1, 2, 5, 10, 30, 60, 120, 300, 600]
        for candidate in candidates where candidate * pps >= 76 {
            return candidate
        }
        return 600
    }

    private func label(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
