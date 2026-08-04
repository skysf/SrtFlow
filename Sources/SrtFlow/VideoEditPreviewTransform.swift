import AppKit
import SwiftUI

// MARK: - 预览区的点选 + 自由变换

/// 铺在预览画面上的交互层：点击画面上的任何轨道内容（主轨、画中画、图片）
/// 就选中它并出现变换框 —— 四角等比缩放、四边自由拉伸、框内拖动移动。
///
/// 形状不归这里管（`ShapeOverlayCanvas` 叠在更上层，自己处理点选和把手）。
/// 拖动过程只动框和 `state`（liveApply），松手才重建 AV 合成 —— 画面本身
/// 要等一拍才跟上，但框是即时的。
struct ClipTransformCanvas: View {
    @ObservedObject var project: VideoEditProject
    /// 必须直接订阅时钟：播放头动了，画面上是谁在显示会跟着变。
    @ObservedObject var clock: PlayerClock
    let boxSize: CGSize

    private static let space = "clipTransformCanvas"

    /// 此刻画面上可见的段，最上层的排最前（画中画行号大的在上，主轨垫底）。
    private struct VisibleClip {
        var clip: EditClip
        var isOverlay: Bool
    }

    private var visibleClips: [VisibleClip] {
        let time = clock.time
        var result: [VisibleClip] = []
        for lane in project.state.overlayTracks.reversed() where !lane.isHidden {
            for clip in lane.clips where isOnScreen(clip, at: time) {
                result.append(VisibleClip(clip: clip, isOverlay: true))
            }
        }
        if !project.state.mainHidden,
           let main = project.state.mainClips.first(where: { isOnScreen($0, at: time) }) {
            result.append(VisibleClip(clip: main, isOverlay: false))
        }
        return result
    }

    /// 画面可见的判断比 `contains(time:)` 宽：正好停在段首（比如 0:00）也算。
    private func isOnScreen(_ clip: EditClip, at time: Double) -> Bool {
        !clip.isAudioOnly && !clip.needsStillConversion
            && time + 0.001 >= clip.timelineStart && time < clip.timelineEnd - 0.0005
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .named(Self.space)) { location in
                    selectClip(at: location)
                }

            if let selection = selectedVisibleClip() {
                let rect = selection.clip
                    .resolvedPlacement(canvas: boxSize, isOverlay: selection.isOverlay)
                    .frame(in: boxSize)
                ResizableFrameBox(
                    rect: rect,
                    handles: FrameHandle.all,
                    keepAspectOnCorners: true,
                    movable: true,
                    onTap: { location in selectClip(at: location) },
                    onChange: { newRect in
                        project.livePlace(
                            selection.clip.id,
                            placement: ClipPlacement(frame: newRect, in: boxSize)
                        )
                    },
                    onEnd: { project.endLiveEdit() }
                )
            }
        }
        .frame(width: boxSize.width, height: boxSize.height)
        .coordinateSpace(name: Self.space)
    }

    /// 选中的那一段现在就在画面上吗（在才画框）。
    private func selectedVisibleClip() -> VisibleClip? {
        guard let selected = project.selectedClip else { return nil }
        return visibleClips.first { $0.clip.id == selected.id }
    }

    private func selectClip(at location: CGPoint) {
        let hit = visibleClips.first { visible in
            visible.clip
                .resolvedPlacement(canvas: boxSize, isOverlay: visible.isOverlay)
                .frame(in: boxSize)
                .contains(location)
        }
        if let hit {
            project.select(hit.clip.id, additive: false)
        } else {
            project.selectedClipIDs = []
        }
    }
}

// MARK: - 变换框

/// 框上的八个把手。
enum FrameHandle: CaseIterable {
    case topLeading, top, topTrailing
    case leading, trailing
    case bottomLeading, bottom, bottomTrailing

    static let all = Set(allCases)
    /// 只留左右（线条改长度用）。
    static let horizontal: Set<FrameHandle> = [.leading, .trailing]
    /// 只留四角（正方形用，等比不破形）。
    static let corners: Set<FrameHandle> = [.topLeading, .topTrailing, .bottomLeading, .bottomTrailing]

    var isCorner: Bool {
        switch self {
        case .topLeading, .topTrailing, .bottomLeading, .bottomTrailing: return true
        default: return false
        }
    }

    /// 在框上的位置（0/0.5/1）。
    var unit: CGPoint {
        switch self {
        case .topLeading: return CGPoint(x: 0, y: 0)
        case .top: return CGPoint(x: 0.5, y: 0)
        case .topTrailing: return CGPoint(x: 1, y: 0)
        case .leading: return CGPoint(x: 0, y: 0.5)
        case .trailing: return CGPoint(x: 1, y: 0.5)
        case .bottomLeading: return CGPoint(x: 0, y: 1)
        case .bottom: return CGPoint(x: 0.5, y: 1)
        case .bottomTrailing: return CGPoint(x: 1, y: 1)
        }
    }

    var cursor: NSCursor {
        switch self {
        case .leading, .trailing: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        default: return .crosshair
        }
    }
}

