import CoreGraphics
import CoreImage
import CoreText
import Foundation
import SrtFlowCore

// MARK: - 文字渲染（预览与导出的唯一绘制入口）
//
// **两条管线只准从这里出画面。** 字幕那边是两套（导出走 libass、预览用
// SwiftUI 八份阴影凑个假描边，文件里自己写着「这是近似效果」），字幕能忍是因为
// 样式就那么几档；文字要精调质感，预览对不上就等于没法调。所以这里只有一个
// 函数，预览和导出的差别只有传进来的 `canvas` 尺寸和时刻。
//
// 四道绘制（底板/描边/填充/字形）在 VideoEditTextDrawing.swift。
//
// ## 坐标系
//
// 全程 **y 轴向上**（Core Graphics 原生），不像 ShapePNGRenderer 那样翻成
// 左上原点 —— 文字要喂给 `CTFontDrawGlyphs`，翻一次就多一处符号写反的机会。
// 排版侧（`TextTypesetter`）产出的也是同一套坐标。
//
// 对外只有 `origin` 是左上原点（画布像素），因为调用方（SwiftUI 叠层、
// ffmpeg overlay）都按左上原点摆图。
//
// ## 包络按**整段动画的极值**算，不是按某一帧
//
// 逐帧导出时每一帧都按同一个框渲，overlay 的 x/y 才能全程固定 ——
// 按当帧算的话，位图尺寸每帧都在变，贴图位置得跟着改，动画会抖。

/// 渲染产物：一张只包住文字的位图，加上它在画布上的落点。
///
/// 位图**只有包络那么大**，不是整幅画布：5 秒标题逐帧导出时，整幅 1080p RGBA
/// 是每帧 8MB，包络通常只有几十分之一。
struct RenderedText {
    var image: CGImage
    /// 位图左上角在画布上的像素位置（左上原点）。
    var origin: CGPoint

    var size: CGSize { CGSize(width: image.width, height: image.height) }
}

enum TextRenderer {

    /// 版面框在画布上的位置（未旋转、不含动画偏移，左上原点）。
    /// 选中框和命中测试用它。
    ///
    /// **不含动画**是刻意的：画面上拖出来的位置永远是动画播完的落点，
    /// 选中框跟着动画飞的话根本拖不住（见 text-overlays.md 的不变量）。
    static func layoutFrame(_ overlay: TextOverlay, canvas: CGSize) -> CGRect {
        // 用**定版串**：数字滚动时位数会变，按当帧算的话选中框会跟着跳。
        layoutFrame(
            overlay, canvas: canvas,
            layout: TextTypesetter.layout(overlay, canvas: canvas, text: overlay.settledText)
        )
    }

