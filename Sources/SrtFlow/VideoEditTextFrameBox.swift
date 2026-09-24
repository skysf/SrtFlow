import AppKit
import SwiftUI

// MARK: - 文字的选中框
//
// 没复用 `ResizableFrameBox`：那个框不会转，而文字要转。把旋转加进那个共用
// 组件，会让剪辑和形状也跟着长出一套用不上的角度语义 —— 它们的旋转在检查器里。
//
// ## 三种把手，三种数学
//
// 框本身是**转过的**，所以把手位置也是转过的，而拖动位移在屏幕坐标系里。
// 每种把手各自挑一条显式的算法，而不是拿一个通用仿射解算器去硬解 ——
// 那种写法在角度接近 90° 时数值会炸。
//
//   角把手：把位移**反旋转**回框的本地坐标，量「把手到中心」这条向量变长了
//           多少倍。等比 —— 文字的缩放本来就只有字号一个自由度。
//   边把手：同样反旋转，只取 x 分量改折行宽度。框是中心锚定的，拖一边两边
//           一起长，所以乘 2。
//   旋转  ：指针相对框中心的极角，减去起手时的极角。
//
// ## 坐标系
//
// 把手一律用**调用方声明的命名坐标系**（`TextFrameBox.space`），不是 `.local`
// 也不是 `.global`：
//   - `.local` 随把手自己移动，位移会被自己的移动抵消（同剪辑块裁切把手）；
//   - `.global` 里拿不到画布原点，旋转手势算不出「指针相对框中心」的极角。
// 命名空间钉在不动的画布上，两个问题都没有。
//
// ## 起手状态必须冻结
//
// `frame` 在手势过程中**会变**（改了字号，框就大了）。所有算法都拿起手时的
// 尺寸当基准 —— 用当前帧当基准的话，缩放会自己加速成指数。

struct TextFrameBox: View {
    /// 未旋转的版面框（画布坐标，左上原点）。
    let frame: CGRect
    let rotationDegrees: Double
    let canvas: CGSize
    /// 字号的缩放倍数（相对手势开始时）。
    let onScale: (Double) -> Void
    /// 新的框宽（画布宽度的比例）。
    let onResizeWidth: (Double) -> Void
    /// 新的角度（度）。
    let onRotate: (Double) -> Void
    let onEnd: () -> Void

    /// 调用方要在画布上声明这个命名坐标系。
    static let space = "textOverlayCanvas"

    @State private var origin: Origin?

    /// 手势起手时冻结的状态。三种把手共用一份。
    private struct Origin {
        var center: CGPoint
        var size: CGSize
        var boxWidth: Double
        var rotationDegrees: Double
        var pointerAngle: Double
    }

    private static let handleSize: Double = 8
    private static let rotateHandleGap: Double = 22

