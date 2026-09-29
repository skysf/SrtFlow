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
// - 每一帧先看人脸，没有人脸看人（上半身），都没有时**字多就对准字**（幻灯片、录屏：三块以上或占画面 2% 以上，
//   2026-09-28 方案第 55 条），再没有看「显眼的东西」（注意力显著区）。`textFirst`（focus=text）只看字。
// - 字比窗宽时对准字合起来的中间，另报宽出去多少（`textCut`）：AI 据此决定要不要改用完整显示。
// - 几张脸 / 几个人：合起来放得进窗就对准它们合起来的中心，放不进就对准最大的那一个（说话的人通常最大）。
// - 几帧合起来取**中位数**（一两帧认错不带偏），种类取出现最多的那种。
// - 坐标一律是源画面上的归一化值，左上原点。

enum AISubjectFocus {
    enum Kind: String, Equatable {
        case face, person, text, salient
    }

    /// 一帧里认出来的东西（框都是归一化、左上原点）。
    struct FrameFindings: Equatable {
        var faces: [CGRect] = []
        var people: [CGRect] = []
        /// 画面上的字（没让 Vision 认字时是空的）。
        var texts: [CGRect] = []
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
        /// 对准字的那几帧里，字合起来比窗大出去多少（按那一边的比例，取中位数）；不是对准字就是 0。
        var textCut: Double = 0
    }

    /// 一帧该对准哪儿。`window`：铺满的那扇窗有多大（归一化宽高），用来判断几张脸放不放得下。
    /// `textFirst`（focus=text）：只看字。
    static func focus(in frame: FrameFindings, window: CGSize, textFirst: Bool = false) -> (point: CGPoint, kind: Kind)? {
        if textFirst { return union(frame.texts).map { (CGPoint(x: $0.midX, y: $0.midY), .text) } }
        if let point = aim(at: frame.faces, window: window) { return (point, .face) }
        if let point = aim(at: frame.people, window: window) { return (point, .person) }
        if isTextHeavy(frame.texts), let box = union(frame.texts) { return (CGPoint(x: box.midX, y: box.midY), .text) }
        if let first = frame.salient.first { return (CGPoint(x: first.midX, y: first.midY), .salient) }
        return nil
    }

    /// 字多到值得对准：三块以上，或者加起来占画面 2% 以上（角落里一行小字、水印不算 —— 那是「有字」，不是「全是字」）。
    static func isTextHeavy(_ texts: [CGRect]) -> Bool {
        texts.count >= 3 || texts.reduce(0) { $0 + $1.width * $1.height } >= 0.02
    }

    /// 几帧合起来。一帧都没认出东西 → nil（调用方照正中铺）。
    static func combine(_ frames: [FrameFindings], window: CGSize, textFirst: Bool = false) -> Result? {
        let aims = frames.compactMap { frame in focus(in: frame, window: window, textFirst: textFirst).map { (frame, $0) } }
        guard !aims.isEmpty else { return nil }
        let xs = aims.map { Double($0.1.point.x) }.sorted()
        let ys = aims.map { Double($0.1.point.y) }.sorted()
        var counts: [Kind: Int] = [:]
        for aim in aims { counts[aim.1.kind, default: 0] += 1 }
        let order: [Kind] = [.face, .person, .text, .salient]
        let kind = order.max { (counts[$0] ?? 0) < (counts[$1] ?? 0) } ?? .salient
        let cuts = aims.filter { $0.1.kind == .text }.map { textCut($0.0.texts, window: window) }.sorted()
        return Result(
            point: CGPoint(x: median(xs), y: median(ys)), kind: kind, frames: aims.count,
            spreadX: (xs.last ?? 0) - (xs.first ?? 0), spreadY: (ys.last ?? 0) - (ys.first ?? 0),
            textCut: kind == .text && !cuts.isEmpty ? median(cuts) : 0
        )
    }

    /// 字合起来比窗大出去多少（宽、高里大的那个比例）：0 = 窗框得下。
    static func textCut(_ texts: [CGRect], window: CGSize) -> Double {
        guard let box = union(texts), box.width > 0, box.height > 0 else { return 0 }
        return max(max(0, box.width - window.width) / box.width, max(0, box.height - window.height) / box.height)
    }

    private static func union(_ boxes: [CGRect]) -> CGRect? {
        guard let first = boxes.first else { return nil }
        return boxes.dropFirst().reduce(first) { $0.union($1) }
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
