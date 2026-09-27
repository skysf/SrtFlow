import CoreGraphics
import Foundation

// MARK: - edit_clip 里和画面有关的参数（纯值）
//
// 管什么：fit / focus_x / focus_y / crop / x / y / scale 读成类型，互相冲突的组合当场挡掉
// （fit 和 x/y/scale 不能一起给、focus 只跟 fit=fill 走）。纯值，自检够得着（scripts/check-mcp.sh）。
// 不管什么：按这些参数算裁切和摆放（AIFrameFit）、去看画面（AIClipTools）。

/// edit_clip 里和画面有关的那几个参数（读的时候就把互相冲突的组合挡掉）。
struct AIFramingRequest {
    enum Fit: String { case fit, fill }

    var fit: Fit?
    var focusPoint: CGPoint?
    /// 手动的四边裁切（`crop` 参数）；给了全 0 就是不裁。
    var crop: ClipCrop?
    var x: Double?
    var y: Double?
    var scale: Double?

    var touchesPicture: Bool {
        fit != nil || crop != nil || x != nil || y != nil || scale != nil
    }

    init(_ args: AIToolArguments) throws {
        fit = try args.choice("fit", from: ["fit", "fill"]).flatMap(Fit.init(rawValue:))
        x = try args.double("x")
        y = try args.double("y")
        scale = try args.double("scale")
        let focusX = try args.double("focus_x")
        let focusY = try args.double("focus_y")
        if focusX != nil || focusY != nil {
            focusPoint = CGPoint(x: min(max(focusX ?? 0.5, 0), 1), y: min(max(focusY ?? 0.5, 0), 1))
        }
        if args.has("crop") {
            guard let raw = args.raw["crop"], case .object = raw else {
                throw AIToolError("crop must be an object like {\"left\": 0.1, \"right\": 0.1, \"top\": 0, \"bottom\": 0}.")
            }
            let edges = AIToolArguments(raw)
            crop = ClipCrop(
                top: try edges.double("top") ?? 0, bottom: try edges.double("bottom") ?? 0,
                leading: try edges.double("left") ?? 0, trailing: try edges.double("right") ?? 0
            )
        }
        if fit != nil, x != nil || y != nil || scale != nil {
            throw AIToolError("Use fit to fill or fit the frame, or x/y/scale to place the picture yourself, not both.")
        }
        if focusPoint != nil, fit != .fill {
            throw AIToolError("focus_x/focus_y only apply with fit=fill.")
        }
        if let scale, !(0.05...6).contains(scale) { throw AIToolError("scale must be between 0.05 and 6.") }
    }
}
