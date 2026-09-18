import AppKit
import SwiftUI

// MARK: - 标尺与行高拖调
//
// 从 `VideoEditTimelineView.swift` 拆出来（拆分前 2101 行，远超仓库约 800 行的
// 警戒线）。标尺自己只管画刻度和把点击换算成 seek，播放头画在滚动内容那一层。
// 接线守卫 `checks/timeline-drag-wiring.sh` 按文件扫描，挪动这里的东西要同步改它。

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
