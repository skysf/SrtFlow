import Foundation
import SrtFlowCore

// MARK: - 形状标注的模型
//
// 管什么：画在画面上的形状（线条 / 长方形 / 正方形）和「盖一块」（模糊 / 马赛克）的数据、宽容解码与存盘。
// 不管什么：形状怎么画（预览 `ShapeOverlayCanvas`、导出 `ShapePNGRenderer`）、盖一块怎么盖（预览 `CoverPreviewLayer`、
// 导出 `VideoEditCoverExport`）、时间线上的形状块。
// 从 VideoEditModels.swift 拆出来（那个文件在行数基线里只许降，见 docs/architecture/coding-standards.md）。

/// 画在画面上的形状：线条、长方形、正方形；以及盖一块（模糊、马赛克）。
enum ShapeKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case line
    case rectangle
    case square
    /// 盖一块（2026-09-29，MCP 方案第 56 条）：**不画东西**，把它下面的画面（主轨 + 上层轨合成之后、调色之后）模糊或打马赛克，
    /// 遮水印、遮烧进去的旧字幕。长方形的几何，和形状共用时间线上的块、选中框、拖动、V 隐藏、复制粘贴；
    /// 但**不算总长**（同滤镜段：一块盖在空白上没有意义）、不进 `renderedShapes`（那是「画出来的」）。
    case blur
    case mosaic

    /// 是不是盖一块。预览、导出、总长、时间线上的块各问它，不各判一份。
    var isCover: Bool { self == .blur || self == .mosaic }

    /// 盖一块的力度：模糊的半径（高斯的标准差）/ 马赛克每一格的边长，按 1080p 基准的像素数。
    /// 默认值：一行 40 像素高的字，模糊半径 28 时糊到认不出、马赛克格子 22 时只剩两格高。
    static let coverAmountRange = 2.0...80.0
    var defaultCoverAmount: Double { self == .mosaic ? 22 : 28 }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .line: return "Line"
        case .rectangle: return "Rectangle"
        case .square: return "Square"
        case .blur: return "Blur"
        case .mosaic: return "Mosaic"
        }
    }

    var icon: String {
        switch self {
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .square: return "square"
        case .blur: return "drop"
        case .mosaic: return "square.grid.3x3"
        }
    }
}

/// 一条形状标注。位置和大小都是相对输出画面的 0…1 归一化值，
/// 预览（SwiftUI 绘制）和导出（渲成 PNG 叠加）用同一套坐标，所见即所得。
struct ShapeAnnotation: Identifiable, Hashable, Sendable {
    let id: UUID
    var kind: ShapeKind

    var timelineStart: Double
    var duration: Double

    var color: SubtitleColor
    /// 描边宽度，按 1080p 基准的像素数。
    var lineWidth: Double

    var centerX: Double
    var centerY: Double
    /// 线条：width 是长度，height 无用；正方形：两者取 width。
    var width: Double
    var height: Double
    /// 只对线条有意义：顺时针角度（度）。
    var rotationDegrees: Double
    /// 单个藏起来（选中按 V，2026-09-26 用户拍板）：时间线上灰显、仍可编辑，预览和成片里都没有。
    /// 和剪辑的 `EditClip.isHidden` 同一条语义（docs/architecture/clip-visibility.md）。v22 字段，按需写键。
    var isHidden = false
    /// 实心：长方形、正方形整块涂满颜色，不画描边（电影遮幅、色块底、面板；2026-09-28 MCP 第 5 块补的零件）。
    /// 线条没有这个概念，恒为 false。v24 字段，按需写键。
    var isFilled = false
    /// 盖一块的力度（模糊的半径 / 马赛克每格的边长，1080p 基准像素）。只对 blur / mosaic 有意义，别的种类不写。v26 字段。
    var coverAmount = 28.0
    /// 用户打在这一块上的标记（离块起点多少秒；裁头时留在原来的时间线时刻）。只影响编辑期的显示，
    /// 不进合成和导出。类型与读写见 VideoEditClipMarker.swift。v28 字段，按需写键。
    var markers: [ClipMarker] = []

    /// 这一个真的画成实心（线条永远是线）。预览和导出都问它，不各判一份。
    var drawsFilled: Bool { isFilled && kind != .line }

