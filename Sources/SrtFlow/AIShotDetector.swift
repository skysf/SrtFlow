import Foundation

// MARK: - 镜头在哪切（纯值）
//
// 管什么：一串缩小的画面（每帧几十 × 几十像素的 RGB）→ 相邻两帧差多少（「内容变化」，0…1）→ 在哪几帧换了镜头 →
// 几个镜头（源秒的起止）。第四块「本机识别画面」的镜头切换点（方案第 11 条）；look 的 shots 从这里拿。
// 口径学 PySceneDetect 的 AdaptiveDetector（开源镜头检测的事实标准）：
// - 相邻两帧逐像素 RGB 差的平均（画面缩到几十像素，噪点和细小的动作被抹平）；
// - 一帧的变化要**同时**够大（≥ `minimumChange`）又明显高出前后几帧的平均（≥ `adaptiveRatio` 倍）才算切 ——
//   摇镜头、人走动时每一帧都在变、平均也高，不算；硬切只有那一帧突然跳；
// - 连着几帧都在变、又不到 `maxTransition` 秒（擦除、推移这类几帧的转场）：整串算一刀，切在变得最多的那一帧、
//   拿这一串前后的平均来比（2026-09-28 在课程视频上试出来的：只比相邻帧，切点会落到转场的末尾，差 0.2 秒）；
// - 暗下去又亮起来（淡出淡入、黑场过渡）：在最暗那一截的正中切一刀；
// - 两刀之间至少 `minimumShot` 秒（闪光、一两帧的抖动不切碎）。
// 叠化（两个镜头慢慢交叠）认不出来，照一个镜头算（已知不足）。
// 不管什么：帧从哪来、缓存（AIShotScan）、怎么写给 AI（AILookShots）。

enum AIShotDetector {
    /// 一帧至少变这么多才可能是切点（PySceneDetect 的 min_content_val 15 / 255）。
    static let minimumChange = 0.06
    /// 比前后 `window` 帧的平均变化高出这么多倍才算切（PySceneDetect 的 adaptive_threshold）。
    static let adaptiveRatio = 3.0
    static let window = 2
    /// 连着变的一串不超过这么长（秒）算一个转场；更长的是摇镜头、走动。
    static let maxTransition = 0.5
    /// 两刀之间至少多少秒。
    static let minimumShot = 0.6
    /// 平均亮度（0…1）低于它算「暗」：黑场、淡出到底。
    static let darkLevel = 0.06

    struct Shot: Equatable, Sendable {
        var start: Double
        var end: Double
    }

    /// 相邻两帧的变化：逐像素 RGB（每像素三个字节）差的平均，0…1。长度不同（换了尺寸）算全变。
    static func change(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var total = 0
        for index in a.indices { total += abs(Int(a[index]) - Int(b[index])) }
        return Double(total) / Double(a.count) / 255
    }

    /// 平均亮度 0…1（RGB 按 Rec.601 加权）。
    static func brightness(_ rgb: [UInt8]) -> Double {
        guard rgb.count >= 3 else { return 0 }
        var total = 0.0
        var index = 0
        while index + 2 < rgb.count {
            total += 0.299 * Double(rgb[index]) + 0.587 * Double(rgb[index + 1]) + 0.114 * Double(rgb[index + 2])
            index += 3
        }
        return total / Double(rgb.count / 3) / 255
    }

    /// 哪几帧开始一个新镜头（下标，升序）。`changes[i]` 是第 i 帧相对上一帧的变化（第 0 帧随便），
    /// `brightness[i]` 是第 i 帧的平均亮度，`times[i]` 是它的源秒。
    static func cutIndices(changes: [Double], brightness: [Double], times: [Double]) -> [Int] {
        let count = min(changes.count, times.count)
        guard count > 1 else { return [] }
        let changes = Array(changes.prefix(count))
        var candidates = Set<Int>()
        var first = 1
        while first < count {
            guard changes[first] >= minimumChange else {
                first += 1
                continue
            }
            var last = first
            while last + 1 < count, changes[last + 1] >= minimumChange { last += 1 }
            if times[last] - times[first] <= maxTransition {
                // 一刀，或者几帧的转场：整串算一刀，切在变得最多的那一帧。
                let peak = (first...last).max { changes[$0] < changes[$1] } ?? first
                if changes[peak] >= adaptiveRatio * max(surrounding(changes, first, last), 1e-6) { candidates.insert(peak) }
            } else {
                // 很长一串都在变（摇镜头、走动）：只认比前后几帧高出一截的那一帧。
                for frame in first...last where changes[frame] >= adaptiveRatio * max(surrounding(changes, frame, frame), 1e-6) {
                    candidates.insert(frame)
                }
            }
            first = last + 1
        }
        for index in darkMiddles(brightness: Array(brightness.prefix(count))) { candidates.insert(index) }
        var cuts: [Int] = []
        for index in candidates.sorted() where index > 0 {
            let since = times[index] - (cuts.last.map { times[$0] } ?? times[0])
            guard since >= minimumShot else { continue }
            guard times[count - 1] - times[index] >= minimumShot / 2 else { continue }
            cuts.append(index)
        }
        return cuts
    }

    /// [first, last] 这一串前后各 `window` 帧的平均变化（不含这一串；第 0 帧没有「上一帧」，不算）。
    private static func surrounding(_ changes: [Double], _ first: Int, _ last: Int) -> Double {
        let before = max(1, first - window)..<first
        let after = (last + 1)..<min(changes.count, last + 1 + window)
        let values = before.map { changes[$0] } + after.map { changes[$0] }
        return values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    /// 暗下去又亮起来的每一截的正中（两头都有亮的画面才算：片头片尾的黑不是镜头之间的过渡）。
    static func darkMiddles(brightness: [Double]) -> [Int] {
        var middles: [Int] = []
        var runStart: Int?
        for (index, level) in brightness.enumerated() {
            if level < darkLevel {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                if start > 0 { middles.append((start + index) / 2) }
                runStart = nil
            }
        }
        return middles
    }

    /// 只要 `range` 里的那些镜头，两头裁到区间里（被区间切掉一截的照样留着，只是短了）。
    static func shots(_ shots: [Shot], within range: ClosedRange<Double>) -> [Shot] {
        shots.compactMap { shot in
            let start = max(shot.start, range.lowerBound)
            let end = min(shot.end, range.upperBound)
            return end - start > 0.01 ? Shot(start: start, end: end) : nil
        }
    }

    /// 一页：从 `from` 起（结束在 `from` 之后的第一个镜头开始）最多 `size` 个，编号从 1 起按全部镜头数；
    /// 后面还有就给下一页从哪起（下一个镜头的开始）。
    static func page(_ shots: [Shot], from: Double?, size: Int) -> (items: [(number: Int, shot: Shot)], next: Double?) {
        let first = from.map { from in shots.firstIndex { $0.end > from + 0.001 } ?? shots.count } ?? 0
        let last = min(shots.count, first + max(1, size))
        let items = (first..<last).map { (number: $0 + 1, shot: shots[$0]) }
        return (items, last < shots.count ? shots[last].start : nil)
    }

    /// 切点（源秒）→ 镜头：第一个从 `from` 开始，最后一个到 `to` 为止。
    static func shots(cutTimes: [Double], from: Double, to: Double) -> [Shot] {
        var edges = [from]
        edges += cutTimes.filter { $0 > from && $0 < to }.sorted()
        edges.append(to)
        return zip(edges, edges.dropFirst()).compactMap { $1 > $0 ? Shot(start: $0, end: $1) : nil }
    }
}