    private var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        ZStack {
            Rectangle()
                .strokeBorder(Color.accentColor, lineWidth: 1)
                .frame(width: frame.width, height: frame.height)

            ForEach(Corner.allCases, id: \.self) { corner in
                handle(filled: true)
                    .offset(x: corner.unitX * frame.width / 2, y: corner.unitY * frame.height / 2)
                    .gesture(scaleGesture(corner: corner))
            }

            ForEach([-1.0, 1.0], id: \.self) { side in
                handle(filled: false)
                    .offset(x: side * frame.width / 2)
                    .gesture(widthGesture(side: side))
            }

            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 1, height: Self.rotateHandleGap)
                .offset(y: -frame.height / 2 - Self.rotateHandleGap / 2)
                .allowsHitTesting(false)
            Circle()
                .fill(Color.accentColor)
                .frame(width: Self.handleSize + 2, height: Self.handleSize + 2)
                .offset(y: -frame.height / 2 - Self.rotateHandleGap)
                .contentShape(Circle().inset(by: -6))
                .gesture(rotateGesture)
        }
        // 框线本身不拦事件：框比文字大一圈，点在文字旁边的空白不该开始拖。
        // 移动由调用方那块命中矩形收（见 VideoEditTextOverlayCanvas）。
        .rotationEffect(.degrees(rotationDegrees))
        .position(center)
    }

    private enum Corner: CaseIterable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing
        var unitX: Double { self == .topLeading || self == .bottomLeading ? -1 : 1 }
        var unitY: Double { self == .topLeading || self == .topTrailing ? -1 : 1 }
    }

    private func handle(filled: Bool) -> some View {
        Circle()
            .fill(filled ? Color.accentColor : Color.white)
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1))
            .frame(width: Self.handleSize, height: Self.handleSize)
            // 把手才 8 点宽，不撑开命中范围根本按不住。
            .contentShape(Circle().inset(by: -6))
    }

    // MARK: - 起手冻结

    @discardableResult
    private func freeze(pointer: CGPoint) -> Origin {
        if let existing = origin { return existing }
        let made = Origin(
            center: center,
            size: frame.size,
            boxWidth: frame.width / max(canvas.width, 1),
            rotationDegrees: rotationDegrees,
            pointerAngle: atan2(pointer.y - center.y, pointer.x - center.x)
        )
        origin = made
        return made
    }

    /// 屏幕位移 → 框的本地位移（反旋转）。
    private func localized(_ translation: CGSize, radians: Double) -> CGPoint {
        CGPoint(
            x: translation.width * cos(radians) + translation.height * sin(radians),
            y: -translation.width * sin(radians) + translation.height * cos(radians)
        )
    }

    // MARK: - 把手手势

    private func scaleGesture(corner: Corner) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { value in
                let start = freeze(pointer: value.startLocation)
                let half = CGPoint(
                    x: corner.unitX * start.size.width / 2,
                    y: corner.unitY * start.size.height / 2
                )
                let baseSquared = half.x * half.x + half.y * half.y
                guard baseSquared > 1 else { return }
                let local = localized(value.translation, radians: start.rotationDegrees * .pi / 180)
                let moved = CGPoint(x: half.x + local.x, y: half.y + local.y)
                // 取「沿原对角线方向」的分量：横着拖不会把角拽向另一个方向。
                onScale(max(0.05, (moved.x * half.x + moved.y * half.y) / baseSquared))
            }
            .onEnded { _ in finish() }
    }

    private func widthGesture(side: Double) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { value in
                let start = freeze(pointer: value.startLocation)
                let local = localized(value.translation, radians: start.rotationDegrees * .pi / 180)
                onResizeWidth(start.boxWidth + side * local.x * 2 / max(canvas.width, 1))
            }
            .onEnded { _ in finish() }
    }

    private var rotateGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { value in
                let start = freeze(pointer: value.startLocation)
                let current = atan2(
                    value.location.y - start.center.y,
                    value.location.x - start.center.x
                )
                let angle = start.rotationDegrees
                    + (current - start.pointerAngle) * 180 / .pi
                // ⇧ 吸 15°：手动拖准水平/垂直基本不可能。
                onRotate(NSEvent.modifierFlags.contains(.shift) ? (angle / 15).rounded() * 15 : angle)
            }
            .onEnded { _ in finish() }
    }

    private func finish() {
        origin = nil
        onEnd()
    }
}

extension TextFrameBox {
    /// 移动落点（含画布中心吸附）。挂在调用方的命中矩形上，不在框里。
    static func movedCenter(
        from origin: CGPoint, translation: CGSize, frameSize: CGSize, canvas: CGSize
    ) -> (center: CGPoint, guides: (vertical: Bool, horizontal: Bool)) {
        let proposed = CGRect(
            x: origin.x + translation.width - frameSize.width / 2,
            y: origin.y + translation.height - frameSize.height / 2,
            width: frameSize.width,
            height: frameSize.height
        )
        let snapped = CenterSnap.snap(proposed, in: canvas)
        return (
            CGPoint(x: snapped.rect.midX, y: snapped.rect.midY),
            (snapped.snappedX, snapped.snappedY)
        )
    }
}
