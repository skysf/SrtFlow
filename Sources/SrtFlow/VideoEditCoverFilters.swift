import CoreImage
import Foundation

// MARK: - 盖一块用的 CIFilter（预览和 AI 的「看」共用）
//
// 管什么：一块盖一块（模糊 / 马赛克）在 CoreImage 里是哪几个滤镜、什么参数。预览的第二层播放器把它们挂到图层上
// （`CoverHostView`），AI 的「看」合成一帧时把它们跑在整幅图上（`CoverCompositing`）—— 两处都问这一个函数，
// 不各拼一份。导出走 ffmpeg 的滤镜（`VideoEditCoverExport`），和这里按构造一致：**裁出这一块、在这一块里做效果、边缘往外延、贴回去**。
// 不管什么：怎么挂到图层上（VideoEditCoverPreview）、怎么合成一帧（AIFrameComposer）、导出（VideoEditCoverExport）。

enum CoverFilters {

    /// - Parameters:
    ///   - kind: `.blur` 高斯模糊，`.mosaic` 马赛克（其余种类不是盖一块，返回空）。
    ///   - amount: 力度换算到**这块画面的单位**之后：模糊的半径（高斯的标准差）/ 马赛克每一格的边长。预览的图层滤镜按点、
    ///     「看」的合成按像素 —— 都是 `1080p 基准的力度 × 画面高 / 1080`（`ShapeKind.coverAmountRange`）。
    ///   - regionHeight: 这一块的高（同一个单位）：CIPixellate 的格子要从这一块的**左上角**起算（默认是从左下角）。
    static func ciFilters(kind: ShapeKind, amount: Double, regionHeight: Double) -> [CIFilter] {
        guard kind.isCover, amount > 0 else { return [] }
        var filters: [CIFilter] = []
        // 边缘往外延：不然模糊 / 取平均会把块外面的透明也算进来，块边上一圈发暗（导出的 gblur 也是边缘外延）。
        if let clamp = CIFilter(name: "CIAffineClamp") {
            clamp.setValue(NSAffineTransform(), forKey: kCIInputTransformKey)
            filters.append(clamp)
        }
        switch kind {
        case .mosaic:
            if let pixellate = CIFilter(name: "CIPixellate") {
                pixellate.setValue(max(1, amount), forKey: kCIInputScaleKey)
                // inputCenter 是格子的一个角点（实测：水平方向的格线落在 x = 0, 12, 24…）；定在左上角，格子从那儿起算，和导出一样。
                pixellate.setValue(CIVector(x: 0, y: regionHeight), forKey: kCIInputCenterKey)
                filters.append(pixellate)
            }
        default:
            if let blur = CIFilter(name: "CIGaussianBlur") {
                blur.setValue(amount, forKey: kCIInputRadiusKey)
                filters.append(blur)
            }
        }
        return filters
    }
}
