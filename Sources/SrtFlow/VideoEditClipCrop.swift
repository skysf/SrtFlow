import CoreGraphics
import Foundation

// MARK: - 画面段的四边裁切
//
// 管什么：`EditClip.crop` 这个纯值 —— 四边各裁多少、在给定尺寸上的裁切矩形、按比例居中裁，以及存盘格式。
// 不管什么：裁完的画面怎么摆（`ClipPlacement`）、预览 / 导出怎么真裁（各自的管线）。
// 2026-09-26 从 VideoEditModels.swift 拆出来（那个文件在行数基线里只许降，见 docs/architecture/coding-standards.md）。

/// 画面段的四边裁切：每边裁掉源画面（按显示方向）的归一化比例，0…0.45。
/// 裁完剩下的画面填进摆放框；默认摆放框本身也按裁后的宽高比算。
struct ClipCrop: Hashable, Sendable {
    var top: Double
    var bottom: Double
    var leading: Double
    var trailing: Double

    init(top: Double = 0, bottom: Double = 0, leading: Double = 0, trailing: Double = 0) {
        self.top = min(max(top, 0), 0.45)
        self.bottom = min(max(bottom, 0), 0.45)
        self.leading = min(max(leading, 0), 0.45)
        self.trailing = min(max(trailing, 0), 0.45)
    }

    var isEmpty: Bool {
        top < 0.0005 && bottom < 0.0005 && leading < 0.0005 && trailing < 0.0005
    }

    /// 在给定显示尺寸上的裁切矩形（像素）。
    func rect(in display: CGSize) -> CGRect {
        CGRect(
            x: leading * display.width,
            y: top * display.height,
            width: max(1, display.width * (1 - leading - trailing)),
            height: max(1, display.height * (1 - top - bottom))
        )
    }

    /// 把源画面居中裁到目标宽高比（Inspector 里的比例预设）。
    static func centered(aspect: Double, in display: CGSize) -> ClipCrop {
        guard display.width > 0, display.height > 0, aspect > 0 else { return ClipCrop() }
        let current = display.width / display.height
        if current > aspect {
            // 太宽：裁左右。
            let keep = aspect / current
            let inset = (1 - keep) / 2
            return ClipCrop(leading: inset, trailing: inset)
        } else {
            // 太高：裁上下。
            let keep = current / aspect
            let inset = (1 - keep) / 2
            return ClipCrop(top: inset, bottom: inset)
        }
    }
}

extension ClipCrop: Codable {
    private enum CodingKeys: String, CodingKey {
        case top, bottom, leading, trailing
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            top: try c.decodeIfPresent(Double.self, forKey: .top) ?? 0,
            bottom: try c.decodeIfPresent(Double.self, forKey: .bottom) ?? 0,
            leading: try c.decodeIfPresent(Double.self, forKey: .leading) ?? 0,
            trailing: try c.decodeIfPresent(Double.self, forKey: .trailing) ?? 0
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(top, forKey: .top)
        try c.encode(bottom, forKey: .bottom)
        try c.encode(leading, forKey: .leading)
        try c.encode(trailing, forKey: .trailing)
    }
}
