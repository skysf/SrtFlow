import AppKit
import SwiftUI

/// 主轨接缝上的转场遮罩：跨在缝上的一小块，左右两条边可以拖着改转场时长。
///
/// 位置和宽度由 `TimelineState.transitionWindow` 算 —— **和渲染同一个口径**：
/// 已相叠（磁吸排的）时窗口就是重叠区，首尾相接时跨在缝上两边各一半。
///
/// 只长在主轨：转场只有主轨有语义。
struct TransitionMaskView: View {
    @ObservedObject var project: VideoEditProject
    /// 第几条缝（= 出场段在 `mainClips` 里的下标）。存下标不存片段：拖动过程中
    /// 磁吸会重排，拿着一份旧的拷贝会画在上一拍的位置上。
    let seamIndex: Int
    let rowHeight: Double
    let pps: Double

    /// 拖动开始时的时长。**必须在开始时定死**：改时长会让磁吸重排片段、窗口
    /// 跟着挪，每一拍都拿实时窗口去算增量的话就是自己追自己（手越拖越飘）——
    /// 和 `ClipBlockView` 的 `dragOrigin` 同一条纪律。
    @State private var dragStartDuration: Double?

    private var outgoing: EditClip? {
        project.state.mainClips.indices.contains(seamIndex) ? project.state.mainClips[seamIndex] : nil
    }

    private var incoming: EditClip? {
        let next = seamIndex + 1
        return project.state.mainClips.indices.contains(next) ? project.state.mainClips[next] : nil
    }

    private var window: (start: Double, duration: Double)? {
        project.state.transitionWindow(afterMainIndex: seamIndex)
    }

    /// 这条缝这一种转场最多能多长。拖到头就停住 —— 拖得出一个渲染管线做不出来
    /// 的值，就又回到了「设了但成片里没有」。
    private var maxDuration: Double {
        guard let outgoing, let incoming else { return 0 }
        if case .available(let maxDuration) = TimelineState.transitionCapacity(
            outgoing: outgoing, incoming: incoming, kind: outgoing.transitionAfter
        ) { return maxDuration }
        return 0
    }

    /// 首尾相接时窗口以缝为心、两边一起动，拖一条边 Δ 就是改 2Δ；已相叠时右边
    /// 界钉在出场段的结尾上（那由磁吸排位说了算），只有一边在动，就是 1Δ。
    private var edgeFactor: Double {
        guard let outgoing, let incoming else { return 2 }
        return TimelineState.needsHandles(outgoing: outgoing, incoming: incoming) ? 2 : 1
    }

    var body: some View {
        if let window, let outgoing {
            // 下限 18：再窄两条把手就贴到一起，哪条都抓不准。窄到贴底之后画出来
            // 的宽度不再代表真实时长 —— 想精调就放大时间线。
            // 位置由 `transitionMaskRect` 按**窗口中心**算，不是钉左边界：下限
            // 多出来的宽度必须两边均摊，否则拖短转场时遮罩会整个往右挪。
            let rect = TimelineState.transitionMaskRect(window: window, pps: pps, minWidth: 18)
            let width = rect.width
            let height = max(14, rowHeight - 10)
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.black.opacity(0.35))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(.white.opacity(0.75), lineWidth: 1)
                    )
                if width > 22 {
                    Image(systemName: "square.filled.and.line.vertical.and.square")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: width, height: height)
            .overlay(alignment: .leading) { edge(trailing: false) }
            .overlay(alignment: .trailing) { edge(trailing: true) }
            .contentShape(Rectangle())
            .onTapGesture {
                // 选中出场段：检查器的转场那一区就是挂在它身上的。
                project.select(outgoing.id, additive: false)
            }
            .contextMenu {
                Button("Remove Transition") {
                    project.setTransition(after: outgoing.id, .none)
                }
            }
            .instantHelp(verbatim: transitionHelp(outgoing, window.duration))
            .offset(x: rect.x, y: (rowHeight - height) / 2)
            // 压在片段块之上，但让被拖动的块（zIndex 10）盖过它。
            .zIndex(6)
        }
    }

    private func edge(trailing: Bool) -> some View {
        Rectangle()
            .fill(.white.opacity(0.9))
            .frame(width: 3)
            .padding(.vertical, 3)
            // 3pt 的线太细抓不住，把命中面往外放宽。
            .contentShape(Rectangle().inset(by: -5))
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        guard let outgoing else { return }
                        if dragStartDuration == nil {
                            dragStartDuration = outgoing.transitionDuration
                        }
                        guard let start = dragStartDuration else { return }
                        let delta = value.translation.width / pps * edgeFactor
                        apply(duration: start + (trailing ? delta : -delta))
                    }
                    .onEnded { _ in
                        dragStartDuration = nil
                        project.endLiveEdit()
                    }
            )
    }

    private func apply(duration: Double) {
        guard let outgoing else { return }
        let clamped = min(max(duration, 0.1), max(0.1, maxDuration))
        project.liveApply { state in
            state.update(outgoing.id) { $0.transitionDuration = clamped }
        }
    }

    private func transitionHelp(_ clip: EditClip, _ duration: Double) -> String {
        String(
            format: L10n("%@ · %.1fs — drag either edge to change the length"),
            L10n(clip.transitionAfter.title), duration
        )
    }
}
