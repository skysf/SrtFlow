import CoreGraphics
import Foundation

// MARK: - 铺满时对准谁（纯值）
//
// 管什么：几帧画面里认出来的人脸 / 人 / 显眼的东西（Vision 给的框）→ 铺满时窗的中心该对准源画面上哪一点，
// 以及主体在这一段里走动得多不多（走动大了，一个固定的窗跟不住，要告诉 AI）。纯值，自检够得着
// （scripts/check-mcp.sh）。
// 不管什么：框从哪来（AIVision）、窗怎么算（AIFrameFit）。
//
// 口径：
// - 每一帧先看人脸，没有人脸看人（上半身），都没有看「显眼的东西」（注意力显著区）。
// - 几张脸 / 几个人：合起来放得进窗就对准它们合起来的中心，放不进就对准最大的那一个（说话的人通常最大）。
// - 几帧合起来取**中位数**（一两帧认错不带偏），种类取出现最多的那种。
// - 坐标一律是源画面上的归一化值，左上原点。

enum AISubjectFocus {
    enum Kind: String, Equatable {
        case face, person, salient
    }

    /// 一帧里认出来的东西（框都是归一化、左上原点）。
    struct FrameFindings: Equatable {
        var faces: [CGRect] = []
        var people: [CGRect] = []
        var salient: [CGRect] = []
    }

    struct Result: Equatable {
        var point: CGPoint
        var kind: Kind
        /// 有几帧认出了东西。
        var frames: Int
        /// 各帧对准的点横向差得最远的两帧之间隔多少（归一化）。
        var spreadX: Double
        var spreadY: Double
    }

    /// 一帧该对准哪儿。`window`：铺满的那扇窗有多大（归一化宽高），用来判断几张脸放不放得下。
    static func focus(in frame: FrameFindings, window: CGSize) -> (point: CGPoint, kind: Kind)? {
        if let point = aim(at: frame.faces, window: window) { return (point, .face) }
        if let point = aim(at: frame.people, window: window) { return (point, .person) }
        if let first = frame.salient.first { return (CGPoint(x: first.midX, y: first.midY), .salient) }
        return nil
    }

    /// 几帧合起来。一帧都没认出东西 → nil（调用方照正中铺）。
    static func combine(_ frames: [FrameFindings], window: CGSize) -> Result? {
        let aims = frames.compactMap { focus(in: $0, window: window) }
        guard !aims.isEmpty else { return nil }
        let xs = aims.map { Double($0.point.x) }.sorted()
        let ys = aims.map { Double($0.point.y) }.sorted()
        var counts: [Kind: Int] = [:]
        for aim in aims { counts[aim.kind, default: 0] += 1 }
        let order: [Kind] = [.face, .person, .salient]
        let kind = order.max { (counts[$0] ?? 0) < (counts[$1] ?? 0) } ?? .salient
        return Result(
            point: CGPoint(x: median(xs), y: median(ys)), kind: kind, frames: aims.count,
            spreadX: (xs.last ?? 0) - (xs.first ?? 0), spreadY: (ys.last ?? 0) - (ys.first ?? 0)
        )
    }

    /// 主体走动得多：各帧对准的点散开超过窗的一半，一个固定的窗会把它甩出画面。
    static func movesTooMuch(_ result: Result, window: CGSize) -> Bool {
        result.spreadX > window.width / 2 || result.spreadY > window.height / 2
    }

    private static func aim(at boxes: [CGRect], window: CGSize) -> CGPoint? {
        guard let largest = boxes.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        let union = boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }
        if union.width <= window.width, union.height <= window.height {
            return CGPoint(x: union.midX, y: union.midY)
        }
        return CGPoint(x: largest.midX, y: largest.midY)
    }

    private static func median(_ sorted: [Double]) -> Double {
        let count = sorted.count
        guard count > 0 else { return 0.5 }
        return count % 2 == 1 ? sorted[count / 2] : (sorted[count / 2 - 1] + sorted[count / 2]) / 2
    }
}
