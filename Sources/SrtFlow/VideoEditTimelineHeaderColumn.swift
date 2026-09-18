import AppKit
import SwiftUI

// MARK: - 左侧轨道头列
//
// 轨道色条 + 类型图标 + 整轨隐藏的眼睛，行高和右边的轨道行严格一致。
// 在视频轨/音频轨的图标上**上下拖**可以调那一类轨道的行高。
//
// 它在滚动区**外面**（横向滚动不该把轨道头滚走），所以时间线纵向滚动时得自己
// 跟上：`.offset(y: -geometry.offset.y)`。这是**唯一**一处订阅
// `TimelineScrollGeometry` 的地方之一（另一处是钉住的标尺）——
// 单拎成一个视图就是为了让滚动的每一帧只重画这一列，而不是整棵时间线视图树
// （docs/architecture/timeline-drag-gestures.md §5b）。

struct TimelineHeaderColumn: View {
    let rows: [VideoEditTimelineView.RowSpec]
    let rowSpacing: Double
    @ObservedObject var project: VideoEditProject
    /// 纵向滚动量的推送值：只有这一列和标尺订阅它。
    @ObservedObject var geometry: TimelineScrollGeometry
    @Binding var resizeBase: Double?

    var body: some View {
        // **这一列不许决定时间线的高度。** 它的固有高度是所有行加起来（十来条轨
        // 就 500pt 往上），直接摆在 HStack 里的话，整条时间线会按这个高度去要
        // 地方 —— VSplitView 给不了那么多，工具栏和标尺就被挤出窗口。
        // `Color.clear` 的固有尺寸是弹性的：面板给多少就是多少，真正的那一列
        // 画在它上面、超出的部分裁掉。
        Color.clear
            .frame(width: 54)
            .overlay(alignment: .top) { column }
            .clipped()
            // `.clipped()` 只裁绘制不裁命中：没有这一条，滚出视口的那些眼睛
            // 按钮照样点得中（同块内装饰那条老教训）。
            .contentShape(Rectangle())
    }

    private var column: some View {
        VStack(alignment: .center, spacing: rowSpacing) {
            ForEach(rows) { row in
                Group {
                    if row.isRuler {
                        Color.clear
                    } else {
                        HStack(spacing: 3) {
                            // 轨道色条：与这条轨上所有块同色。空轨在时间线上
                            // 一个块都没有，只有它能告诉用户那是哪条轨。
                            if let slot = row.slot {
                                Capsule()
                                    .fill(project.state.trackAccent(for: slot))
                                    .frame(width: 3, height: max(10, row.height - 10))
                                    .opacity(row.isHidden ? 0.3 : 1)
                            }
                            Image(systemName: row.icon)
                                .font(.caption)
                                .foregroundStyle(row.isHidden ? .tertiary : .secondary)
                            if let slot = row.slot {
                                Button {
                                    project.toggleLaneHidden(slot)
                                } label: {
                                    Image(systemName: row.isHidden ? "eye.slash" : "eye")
                                        .font(.system(size: 9))
                                        .foregroundStyle(row.isHidden ? .orange : .secondary)
                                }
                                .buttonStyle(.borderless)
                                .instantHelp("Hide or show this track", shortcut: .plain("V"))
                            } else if let kind = row.subtitleKind {
                                // 字幕轨的眼睛：语义与其他轨道一致（预览+烧录
                                // 都跳过），只是隐藏状态不挂在 slot 上。
                                Button {
                                    switch kind {
                                    case .original: project.toggleSubtitleHidden()
                                    case .translation: project.toggleTranslationHidden()
                                    }
                                } label: {
                                    Image(systemName: row.isHidden ? "eye.slash" : "eye")
                                        .font(.system(size: 9))
                                        .foregroundStyle(row.isHidden ? .orange : .secondary)
                                }
                                .buttonStyle(.borderless)
                                .instantHelp(kind == .original
                                      ? "Hide or show the original subtitle track"
                                      : "Hide or show the translated subtitle track")
                            }
                        }
                    }
                }
                .frame(width: 54, height: row.height)
                .contentShape(Rectangle())
                .modifier(RowHeightDragModifier(
                    kind: rowKind(row),
                    project: project,
                    base: $resizeBase
                ))
            }
        }
        .padding(.vertical, 2)
        // 轨道行是**同一份 `rows`** 排出来的，所以只要减掉同一个纵向滚动量，
        // 两边就永远对得上（不用各自去量位置）。
        .offset(y: -geometry.offset.y)
    }

    private func rowKind(_ row: VideoEditTimelineView.RowSpec) -> TrackRowKind {
        switch row.slot {
        case .main, .overlay: return .video
        case .audio: return .audio
        case nil: return .other
        }
    }
}
