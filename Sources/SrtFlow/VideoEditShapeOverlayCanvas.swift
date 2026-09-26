import AppKit
import SwiftUI

// MARK: - 预览上的形状叠层
//
// 管什么：预览画面上此刻该出现的形状（矩形 / 圆 / 箭头……）怎么画、怎么点选、怎么拖动和缩放（带中心吸附）。
// 不管什么：形状什么时候出现（`project.visibleShapes(at:)` 按时间取）、形状的数据怎么存（`ShapeAnnotation`）。
// 从 VideoEditView.swift 拆出来（那个文件在行数基线里只许降，见 docs/architecture/coding-standards.md）。

struct ShapeOverlayCanvas: View {
    let project: VideoEditProject
    /// 必须直接订阅时钟（和 `ClipTransformCanvas` 同款）：形状的出没跟着
    /// 播放头走，只观察 project 的话，播放/扫帧时这层不重算 —— 形状要么
    /// 到点不出现、要么过点不消失。
    @ObservedObject var clock: PlayerClock
    let boxSize: CGSize

    /// 拖动开始时的中心（归一化），增量都相对它算。
    @State private var dragOrigin: CGPoint?
    /// 中心参考线的亮灭（竖线, 横线）。
    @State private var centerGuides = (vertical: false, horizontal: false)

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        ZStack(alignment: .topLeading) {
            Color.clear
            // displayTime：悬停预览时形状的出没要跟画面那一帧走。
            ForEach(project.visibleShapes(at: clock.displayTime)) { shape in
                shapeView(shape)
            }
            // 选中形状的变换框：线条只给左右（改长度），正方形只给四角（保形），
            // 长方形全套八个。移动仍走形状本体的拖动手势，框体不拦事件。
            if let shape = project.selectedShape, shape.contains(time: clock.displayTime) {
                ResizableFrameBox(
                    rect: resizeBoxRect(shape),
                    bounds: boxSize,
                    handles: resizeHandles(shape),
                    keepAspectOnCorners: true,
                    movable: false,
                    onCenterGuides: { centerGuides = (vertical: $0, horizontal: $1) },
                    onChange: { newRect in applyShapeResize(shape, newRect) },
                    onEnd: { project.endLiveEdit(rebuildsPreview: false) }
                )
            }

            CenterGuideLines(
                canvas: boxSize,
                showVertical: centerGuides.vertical,
                showHorizontal: centerGuides.horizontal
            )
        }
        .frame(width: boxSize.width, height: boxSize.height)
    }

    /// 框比形状本体略大一圈。线条按**旋转后的包络**画框（绘制带
    /// rotationEffect，`frame(in:)` 不带），细的方向撑到能看见。
    private func resizeBoxRect(_ shape: ShapeAnnotation) -> CGRect {
        var frame = shape.frame(in: boxSize)
        if shape.kind == .line {
            let angle = shape.rotationDegrees * .pi / 180
            let w = abs(frame.width * cos(angle))
            let h = abs(frame.width * sin(angle))
            frame = CGRect(x: frame.midX - w / 2, y: frame.midY - h / 2, width: w, height: h)
        }
        frame = frame.insetBy(dx: -4, dy: -4)
        if shape.kind == .line {
            let minSide = 14.0
            if frame.height < minSide {
                frame = frame.insetBy(dx: 0, dy: -(minSide - frame.height) / 2)
            }
            if frame.width < minSide {
                frame = frame.insetBy(dx: -(minSide - frame.width) / 2, dy: 0)
            }
        }
        return frame
    }

    private func resizeHandles(_ shape: ShapeAnnotation) -> Set<FrameHandle> {
        switch shape.kind {
        case .line:
            // 转过角度的线，左右把手方向就不对了：只留框做选中指示，
            // 长度在检查器里调。没转的照旧左右改长度。
            let rotated = abs(shape.rotationDegrees.truncatingRemainder(dividingBy: 360)) > 0.5
            return rotated ? [] : FrameHandle.horizontal
        case .square: return FrameHandle.corners
        case .rectangle: return FrameHandle.all
        }
    }

    /// 把新框写回归一化的形状字段。正方形由 `updateShape` 强制保形；
    /// 线条只吃长度和中心，高度是撑出来的视觉量，不落模型。
    private func applyShapeResize(_ shape: ShapeAnnotation, _ newRect: CGRect) {
        let rect = newRect.insetBy(dx: 4, dy: 4)
        let kind = shape.kind
        project.liveApply { state in
            state.updateShape(shape.id) {
                $0.centerX = min(max(newRect.midX / boxSize.width, 0), 1)
                $0.centerY = min(max(newRect.midY / boxSize.height, 0), 1)
                $0.width = min(max(rect.width / boxSize.width, 0.02), 1)
                if kind == .rectangle {
                    $0.height = min(max(rect.height / boxSize.height, 0.02), 1)
                }
            }
        }
    }

    @ViewBuilder
    private func shapeView(_ shape: ShapeAnnotation) -> some View {
        let frame = shape.frame(in: boxSize)
        let strokeWidth = max(0.5, shape.lineWidth * boxSize.height / 1080)

        Group {
            switch shape.kind {
            case .line:
                RoundedRectangle(cornerRadius: strokeWidth / 2)
                    .fill(shape.color.swiftUIColor)
                    .frame(width: max(2, frame.width), height: strokeWidth)
                    .rotationEffect(.degrees(shape.rotationDegrees))
                    .frame(width: max(2, frame.width), height: max(strokeWidth, frame.width))
            case .rectangle, .square:
                Rectangle()
                    .strokeBorder(shape.color.swiftUIColor, lineWidth: strokeWidth)
                    .frame(width: max(2, frame.width), height: max(2, frame.height))
            }
        }
        .contentShape(Rectangle().inset(by: -8))
        .position(x: shape.centerX * boxSize.width, y: shape.centerY * boxSize.height)
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if dragOrigin == nil {
                        dragOrigin = CGPoint(x: shape.centerX, y: shape.centerY)
                        project.selectShape(shape.id, additive: false)
                    }
                    guard let origin = dragOrigin else { return }
                    // 接近画布中心时吸附并亮参考线，和剪辑变换框同一套手感。
                    let size = shape.frame(in: boxSize).size
                    var proposed = CGRect(
                        x: (origin.x + value.translation.width / boxSize.width) * boxSize.width - size.width / 2,
                        y: (origin.y + value.translation.height / boxSize.height) * boxSize.height - size.height / 2,
                        width: size.width,
                        height: size.height
                    )
                    let snapped = CenterSnap.snap(proposed, in: boxSize)
                    proposed = snapped.rect
                    centerGuides = (vertical: snapped.snappedX, horizontal: snapped.snappedY)
                    let nx = proposed.midX / boxSize.width
                    let ny = proposed.midY / boxSize.height
                    project.liveApply { state in
                        state.updateShape(shape.id) {
                            $0.centerX = min(max(nx, 0), 1)
                            $0.centerY = min(max(ny, 0), 1)
                        }
                    }
                }
                .onEnded { _ in
                    dragOrigin = nil
                    centerGuides = (vertical: false, horizontal: false)
                    project.endLiveEdit(rebuildsPreview: false)
                }
        )
        .onTapGesture { project.selectShape(shape.id, additive: false) }
    }
}
