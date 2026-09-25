import CoreGraphics

// MARK: - 文字在预览上的可点范围
//
// 管什么：一段文字在预览画布上的两块矩形 ——
//   · **版面框**：选中框画在它上面；**选中之后**整个框里都能拖；
//   · **看得见的那一块**：字的墨迹（有底板时连底板一起），**没选中时**只有它能点。
// 两块都是未旋转的；旋转由调用方绕版面框中心套上去（和 `TextFrameBox` 同一个中心）。
//
// 不管什么：手势和绘制（`TextOverlayCanvas`、`TextFrameBox`）。
//
// 为什么没选中时只认看得见的部分：版面框的宽是折行宽度，默认占画面的 80%，
// 「090」这么短的数字也有 80% 宽。几段字的框在画面上互相盖着，点在「° SOUTH」
// 的字上会选中旁边的数字（2026-09-24 用户反馈）。约束见
// docs/architecture/text-overlays.md「预览上点得着哪里」。
//
// 一次排版出两块：预览每跳一下都要算，排两遍就是两倍的 Core Text 开销。

struct TextHitGeometry: Equatable {
    /// 版面框（画布坐标，左上原点，未旋转）。与 `TextRenderer.layoutFrame` 是同一个框。
    var frame: CGRect
    /// 看得见的那一块，**相对版面框的左上角**（未旋转），已经含 `contentPadding`。
    /// 空文字（刚 Add 出来还没打字）就是整个版面框 —— 不然什么都点不着。
    var contentInFrame: CGRect

    /// 墨迹四周多给的几点：小字只有十几点高，贴着墨迹判很难点中。
    static let contentPadding: Double = 6

    init(_ overlay: TextOverlay, canvas: CGSize) {
        // 定版串：数字滚动时位数会变，按当帧算的话可点范围会跟着跳（同选中框）。
        let layout = TextTypesetter.layout(overlay, canvas: canvas, text: overlay.settledText)
        let frame = TextRenderer.layoutFrame(overlay, canvas: canvas, layout: layout)
        self.frame = frame
        self.contentInFrame = Self.visibleRect(overlay, layout: layout, frame: frame, canvas: canvas)
    }

    /// 看得见的那一块，版面框本地坐标（左上原点）。
    ///
    /// 排版坐标是 y 向上、原点在版面左下（`TextTypesetter`）；框比排版高时（空文字给了
    /// 按字号算的最小高度）排版居中放在框里 —— 和 `TextRenderer.render` 摆位图的口径一样。
    private static func visibleRect(
        _ overlay: TextOverlay, layout: TextLayout, frame: CGRect, canvas: CGSize
    ) -> CGRect {
        let whole = CGRect(origin: .zero, size: frame.size)
        let ink = layout.inkBounds
        guard !ink.isNull, ink.width > 0, ink.height > 0 else { return whole }

        let layoutTop = (frame.height - layout.size.height) / 2
        var visible = CGRect(
            x: ink.minX,
            y: layoutTop + (layout.size.height - ink.maxY),
            width: ink.width,
            height: ink.height
        ).insetBy(dx: -contentPadding, dy: -contentPadding)

        // 底板是按**版面框**画的（`TextDrawing.background`），不是按墨迹 —— 开着底板时
        // 整块底板都是这段字看得见的身体，点在底板上当然该选中它。
        if let background = overlay.style.background, background.color.opacity > 0 {
            let scale = TextOverlay.pixelScale(canvas: canvas)
            let plate = CGRect(x: 0, y: layoutTop, width: layout.size.width, height: layout.size.height)
                .insetBy(dx: -max(0, background.paddingX * scale), dy: -max(0, background.paddingY * scale))
            visible = visible.union(plate)
        }
        return visible
    }
}
