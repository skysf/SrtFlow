import CoreGraphics
import Foundation
import SrtFlowMCPKit

// MARK: - look text_scan 给的「盖一块」的位置：源画面上的框换成画布上的框（纯值）
//
// 管什么：text_scan 报的字幕带 / 水印是**源画面**上的框；要盖住它得知道它现在落在**画布**的哪儿 —— 片段裁过、翻过、缩放摆过、旋转过，
// 位置都变了。这里按预览 / 导出同一个变换顺序（裁切 → 翻转 → 缩放进摆放框 → 绕框中心旋转，
// docs/architecture/preview-free-transform.md）把框换过去，再写成 `set_shape` 直接能抄的参数（x / y 是中心，都是画布的比例）。
// 不管什么：怎么认出字（AITextRegions）、怎么盖（VideoEditCoverExport / CoverPreviewLayer）、盖一块的模型（ShapeAnnotation）。
//
// 只按**此刻的摆放**换算（不看关键帧动画）：摆放有动画的话，位置随时间变，报出来的是没动画时的样子 —— 提示里写明先 look 时间线核对。

enum AICoverBox {

    /// 源画面（显示方向、左上原点、0…1）上的一块，现在落在画布（0…1、左上原点）的哪一块。旋转过的取外接框。
    /// 被裁掉的部分不算；整块都被裁掉了返回 nil。
    static func canvasRect(of source: CGRect, on clip: EditClip, canvas: CGSize) -> CGRect? {
        let crop = clip.crop ?? ClipCrop()
        let visible = CGRect(x: crop.leading, y: crop.top, width: 1 - crop.leading - crop.trailing, height: 1 - crop.top - crop.bottom)
        let shown = source.intersection(visible)
        guard !shown.isNull, shown.width > 1e-6, shown.height > 1e-6, visible.width > 0, visible.height > 0 else { return nil }
        // 裁后画面里的相对位置 0…1。
        var u0 = (shown.minX - visible.minX) / visible.width, u1 = (shown.maxX - visible.minX) / visible.width
        var v0 = (shown.minY - visible.minY) / visible.height, v1 = (shown.maxY - visible.minY) / visible.height
        if clip.flippedHorizontally { (u0, u1) = (1 - u1, 1 - u0) }
        if clip.flippedVertically { (v0, v1) = (1 - v1, 1 - v0) }
        let placement = clip.resolvedPlacement(canvas: canvas)
        let left = placement.centerX - placement.width / 2, top = placement.centerY - placement.height / 2
        var rect = CGRect(
            x: left + u0 * placement.width, y: top + v0 * placement.height,
            width: (u1 - u0) * placement.width, height: (v1 - v0) * placement.height
        )
        if abs(clip.rotationDegrees.truncatingRemainder(dividingBy: 360)) > 0.01, canvas.width > 0, canvas.height > 0 {
            // 绕摆放框中心转（顺时针为正，y 朝下）；转的是像素，不是归一化的比例。
            let angle = clip.rotationDegrees * .pi / 180
            let corners = [(rect.minX, rect.minY), (rect.maxX, rect.minY), (rect.maxX, rect.maxY), (rect.minX, rect.maxY)].map { corner -> CGPoint in
                let dx = (corner.0 - placement.centerX) * canvas.width, dy = (corner.1 - placement.centerY) * canvas.height
                let x = dx * cos(angle) - dy * sin(angle), y = dx * sin(angle) + dy * cos(angle)
                return CGPoint(x: placement.centerX + x / canvas.width, y: placement.centerY + y / canvas.height)
            }
            rect = CGRect(
                x: corners.map(\.x).min() ?? rect.minX, y: corners.map(\.y).min() ?? rect.minY,
                width: (corners.map(\.x).max() ?? rect.maxX) - (corners.map(\.x).min() ?? rect.minX),
                height: (corners.map(\.y).max() ?? rect.maxY) - (corners.map(\.y).min() ?? rect.minY)
            )
        }
        // 收进画布：探出去的部分盖了也没有画面可盖。
        let clipped = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return clipped.isNull || clipped.width <= 0 || clipped.height <= 0 ? nil : clipped
    }

    /// 四周各多留 `margin`（画布的比例）之后，写成 `set_shape` 的参数：x / y 是中心，width / height 是画布的比例。
    static func shapeArguments(covering rect: CGRect, margin: Double = 0.01) -> [String: JSONValue] {
        let padded = rect.insetBy(dx: -margin, dy: -margin).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        func round3(_ value: Double) -> JSONValue { .number((value * 1000).rounded() / 1000) }
        return ["x": round3(padded.midX), "y": round3(padded.midY), "width": round3(padded.width), "height": round3(padded.height)]
    }

    /// 字幕带要盖的那一条：**整条画面宽**（Vision 会把字幕和同一条线上的幻灯片字并成一个宽框，报出来的左右不可靠，
    /// docs/architecture/ai-control-mcp.md 第 37 条），从字幕上沿往上留一点，一直到画面底边（裁切也是这么裁的）。
    static func bandSource(_ band: CGRect) -> CGRect {
        let top = max(0, band.minY - 0.01)
        return CGRect(x: 0, y: top, width: 1, height: 1 - top)
    }

    /// 给 text_scan 的结果补上「盖一块」的参数（看的是时间线上的一段时才有：源画面上的框要换成画布上的）。
    /// `payload` 是 `AITextRegions.json` 出的那份；没找到字幕带 / 固定的字就原样不动。
    static func annotate(
        _ payload: inout [String: JSONValue], report: AITextRegions.Report, clip: EditClip, canvas: CGSize,
        timeline: (Double) -> Double
    ) {
        var suggested = false
        let clipStart = clip.timelineStart, clipDuration = clip.timelineEnd - clip.timelineStart
        if let band = report.band, case .object(var object)? = payload["subtitle_band"],
           let rect = canvasRect(of: bandSource(band.box), on: clip, canvas: canvas) {
            var cover = shapeArguments(covering: rect, margin: 0)
            cover["start"] = AIFormat.seconds(timeline(band.from))
            cover["duration"] = AIFormat.seconds(max(0.2, timeline(band.to) - timeline(band.from)))
            object["cover"] = .object(cover)
            payload["subtitle_band"] = .object(object)
            suggested = true
        }
        if case .array(var fixed)? = payload["fixed_text"] {
            for index in fixed.indices where index < report.fixed.count {
                guard case .object(var object) = fixed[index] else { continue }
                let mark = report.fixed[index]
                let boxes = mark.places.isEmpty ? [mark.box] : [mark.box] + mark.places
                let covers = boxes.compactMap { canvasRect(of: $0, on: clip, canvas: canvas) }.map { rect -> JSONValue in
                    var cover = shapeArguments(covering: rect)
                    cover["start"] = AIFormat.seconds(clipStart)
                    cover["duration"] = AIFormat.seconds(clipDuration)
                    return .object(cover)
                }
                guard !covers.isEmpty else { continue }
                object["cover"] = covers.count == 1 ? covers[0] : .array(covers)
                fixed[index] = .object(object)
                suggested = true
            }
            payload["fixed_text"] = .array(fixed)
        }
        if suggested {
            payload["cover_hint"] = .string(
                "To hide it without cropping: set_shape kind=blur (or mosaic) with the cover values (x, y, width, height are fractions of "
                    + "the canvas from the clip's current placement, start and duration are timeline seconds); the strip is the whole "
                    + "picture width because the scanned left and right are unreliable. Then look at the timeline to check it covers "
                    + "(the result is for a clip without animated placement; a watermark that jumps gets one cover per place)."
            )
        }
    }
}