/// 通用的变换框：描边 + 把手 + （可选）框内拖动。
///
/// 所有手势都必须用 `.global` 坐标系：把手挂在框边上，手势一生效框就会动，
/// `.local` 坐标会形成「位移抵消一半 + 振荡」的反馈回路
/// （见 docs/architecture/timeline-drag-gestures.md）。每个 tick 都从手势开始时
/// 抓的 `startRect` 重放绝对增量，幂等。
struct ResizableFrameBox: View {
    let rect: CGRect
    var handles: Set<FrameHandle> = FrameHandle.all
    /// 四角是否保持宽高比（边把手永远自由拉伸）。
    var keepAspectOnCorners = true
    /// 框内能不能拖动移动。
    var movable = true
    /// 框内单击（没构成拖动）转给外层重新点选用；nil 就不拦。
    var onTap: ((CGPoint) -> Void)?
    /// 拖动中的回调，给的是**绝对**的新框。
    let onChange: (CGRect) -> Void
    let onEnd: () -> Void

    /// 手势开始时的框，增量都相对它算（反复应用不叠加）。
    @State private var startRect: CGRect?

    private let handleSize: Double = 9
    private let minSide: Double = 14

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 描边；能移动的框整个内部都接拖动，不能移动的（形状）只当视觉框，
            // 事件全部放行给下面形状自己的手势。
            let stroke = Rectangle()
                .strokeBorder(.white, lineWidth: 1.5)
                .shadow(color: .teal.opacity(0.8), radius: 2)
                .frame(width: max(rect.width, 2), height: max(rect.height, 2))
            if movable {
                stroke
                    .contentShape(Rectangle())
                    .modifier(TapLocationModifier(space: "clipTransformCanvas", onTap: onTap))
                    .gesture(moveGesture)
                    .offset(x: rect.minX, y: rect.minY)
            } else {
                stroke
                    .allowsHitTesting(false)
                    .offset(x: rect.minX, y: rect.minY)
            }

            ForEach(Array(handles), id: \.self) { handle in
                handleView(handle)
            }
        }
        .animation(nil, value: rect)
    }

    // MARK: 移动

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                if startRect == nil { startRect = rect }
                guard let start = startRect else { return }
                onChange(start.offsetBy(dx: value.translation.width, dy: value.translation.height))
            }
            .onEnded { _ in
                startRect = nil
                onEnd()
            }
    }

    // MARK: 把手

    private func handleView(_ handle: FrameHandle) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(.white)
            .frame(width: handleSize, height: handleSize)
            .shadow(color: .black.opacity(0.6), radius: 1)
            .contentShape(Rectangle().inset(by: -5))
            .onHover { inside in
                if inside { handle.cursor.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if startRect == nil { startRect = rect }
                        guard let start = startRect else { return }
                        onChange(resized(start, handle: handle, translation: value.translation))
                    }
                    .onEnded { _ in
                        startRect = nil
                        onEnd()
                    }
            )
            .offset(
                x: rect.minX + rect.width * handle.unit.x - handleSize / 2,
                y: rect.minY + rect.height * handle.unit.y - handleSize / 2
            )
    }

    /// 从起始框算新框：边把手只动那一条边（自由拉伸），
    /// 角把手以对角为锚点等比缩放（哪个方向拖得多听哪个）。
    private func resized(_ start: CGRect, handle: FrameHandle, translation: CGSize) -> CGRect {
        if handle.isCorner, keepAspectOnCorners {
            // 拖向外为正的增量：对角固定，左/上把手的手感和右/下一致。
            let dx = handle.unit.x == 0 ? -translation.width : translation.width
            let dy = handle.unit.y == 0 ? -translation.height : translation.height
            let sw = (start.width + dx) / max(start.width, 1)
            let sh = (start.height + dy) / max(start.height, 1)
            let scale = abs(sw - 1) >= abs(sh - 1) ? sw : sh
            let width = max(minSide, start.width * scale)
            let height = max(minSide, start.height * scale)
            let anchorX = handle.unit.x == 0 ? start.maxX : start.minX
            let anchorY = handle.unit.y == 0 ? start.maxY : start.minY
            return CGRect(
                x: handle.unit.x == 0 ? anchorX - width : anchorX,
                y: handle.unit.y == 0 ? anchorY - height : anchorY,
                width: width,
                height: height
            )
        }

        var minX = start.minX
        var minY = start.minY
        var maxX = start.maxX
        var maxY = start.maxY
        switch handle.unit.x {
        case 0: minX = min(minX + translation.width, maxX - minSide)
        case 1: maxX = max(maxX + translation.width, minX + minSide)
        default: break
        }
        switch handle.unit.y {
        case 0: minY = min(minY + translation.height, maxY - minSide)
        case 1: maxY = max(maxY + translation.height, minY + minSide)
        default: break
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// 框内单击转给外层（重新点选下面的内容）。没给回调就什么都不拦。
private struct TapLocationModifier: ViewModifier {
    let space: String
    let onTap: ((CGPoint) -> Void)?

    func body(content: Content) -> some View {
        if let onTap {
            content.onTapGesture(coordinateSpace: .named(space)) { onTap($0) }
        } else {
            content
        }
    }
}

private extension CGRect {
    func offsetBy(dx: Double, dy: Double) -> CGRect {
        CGRect(x: minX + dx, y: minY + dy, width: width, height: height)
    }
}