    init(
        id: UUID = UUID(),
        kind: ShapeKind,
        timelineStart: Double,
        duration: Double = 3,
        color: SubtitleColor = .yellow,
        lineWidth: Double = 6,
        centerX: Double = 0.5,
        centerY: Double = 0.5,
        width: Double = 0.3,
        height: Double = 0.2,
        rotationDegrees: Double = 0,
        coverAmount: Double? = nil
    ) {
        self.id = id
        self.kind = kind
        self.timelineStart = timelineStart
        self.duration = duration
        self.color = color
        self.lineWidth = lineWidth
        self.centerX = centerX
        self.centerY = centerY
        self.width = width
        self.height = kind == .square ? width : height
        self.rotationDegrees = rotationDegrees
        self.coverAmount = coverAmount ?? kind.defaultCoverAmount
    }

    var timelineEnd: Double { timelineStart + duration }

    func contains(time: Double) -> Bool {
        time >= timelineStart && time < timelineEnd
    }

    /// 画布上的外接框（按给定画布尺寸换算）。正方形按画布**宽度**取边长，
    /// 保证在任何比例的画面里都是正的。
    func frame(in canvas: CGSize) -> CGRect {
        let w: Double
        let h: Double
        switch kind {
        case .square:
            w = width * canvas.width
            h = w
        case .rectangle, .blur, .mosaic:
            w = width * canvas.width
            h = height * canvas.height
        case .line:
            w = width * canvas.width
            h = 0
        }
        return CGRect(
            x: centerX * canvas.width - w / 2,
            y: centerY * canvas.height - h / 2,
            width: w,
            height: h
        )
    }
}

// MARK: - 存盘

extension ShapeKind: LenientCodableEnum {
    static var decodingFallback: ShapeKind { .rectangle }
}

extension ShapeAnnotation: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, kind, timelineStart, duration, color, lineWidth
        case centerX, centerY, width, height, rotationDegrees, isHidden, isFilled, coverAmount, markers
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            kind: try c.decodeIfPresent(ShapeKind.self, forKey: .kind) ?? .rectangle,
            timelineStart: try c.decodeIfPresent(Double.self, forKey: .timelineStart) ?? 0,
            duration: try c.decodeIfPresent(Double.self, forKey: .duration) ?? 3,
            color: try c.decodeIfPresent(SubtitleColor.self, forKey: .color) ?? .yellow,
            lineWidth: try c.decodeIfPresent(Double.self, forKey: .lineWidth) ?? 6,
            centerX: try c.decodeIfPresent(Double.self, forKey: .centerX) ?? 0.5,
            centerY: try c.decodeIfPresent(Double.self, forKey: .centerY) ?? 0.5,
            width: try c.decodeIfPresent(Double.self, forKey: .width) ?? 0.3,
            height: try c.decodeIfPresent(Double.self, forKey: .height) ?? 0.2,
            rotationDegrees: try c.decodeIfPresent(Double.self, forKey: .rotationDegrees) ?? 0
        )
        // 缺键 = 没藏：v21 及更早没有这个概念，那时它就是显示的。
        isHidden = try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        // 缺键 = 描边：v23 及更早只有描边。
        isFilled = try c.decodeIfPresent(Bool.self, forKey: .isFilled) ?? false
        // 缺键 = 这个种类的默认力度（v25 及更早没有盖一块）。
        coverAmount = try c.decodeIfPresent(Double.self, forKey: .coverAmount) ?? kind.defaultCoverAmount
        // 缺键 = 没打过标记（v27 及更早形状上打不了）。
        markers = try c.decodeIfPresent([ClipMarker].self, forKey: .markers) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(timelineStart, forKey: .timelineStart)
        try c.encode(duration, forKey: .duration)
        try c.encode(color, forKey: .color)
        try c.encode(lineWidth, forKey: .lineWidth)
        try c.encode(centerX, forKey: .centerX)
        try c.encode(centerY, forKey: .centerY)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(rotationDegrees, forKey: .rotationDegrees)
        // 按需写键：没藏过的形状不落它，没用过 V 的工程照旧能被旧版打开。
        if isHidden { try c.encode(isHidden, forKey: .isHidden) }
        // 同上：只有实心的才落键，两处（这里和 requiresFormatVersion24）同源。
        if isFilled { try c.encode(isFilled, forKey: .isFilled) }
        // 同上：只有盖一块才落键，两处（这里和 requiresFormatVersion26）同源。
        if kind.isCover { try c.encode(coverAmount, forKey: .coverAmount) }
        // 同上：一枚标记都没有的不落键，免得被抬进 v28。
        if !markers.isEmpty { try c.encode(markers, forKey: .markers) }
    }
}
