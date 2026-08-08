import Foundation

/// 工程帧率：预览、导出、预渲染、关键帧容差的**唯一事实来源**。
///
/// 在此之前这些地方各自写死 30 fps（`VideoEditCompositionBuilder` 的
/// `frameDuration = 1/30`、`VideoEditExporter` 九处滤镜的 `fps=30` / `r=30`、
/// `KeyframeTrack.timeTolerance = 1/60` 也就是「30 fps 的半帧」）。录屏功能要求
/// 24/30/60 可选，这些假设必须统一到本类型上，否则会出现「AI 素材 24 fps、
/// 录屏 30 fps、编辑器内部又按 30 fps」的三套时间基准。
///
/// 放在 SrtFlowCore 而不是 App 层：它是纯逻辑，要能被 `SrtFlowCoreChecks` 覆盖。
/// 因此这里**不引入 CoreMedia** —— `CMTime` 的桥接在 App 层单独提供。
public enum ProjectFrameRate: Int, CaseIterable, Hashable, Sendable {
    case fps24 = 24
    case fps30 = 30
    case fps60 = 60

    /// 默认 24 —— 与计划一致（AI 生成素材的常见帧率）。
    public static let fallback = ProjectFrameRate.fps24

    public var fps: Int { rawValue }

    /// 一帧的时长（秒）。
    public var secondsPerFrame: Double { 1.0 / Double(rawValue) }

    /// 半帧容差（秒）。关键帧的「同一时刻」判定用它。
    ///
    /// 注意旧代码 `KeyframeTrack.timeTolerance = 1/60` 恰好等于 30 fps 的半帧，
    /// 所以 30 fps 工程的行为与迁移前完全一致；24 和 60 才会变。
    public var halfFrameTolerance: Double { 0.5 / Double(rawValue) }

    /// `CMTime` 用的分子/分母（`CMTime(value: 1, timescale: fps)`）。
    /// 分开给出是为了让 Core 层不依赖 CoreMedia。
    public var frameDurationRational: (value: Int64, timescale: Int32) {
        (1, Int32(rawValue))
    }

    public var title: String { "\(rawValue) fps" }
}

extension ProjectFrameRate: Codable {
    /// 宽容解码：认不出的值一律回退到 24，绝不让工程因为一个陌生帧率打不开。
    /// 与仓库既有的 `LenientCodableEnum` 同一取向（那个协议要求 String raw，
    /// 这里是 Int raw，所以内联实现）。
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(Int.self)
        self = ProjectFrameRate(rawValue: raw) ?? .fallback
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

extension ProjectFrameRate: Identifiable {
    public var id: Int { rawValue }
}
