import CoreGraphics
import SwiftUI

// MARK: - 预览上一块形状的画面
//
// 管什么：预览里一块形状（线条、长方形、正方形、圆、圆弧）这一刻画成什么样：路径、截到哪、缩多少、露出哪一块、多透明
// 全部来自 `ShapeOutline.drawing`（导出 `ShapePNGRenderer` 同一份），这里只按 SwiftUI 的写法上色。
// 不管什么：点选、拖动、可点范围、摆在画布哪儿（`ShapeOverlayCanvas`）；动画求值（`ShapeAnimator`）；盖一块（不画东西）。
// 是函数不是视图类型：每次播放头跳一格 `ShapeOverlayCanvas` 都会重算，多一层视图就多一份性能计数（docs/architecture/preview-perf-ratchet.md）。
// 自检（scripts/check-shape-render.sh）把它离屏渲一张，和导出那张逐像素比。

enum ShapePreviewDrawing {
    /// 预览里这一块的框多大：线条撑成「长度 × 长度」见方（转过角度的线落在框里，可点范围就是它），别的就是外接框。
    static func size(of shape: ShapeAnnotation, frame: CGRect, strokeWidth: Double) -> CGSize {
        shape.kind == .line
            ? CGSize(width: max(2, frame.width), height: max(strokeWidth, frame.width))
            : CGSize(width: max(2, frame.width), height: max(2, frame.height))
    }

    /// 这一块此刻的画面，`size` 大小、框的左上角是原点（调用方再 `.position` 到形状的中心）。
    @ViewBuilder
    static func view(_ shape: ShapeAnnotation, size: CGSize, strokeWidth: Double, state: ShapeAnimationState) -> some View {
        let drawing = ShapeOutline.drawing(for: shape, size: size, strokeWidth: strokeWidth, state: state)
        // 同 `SubtitleColor.swiftUIColor`（MediaFormatting.swift）；这里直接写，自检不用为一行颜色编进一串界面文件。
        let color = Color(.sRGB, red: shape.color.red, green: shape.color.green, blue: shape.color.blue, opacity: shape.color.opacity)
        let painted = Group {
            if drawing.filled {
                Path(drawing.path).fill(color)
            } else {
                Path(drawing.path).stroke(color, style: StrokeStyle(
                    lineWidth: strokeWidth, lineCap: drawing.lineCap == .round ? .round : .butt, lineJoin: .miter
                ))
            }
        }
        .frame(width: size.width, height: size.height)

        if let reveal = drawing.reveal {
            painted
                .mask(alignment: .topLeading) { Path(reveal).fill(Color.black) }
                .opacity(drawing.opacity)
        } else {
            painted.opacity(drawing.opacity)
        }
    }
}
