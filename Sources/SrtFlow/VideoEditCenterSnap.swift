import SwiftUI

// MARK: - 预览画布的中心对齐

/// 拖动预览里的内容（剪辑变换框、形状）接近画布正中时吸附，并亮出横/竖
/// 两条参考线（Keynote 的习惯）。缩放/拉伸把手不吸附 —— 吸中心会拽歪
/// 锚定在对角/对边的手感 —— 只在恰好对中时亮线提示。
enum CenterSnap {

    /// 移动吸附半径（视图点）。
    static let tolerance: Double = 6
    /// 缩放时「算对中」的判定半径：不吸附，纯提示，给宽一点才看得见。
    static let alignTolerance: Double = 2

    struct Result {
        var rect: CGRect
        /// 水平方向对中（亮竖线）。
        var snappedX = false
        /// 垂直方向对中（亮横线）。
        var snappedY = false
    }

    /// 把框的中心往画布中心吸。只给移动手势用。
    static func snap(_ rect: CGRect, in canvas: CGSize) -> Result {
        var result = Result(rect: rect)
        let dx = canvas.width / 2 - rect.midX
        if abs(dx) <= tolerance {
            result.rect.origin.x += dx
            result.snappedX = true
        }
        let dy = canvas.height / 2 - rect.midY
        if abs(dy) <= tolerance {
            result.rect.origin.y += dy
            result.snappedY = true
        }
        return result
    }

    /// 框的中心正好在画布中心吗（缩放时只亮线不吸）。
    static func aligned(_ rect: CGRect, in canvas: CGSize) -> (x: Bool, y: Bool) {
        (
            abs(rect.midX - canvas.width / 2) <= alignTolerance,
            abs(rect.midY - canvas.height / 2) <= alignTolerance
        )
    }
}

/// 亮起的中心参考线，铺满画布、不拦事件。
struct CenterGuideLines: View {
    let canvas: CGSize
    var showVertical: Bool
    var showHorizontal: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if showVertical {
                Rectangle()
                    .fill(.yellow)
                    .frame(width: 1, height: canvas.height)
                    .offset(x: canvas.width / 2 - 0.5)
            }
            if showHorizontal {
                Rectangle()
                    .fill(.yellow)
                    .frame(width: canvas.width, height: 1)
                    .offset(y: canvas.height / 2 - 0.5)
            }
        }
        .allowsHitTesting(false)
    }
}