    /// 同上，排版由调用方给 —— `TextHitGeometry` 一次排版既要框又要墨迹范围，
    /// 别让它排两遍。传进来的**必须是定版串的排版**。
    static func layoutFrame(_ overlay: TextOverlay, canvas: CGSize, layout: TextLayout) -> CGRect {
        let size = CGSize(
            width: layout.size.width,
            // 空文字的框高是 0，画面上就什么都点不着了；给一个按字号算的
            // 最小高度，保证刚 Add 出来还没打字时框也拖得动。
            height: max(layout.size.height, overlay.style.fontSize * TextOverlay.pixelScale(canvas: canvas))
        )
        return CGRect(
            x: overlay.centerX * canvas.width - size.width / 2,
            y: overlay.centerY * canvas.height - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// 画这一段文字。`state` 默认是"不动"（静态文字走这条）。
    /// 空文字返回 nil（画面上不渲染、导出跳过）。
    static func render(
        _ overlay: TextOverlay, canvas: CGSize,
        state: TextAnimationState = TextAnimationState()
    ) -> RenderedText? {
        guard !overlay.isBlank, canvas.width > 0, canvas.height > 0 else { return nil }
        let scale = TextOverlay.pixelScale(canvas: canvas)
        // 两份排版，各司其职：
        //   · settled —— 定位与包络。数字滚动时位数会变，按当帧算的话位图
        //     尺寸每帧都不一样，贴图位置就固定不住了。
        //   · frame   —— 这一帧真要画的内容。
        // 两者的框宽、对齐、字体完全相同，只有字符串（以及老虎机里正滚进滚出的
        // 那几格此刻占多宽）可能不同。
        let settled = TextTypesetter.layout(overlay, canvas: canvas, text: overlay.settledText)
        let layout = state.textOverride.map {
            TextTypesetter.layout(overlay, canvas: canvas, text: $0, widths: state.odometer?.widths ?? [:])
        } ?? settled
        guard !settled.isEmpty else { return nil }

        let layoutBox = CGRect(origin: .zero, size: settled.size)
        let center = CGPoint(x: layoutBox.midX, y: layoutBox.midY)
        let visual = visualBounds(overlay, layout: settled, scale: scale)
        let framed = animationBounds(visual, around: center, overlay: overlay, canvas: canvas)
        let radians = -overlay.rotationDegrees * .pi / 180  // y 向上：顺时针是负角
        let envelope = rotatedBounds(framed, around: center, radians: radians)

        let pixelWidth = Int(ceil(envelope.width))
        let pixelHeight = Int(ceil(envelope.height))
        guard pixelWidth > 0, pixelHeight > 0,
              pixelWidth <= 16384, pixelHeight <= 16384,
              let context = makeContext(width: pixelWidth, height: pixelHeight) else { return nil }

        context.textMatrix = .identity
        // 位图左下角 ↔ 包络左下角。
        context.translateBy(x: -envelope.minX, y: -envelope.minY)
        // 绕版面框中心旋转，之后一律用未旋转的版面框坐标画。
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: radians)
        context.translateBy(x: -center.x, y: -center.y)

        // 动画的位移和缩放。**位移写在缩放外面**：先 translate 后 scale，
        // 于是位移量不被缩放放大（CG 的 CTM 是后调用的先作用于点）。
        // `offsetY` 是 y 向下为正（UI 直觉），这里的画布 y 向上 —— 取负。
        if state.offsetY != 0 {
            context.translateBy(x: 0, y: -state.offsetY)
        }
        if state.scale != 1 {
            context.translateBy(x: center.x, y: center.y)
            context.scaleBy(x: state.scale, y: state.scale)
            context.translateBy(x: -center.x, y: -center.y)
        }
        if state.opacity < 1 {
            context.setAlpha(max(0, state.opacity))
        }
        if let wipe = state.wipe {
            TextDrawing.clipWipe(wipe, bounds: visual, into: context)
        }

        // 这一帧的内容行数可能和定版不同（数字滚到位数变多就会多折一行）。
        // 定位、包络全按定版算，所以画的时候要把**第一行基线**对到定版的
        // 第一行上 —— 不对齐的话，多出一行的那一刻数字会整个竖着跳一下。
        if layout.lines.count != settled.lines.count {
            context.translateBy(x: 0, y: settled.firstBaselineY - layout.firstBaselineY)
        }

        TextDrawing.background(overlay.style, layoutBox: layoutBox, scale: scale, into: context)

        if let shadow = overlay.style.shadow, shadow.color.opacity > 0 {
            context.setShadow(
                // y 向上，所以「往下偏移」是负的。
                offset: CGSize(width: shadow.offsetX * scale, height: -shadow.offsetY * scale),
                blur: max(0, shadow.blur * scale),
                color: TextDrawing.cgColor(shadow.color)
            )
        }
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        TextDrawing.stroke(
            overlay.style, layout: layout, scale: scale, animation: state,
            wipe: state.strokeDraw?.strokeWipe, clipBounds: visual, into: context
        )
        TextDrawing.fill(
            overlay.style, layout: layout, animation: state,
            extraAlpha: state.strokeDraw?.fillOpacity ?? 1, into: context
        )
        context.endTransparencyLayer()

        guard var image = context.makeImage() else { return nil }
        if state.blur > 0.5, let blurred = blurred(image, radius: state.blur) {
            image = blurred
        }

        // 包络中心相对版面框中心的偏移，换算到画布的左上原点坐标系。
        let canvasCenter = CGPoint(
            x: overlay.centerX * canvas.width,
            y: overlay.centerY * canvas.height
        )
        let imageCenter = CGPoint(
            x: canvasCenter.x + (envelope.midX - center.x),
            y: canvasCenter.y - (envelope.midY - center.y)  // y 轴在这里翻过来
        )
        // **落点取整**：ffmpeg 的 overlay 按整像素贴图，预览也按同一个整数摆位，
        // 于是两条管线的文字落在**同一个像素**上。不取整的话，同一段文字在预览
        // 里是 100.4px、在成片里是 100px，逐像素比对的回归就永远差半个像素。
        return RenderedText(
            image: image,
            origin: CGPoint(
                x: (imageCenter.x - Double(pixelWidth) / 2).rounded(),
                y: (imageCenter.y - Double(pixelHeight) / 2).rounded()
            )
        )
    }

    // MARK: - 包络

    /// 未旋转时，这段文字实际会画到哪个范围（含描边、投影、底板）。
    private static func visualBounds(
        _ overlay: TextOverlay, layout: TextLayout, scale: Double
    ) -> CGRect {
        let layoutBox = CGRect(origin: .zero, size: layout.size)
        // 版面框和墨迹取并集：斜体和某些字体的墨迹会探出版面框一点点。
        var bounds = layoutBox.union(layout.inkBounds)

        if let stroke = overlay.style.stroke {
            let pad = max(0, stroke.width * scale)
            bounds = bounds.insetBy(dx: -pad, dy: -pad)
        }
        if let background = overlay.style.background, background.color.opacity > 0 {
            bounds = bounds.union(layoutBox.insetBy(
                dx: -max(0, background.paddingX * scale),
                dy: -max(0, background.paddingY * scale)
            ))
        }
        if let shadow = overlay.style.shadow, shadow.color.opacity > 0 {
            // 模糊要留够：CG 的 blur 参数不是严格的高斯半径，1.5 倍是经验余量，
            // 留少了影子会被位图边缘切掉一条直边（非常显眼）。
            let spread = max(0, shadow.blur * scale) * 1.5
            let shifted = bounds
                .offsetBy(dx: shadow.offsetX * scale, dy: -shadow.offsetY * scale)
                .insetBy(dx: -spread, dy: -spread)
            bounds = bounds.union(shifted)
        }
        // 抗锯齿的半像素余量。
        return bounds.insetBy(dx: -2, dy: -2)
    }

    /// 再按**整段动画的极值**外扩一圈。每一帧都用同一个结果，
    /// 所以贴图位置全程固定。
    private static func animationBounds(
        _ bounds: CGRect, around center: CGPoint, overlay: TextOverlay, canvas: CGSize
    ) -> CGRect {
        let allowance = TextAnimator.envelopeAllowance(for: overlay, canvas: canvas)
        var result = bounds
        if allowance.inset > 0 {
            result = result.insetBy(dx: -allowance.inset, dy: -allowance.inset)
        }
        if allowance.scale > 1 {
            let width = result.width * allowance.scale
            let height = result.height * allowance.scale
            result = CGRect(
                x: center.x + (result.minX - center.x) * allowance.scale,
                y: center.y + (result.minY - center.y) * allowance.scale,
                width: width, height: height
            )
        }
        return result
    }

    /// 绕某点旋转后的外接矩形。
    private static func rotatedBounds(_ rect: CGRect, around center: CGPoint, radians: Double) -> CGRect {
        guard abs(radians) > 0.0001 else { return rect }
        let transform = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: radians)
            .translatedBy(x: -center.x, y: -center.y)
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
        ].map { $0.applying(transform) }
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        return CGRect(
            x: xs.min() ?? 0, y: ys.min() ?? 0,
            width: (xs.max() ?? 0) - (xs.min() ?? 0),
            height: (ys.max() ?? 0) - (ys.min() ?? 0)
        )
    }

    // MARK: - 画布与模糊

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    /// 共享一个 `CIContext`：每次新建要几十毫秒，逐帧导出时会变成主要开销。
    /// `CIContext` 本身是线程安全的。
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// 模糊整张产物，而不是在绘制中途模糊。
    ///
    /// 位图里除了字什么都没有（四周全透明），所以"模糊最终结果"和"模糊文字"
    /// 是同一件事；而包络已经按最大模糊半径留过余量，糊出来的边不会被切掉。
    private static func blurred(_ image: CGImage, radius: Double) -> CGImage? {
        let source = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIGaussianBlur", parameters: [
            kCIInputImageKey: source,
            kCIInputRadiusKey: radius
        ]), let output = filter.outputImage else { return nil }
        // `CIGaussianBlur` 会把 extent 撑大，裁回原尺寸 —— 否则产物尺寸每帧
        // 都不一样，贴图位置就固定不住了。
        return ciContext.createCGImage(output.cropped(to: source.extent), from: source.extent)
    }
}
