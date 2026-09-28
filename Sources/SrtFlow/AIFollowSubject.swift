import CoreGraphics
import Foundation

// MARK: - 跟拍：主体走动时，铺满的那扇窗跟着它走（纯值）
//
// 管什么：一段里每秒两帧认出来的主体（AISubjectFocus 的口径：人脸 → 人 → 显眼的东西）→ 要不要跟 →
// 窗中心的一串点（平滑过、精简过）→ 裁切 + 摆放框 + 摆放框中心的关键帧。第四块「横竖屏转换按人脸裁」
// （方案第 11 条）；第二块只有固定的窗、走动大了只提醒（第二块报告的已知不足）。
// 口径：
// - **只跟人脸和人**：「显眼的东西」一帧一跳（2026-09-28 冒烟：企鹅那段没人脸，窗从最左甩到最右），它只用来定固定的窗。
//   大半的帧（`seenShare`）认出了人、而且散开超过窗宽 / 窗高的 `followOver` 才跟：走动小的一个固定的窗就框得住，
//   不打关键帧（主轨上带关键帧的段导出时要先渲一遍中间片，能不打就不打）。
// - 素材里有切点（换镜头）：每个镜头各自平滑、各自精简，在切点前一帧和切点上各打一个关键帧 —— 跳过去，不从上一个镜头
//   平移过去（同一次冒烟：企鹅那段中间有一刀）。
// - 前后 `smoothingSeconds` 秒的平均抹掉 Vision 一帧一帧的抖动；再用 RDP 精简，只留转折处的点（摆放框中心的
//   关键帧之间是直线插值，所以精简到 `simplifyTolerance` 以内，画面几乎一样，关键帧少很多）。
// - **裁切不能做关键帧**（docs/architecture/keyframe-animation.md），所以裁切固定成盖住所有窗的那一块，
//   窗怎么走全靠摆放框的中心走：窗左上角在源画面的 (wx, wy) 时，中心 = ((K.midX − wx) / W, (K.midY − wy) / H)
//   （K = 裁剩的那块，W × H = 窗的大小）—— 只有一个点时就是 AIFrameFit.fill 那个固定的窗。
// 不管什么：帧从哪来、认主体（AIPictureProbe / AIVision）、写进段（AIClipEdit）。

enum AIFollowSubject {
    static let followOver = 0.3
    /// 至少这么多帧认出了人（人脸或上半身）才跟。
    static let seenShare = 0.6
    static let smoothingSeconds = 0.75
    static let simplifyTolerance = 0.015

    struct Sample {
        /// 源秒。
        var time: Double
        var findings: AISubjectFocus.FrameFindings
    }

    struct Point: Equatable {
        var time: Double
        var center: CGPoint
    }

    /// 每个样本对准哪：只认人脸和人（没认出人的那几帧，沿用前后最近认出人的那一帧）；`seen` = 认出人的帧数。
    /// 一帧都没认出人 → 空。
    static func targets(_ samples: [Sample], window: CGSize) -> (points: [Point], seen: Int) {
        let aims: [CGPoint?] = samples.map { sample in
            guard let aim = AISubjectFocus.focus(in: sample.findings, window: window), aim.kind != .salient else { return nil }
            return aim.point
        }
        let seen = aims.filter { $0 != nil }.count
        guard seen > 0 else { return ([], 0) }
        let points = samples.indices.map { index in
            let nearest = aims.indices
                .filter { aims[$0] != nil }
                .min { abs($0 - index) < abs($1 - index) } ?? index
            return Point(time: samples[index].time, center: aims[nearest] ?? CGPoint(x: 0.5, y: 0.5))
        }
        return (points, seen)
    }

    /// 要不要跟：大半的帧认出了人，而且人横向或纵向散开超过窗的 `followOver`。
    static func needsFollow(_ targets: (points: [Point], seen: Int), window: CGSize) -> Bool {
        guard !targets.points.isEmpty, Double(targets.seen) >= seenShare * Double(targets.points.count),
              let spread = spread(targets.points) else { return false }
        return spread.x > window.width * followOver || spread.y > window.height * followOver
    }

