import Foundation

// MARK: - 送去 upscale 的范围（纯值）
//
// 管什么：一个原片在当前工程里被哪些画面段用到（原片时间轴上的区间）、用户三选一（这一段 / 工程里最长的那处 / 整个文件）
// 之后到底送哪一段（两头各留余料、对齐到整帧、夹在文件两头之内）、面板上「另一处用了更长的范围」的提示要的数。
// 用户 2026-10-02 拍的板（docs/plans/2026-10-02-video-upscale.md 第 2、5 条）：带余料；同一个原片在当前工程里用到的地方都换，
// 只选了短的那处时提示另一处用了更长的范围、建议直接做最长的那段。
// 不管什么：裁文件（UpscaleSourceTrimmer）、换源（ClipSourceSwap）。

/// 一个画面段在原片时间轴上用到的区间。
struct UpscaleUse: Equatable, Sendable {
    var clipID: UUID
    var start: Double
    var duration: Double
    var end: Double { start + duration }
}

enum UpscaleRangeChoice: Equatable, Sendable {
    /// 只做点开面板的这一段。
    case thisClip
    /// 工程里用这个原片最长的那一处（面板的默认）。
    case longestUse
    case wholeFile
}

struct UpscaleRange: Equatable, Sendable {
    /// 两头各留的余料（秒）：主轨转场最多借 2 秒，往外拖一点也要有帧。
    static let handle = 1.0

    /// 原片时间轴上要送去的区间（已含余料、已对齐到整帧、已夹在文件两头之内）。
    var start: Double
    var end: Double
    var duration: Double { end - start }

    /// 这个区间盖住的用处（换源时就是这些段会换）。
    var coveredClipIDs: [UUID]

    /// 用户选的那一段 / 那一处，不含余料（面板上写「用了 3.0 s」）。
    var chosen: UpscaleUse?

    /// 按选择算范围。`uses` 是这个原片在工程里的全部用处（`TimelineState.clipIDs(usingPicture:)` 换算到原片时间）。
    static func make(
        _ choice: UpscaleRangeChoice, thisClip: UUID, uses: [UpscaleUse], fileDuration: Double, frameRate: Double
    ) -> UpscaleRange {
        let frame = frameRate > 0 ? 1 / frameRate : 1 / 24
        func aligned(_ raw: ClosedRange<Double>) -> UpscaleRange {
            // 两头各留余料，起点往下对到整帧、终点往上对到整帧，再夹进文件里。
            let start = max(0, ((raw.lowerBound - handle) / frame).rounded(.down) * frame)
            let end = min(fileDuration, ((raw.upperBound + handle) / frame).rounded(.up) * frame)
            let covered = uses.filter { $0.start >= start - ClipUpscaleRecord.frameSlack && $0.end <= end + ClipUpscaleRecord.frameSlack }.map(\.clipID)
            return UpscaleRange(start: start, end: max(start, end), coveredClipIDs: covered, chosen: nil)
        }
        switch choice {
        case .wholeFile:
            return UpscaleRange(start: 0, end: fileDuration, coveredClipIDs: uses.map(\.clipID), chosen: nil)
        case .thisClip:
            guard let use = uses.first(where: { $0.clipID == thisClip }) else {
                return UpscaleRange(start: 0, end: fileDuration, coveredClipIDs: uses.map(\.clipID), chosen: nil)
            }
            var range = aligned(use.start...use.end)
            range.chosen = use
            return range
        case .longestUse:
            guard let longest = longestUse(uses) else {
                return UpscaleRange(start: 0, end: fileDuration, coveredClipIDs: uses.map(\.clipID), chosen: nil)
            }
            var range = aligned(longest.start...longest.end)
            range.chosen = longest
            return range
        }
    }

    /// 用得最长的那一处（一样长取先出现的）。
    static func longestUse(_ uses: [UpscaleUse]) -> UpscaleUse? {
        uses.max { a, b in a.duration < b.duration || (a.duration == b.duration && a.clipID.uuidString > b.clipID.uuidString) }
    }

    /// 面板上的提示：用户点开的这一段之外，工程里还有没有用得更长的一处（有就建议直接做那一处）。
    static func longerUseElsewhere(thisClip: UUID, uses: [UpscaleUse]) -> UpscaleUse? {
        guard let mine = uses.first(where: { $0.clipID == thisClip }), let longest = longestUse(uses) else { return nil }
        return longest.clipID != mine.clipID && longest.duration > mine.duration + 0.001 ? longest : nil
    }
}
