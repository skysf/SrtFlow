import CoreGraphics
import Foundation

// MARK: - 导出图里的「盖一块」（模糊 / 马赛克）
//
// 管什么：把 `renderedCovers` 翻成导出滤镜图里的步骤：整幅画面复制一份 → 裁出这一块 → 模糊（`gblur`）或打马赛克（`pixelize`）→
// 贴回原位，只在这一块的时间段里生效。落点在**调色之后、形状之前**：盖的是主轨 + 上层轨合成、调完色的画面，形状 / 文字 / 字幕
// 压在它上面不受影响 —— 和预览侧（`CoverPreviewLayer`：同一个播放器再开一层、只露那一块加模糊，叠层是它上面的兄弟视图）一字不差。
// 不管什么：预览怎么盖（CoverPreviewLayer）、模型（VideoEditShapeModels.swift）、别的步骤（VideoEditExportGraph）。
//
// **两条管线按构造一致：裁出这一块、在这一块里做效果、边缘往外延、贴回去。** 预览的图层滤镜是
// `CIAffineClamp` + `CIGaussianBlur`（边缘外延的真高斯），这里是 `crop` 之后的 `gblur`（同样边缘外延；`steps=3` 和理想高斯最大差
// 2%），半径都是高斯的标准差、都按 1080p 基准换算到画布。马赛克的格子从这一块的左上角起算（预览的 CIPixellate 有自己的格子对齐，
// 两边的格子边长一样、位置差半格以内，不追像素一致）。
// 坐标都是**成片画布的像素**（形状 / 文字的 PNG 用的同一个 `renderSize`），取偶数：yuv420 的 crop 和 overlay 要偶数对齐，
// 不取偶数的话 overlay 会错一个像素。

enum VideoEditCoverExport {

    /// 高斯的近似步数：1 步最大差 6%，3 步 2%，再多每帧的 CPU 白花（只算裁出来的那一块）。
    static let gaussianSteps = 3

    /// 一块盖在成片画布上的整数像素框：取偶数、收进画布。
    static func pixelRect(_ cover: ShapeAnnotation, canvas: CGSize) -> CGRect? {
        let frame = cover.frame(in: canvas)
        let x = max(0, Int((frame.minX / 2).rounded(.down)) * 2)
        let y = max(0, Int((frame.minY / 2).rounded(.down)) * 2)
        let right = min(Int(canvas.width), Int((frame.maxX / 2).rounded(.up)) * 2)
        let bottom = min(Int(canvas.height), Int((frame.maxY / 2).rounded(.up)) * 2)
        guard right - x >= 2, bottom - y >= 2 else { return nil }
        return CGRect(x: x, y: y, width: right - x, height: bottom - y)
    }

    /// 力度（1080p 基准像素）换算到成片画布，至少 1。
    static func pixels(_ amount: Double, canvas: CGSize) -> Double {
        max(1, amount * canvas.height / Double(1080))
    }

    /// 一块盖一块翻成的滤镜段。`input` 是接上来的画面标签，返回新的画面标签。
    static func steps(
        _ cover: ShapeAnnotation, canvas: CGSize, total: Double,
        input: String, nextLabel: (String) -> String
    ) -> (filters: [String], output: String)? {
        guard cover.timelineEnd > 0, cover.timelineStart < total,
              let rect = pixelRect(cover, canvas: canvas) else { return nil }
        let x = Int(rect.minX), y = Int(rect.minY), w = Int(rect.width), h = Int(rect.height)
        let amount = pixels(cover.coverAmount, canvas: canvas)
        let effect: String
        switch cover.kind {
        case .mosaic:
            let cell = max(2, Int(amount.rounded()))
            effect = "pixelize=w=\(cell):h=\(cell):mode=avg"
        default:
            effect = "gblur=sigma=\(VideoEditExportGraph.fmt(amount)):steps=\(gaussianSteps)"
        }
        let original = nextLabel("v"), copy = nextLabel("v"), region = nextLabel("v"), output = nextLabel("v")
        let start = VideoEditExportGraph.fmt(max(0, cover.timelineStart))
        let end = VideoEditExportGraph.fmt(min(total, cover.timelineEnd))
        return ([
            "[\(input)]split[\(original)][\(copy)]",
            "[\(copy)]crop=\(w):\(h):\(x):\(y),\(effect)[\(region)]",
            // format=auto：两路同一种像素格式就原样出，不悄悄换成 yuv420（调色之后是 gbrp）。
            "[\(original)][\(region)]overlay=x=\(x):y=\(y):format=auto:eof_action=pass:enable='between(t,\(start),\(end))'[\(output)]"
        ], output)
    }

    /// 把一串盖一块接到 `video` 后面（数组顺序：先加的先盖）。
    static func append(
        _ covers: [ShapeAnnotation], canvas: CGSize, total: Double,
        video: inout String, filters: inout [String], nextLabel: (String) -> String
    ) {
        for cover in covers {
            guard let step = steps(cover, canvas: canvas, total: total, input: video, nextLabel: nextLabel) else { continue }
            filters += step.filters
            video = step.output
        }
    }
}