    /// 平滑 + 精简 + 夹在窗能到的范围里（窗出不了 `active`）→ 窗中心的关键帧点。`cuts`：这一段素材里换镜头的
    /// 源秒 —— 每个镜头各算各的，切点前 `frame` 秒和切点上各一个关键帧（跳过去）。
    static func path(_ targets: [Point], window: CGSize, active: CGRect, cuts: [Double] = [], frame: Double = 1.0 / 30) -> [Point] {
        let bounds = cuts.sorted().filter { cut in targets.contains { $0.time < cut } && targets.contains { $0.time >= cut } }
        var segments: [[Point]] = []
        var rest = targets
        for cut in bounds {
            segments.append(rest.filter { $0.time < cut })
            rest = rest.filter { $0.time >= cut }
        }
        segments.append(rest)
        var result: [Point] = []
        for (index, segment) in segments.enumerated() where !segment.isEmpty {
            let smoothed = segment.map { point in
                let near = segment.filter { abs($0.time - point.time) <= smoothingSeconds }
                let x = near.map { Double($0.center.x) }.reduce(0, +) / Double(near.count)
                let y = near.map { Double($0.center.y) }.reduce(0, +) / Double(near.count)
                return Point(time: point.time, center: clamp(CGPoint(x: x, y: y), window: window, active: active))
            }
            var simplified = simplify(smoothed, tolerance: simplifyTolerance)
            if index > 0, let previous = result.last, let first = simplified.first {
                let cut = bounds[index - 1]
                result.append(Point(time: cut - frame, center: previous.center))
                simplified.insert(Point(time: cut, center: first.center), at: 0)
            }
            result += simplified
        }
        return result
    }

    /// 窗中心的一串点 → 裁切（盖住所有的窗）+ 静态摆放框（第一个点那一刻）+ 每个点的摆放框中心（`follow`）。
    static func framing(_ path: [Point], window: CGSize) -> AIFrameFit.Framing? {
        guard !path.isEmpty, window.width > 0, window.height > 0 else { return nil }
        let origins = path.map { CGPoint(x: $0.center.x - window.width / 2, y: $0.center.y - window.height / 2) }
        let union = CGRect(
            x: origins.map(\.x).min() ?? 0, y: origins.map(\.y).min() ?? 0,
            width: (origins.map(\.x).max() ?? 0) - (origins.map(\.x).min() ?? 0) + window.width,
            height: (origins.map(\.y).max() ?? 0) - (origins.map(\.y).min() ?? 0) + window.height
        )
        let crop = AIFrameFit.crop(keeping: union)
        let kept = AIFrameFit.region(of: crop)
        let centers = zip(path, origins).map { point, origin in
            Point(time: point.time, center: CGPoint(
                x: (kept.midX - origin.x) / window.width, y: (kept.midY - origin.y) / window.height
            ))
        }
        let placement = ClipPlacement(
            centerX: Double(centers[0].center.x), centerY: Double(centers[0].center.y),
            width: Double(kept.width / window.width), height: Double(kept.height / window.height)
        )
        return AIFrameFit.Framing(crop: crop, placement: placement, replacesMotion: true, follow: centers)
    }

    // MARK: 内部

    private static func spread(_ points: [Point]) -> (x: Double, y: Double)? {
        guard !points.isEmpty else { return nil }
        let xs = points.map { Double($0.center.x) }
        let ys = points.map { Double($0.center.y) }
        return ((xs.max() ?? 0) - (xs.min() ?? 0), (ys.max() ?? 0) - (ys.min() ?? 0))
    }

    private static func clamp(_ point: CGPoint, window: CGSize, active: CGRect) -> CGPoint {
        let halfW = window.width / 2
        let halfH = window.height / 2
        return CGPoint(
            x: min(max(point.x, active.minX + halfW), active.maxX - halfW),
            y: min(max(point.y, active.minY + halfH), active.maxY - halfH)
        )
    }

    /// Ramer–Douglas–Peucker：按时间把点连成折线，离直线不到 `tolerance` 的中间点去掉（首尾留着）。
    static func simplify(_ points: [Point], tolerance: Double) -> [Point] {
        guard points.count > 2, let first = points.first, let last = points.last else { return points }
        var farthest = 0
        var distance = 0.0
        for index in 1..<(points.count - 1) {
            let point = points[index]
            let t = last.time > first.time ? (point.time - first.time) / (last.time - first.time) : 0
            let x = Double(first.center.x) + (Double(last.center.x) - Double(first.center.x)) * t
            let y = Double(first.center.y) + (Double(last.center.y) - Double(first.center.y)) * t
            let off = max(abs(Double(point.center.x) - x), abs(Double(point.center.y) - y))
            if off > distance {
                distance = off
                farthest = index
            }
        }
        guard distance > tolerance else { return [first, last] }
        let left = simplify(Array(points[...farthest]), tolerance: tolerance)
        let right = simplify(Array(points[farthest...]), tolerance: tolerance)
        return left.dropLast() + right
    }
}
