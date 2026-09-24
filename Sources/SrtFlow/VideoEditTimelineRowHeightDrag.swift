import SwiftUI

// MARK: - 轨道头下边缘上下拖 = 调这一条轨的行高
//
// 2026-09-24 起只挂在轨道头的**下边缘**那一条上（学 Logic）：轨道头本体的上下拖改成了
// 整条轨换位置（`VideoEditTimelineLaneReorder.swift`）。
//
// 从 `VideoEditTimelineRuler.swift` 拆出来（标尺只管刻度和 seek，行高是另一件
// 事）。判据和存储是纯值，在 `VideoEditTimelineRowHeights.swift`；这里只有接线。
//
// 接线守卫 `checks/timeline-drag-wiring.sh` 按文件扫描，挪动这里的东西要同步改它。

/// 一轮行高拖动的起手值。
///
/// **必须带着「是哪条轨」**：`onEnded` 不保证会来（模态框挡在前面、视图消失时
/// 指针「离开」根本不发事件，同 docs/bugfixes/2026-08-23-tooltip-survives-open-panel.md
/// 那条教训）。残留的起手值若不认轨，下一次拖**另一条**轨就会从上一条轨的高度
/// 起算，块当场跳一下。
struct RowHeightDragState: Equatable {
    var key: TimelineRowHeightKey
    var base: Double
}

/// 轨道头下边缘上的上下拖：调**这一条**轨的行高（2026-09-22 起不再按类一起动）。
struct RowHeightDragModifier: ViewModifier {
    let kind: TrackRowKind
    /// 这一行对应哪条轨。nil = 这一行没有可调的高度（标尺 / 滤镜 / 文字 /
    /// 形状 / 字幕行），整条手势都不挂。
    let key: TimelineRowHeightKey?
    @ObservedObject var project: VideoEditProject
    @Binding var session: RowHeightDragState?

    func body(content: Content) -> some View {
        let _ = PerfCounters.body(Self.self)
        if let key, kind.heightRange != nil {
            content
                .gesture(
                    // 量在轨道头列那个不动的坐标系上：下边缘这一条跟着行高一起往下长，
                    // 以它自己为参照的 translation 会被自己的位移抵掉一半（§1 裁切把手
                    // 那个反馈回路：振荡 + 半速）。
                    DragGesture(minimumDistance: 2, coordinateSpace: .named(TimelineHeaderColumn.space))
                        .onChanged { value in
                            let base = base(for: key)
                            session = RowHeightDragState(key: key, base: base)
                            // 绝对增量：每一拍都从起手值重放，反复调用不叠加。
                            project.setRowHeight(
                                base + value.translation.height,
                                for: key,
                                kind: kind
                            )
                        }
                        .onEnded { _ in session = nil }
                )
                .pointerStyle(.rowResize)
                .instantHelp("Drag up or down to resize this track")
        } else {
            content
        }
    }

    /// 这一轮的起手高度：同一条轨接着用上一拍的，换了轨（或刚起手）现取一次。
    private func base(for key: TimelineRowHeightKey) -> Double {
        if let session, session.key == key { return session.base }
        return project.rowHeight(for: key, kind: kind)
    }
}
