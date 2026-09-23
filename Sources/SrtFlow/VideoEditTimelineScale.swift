import Foundation
import SrtFlowCore

// MARK: - 深度缩放的两份纯值：标尺刻度、缩略图网格
//
// 2026-09-23 缩放上限从 120 抬到 4800pt/秒之后，标尺要能细到帧、缩略图要能按可见
// 范围铺格子。两样的「算」都放在这里（不 import SwiftUI），自检编得动它；画在
// `VideoEditTimelineRuler.swift` / `VideoEditTimelineThumbnails.swift`。
// 合同见 docs/architecture/audio-waveform.md。

/// 标尺的一档刻度：主刻度多长（秒）、中间分几小格、标签带不带帧号。纯值，自检够得着。
struct RulerScale: Equatable {
    var major: Double
    var minorCount: Int
    var showsFrames: Bool

    /// 相邻两个标签至少隔多远（pt），不然会叠在一起。
    static let minimumLabelSpacing = 76.0

    /// 按缩放挑最细、但标签不打架的那一档。一秒以下按**帧**分档（1 / 2 / 5 / 10 帧、
    /// 半秒），一秒以上按秒。
    static func pick(pps: Double, frameRate: ProjectFrameRate) -> RulerScale {
        let frame = frameRate.secondsPerFrame
        let fps = frameRate.fps
        let candidates: [RulerScale] = [
            RulerScale(major: frame, minorCount: 1, showsFrames: true),
            RulerScale(major: 2 * frame, minorCount: 2, showsFrames: true),
            RulerScale(major: 5 * frame, minorCount: 5, showsFrames: true),
            RulerScale(major: 10 * frame, minorCount: 10, showsFrames: true),
            RulerScale(major: Double(fps / 2) * frame, minorCount: fps / 2 >= 10 ? 5 : fps / 2, showsFrames: true),
            RulerScale(major: 1, minorCount: 5, showsFrames: false),
            RulerScale(major: 2, minorCount: 4, showsFrames: false),
            RulerScale(major: 5, minorCount: 5, showsFrames: false),
            RulerScale(major: 10, minorCount: 5, showsFrames: false),
            RulerScale(major: 30, minorCount: 6, showsFrames: false),
            RulerScale(major: 60, minorCount: 6, showsFrames: false),
            RulerScale(major: 120, minorCount: 4, showsFrames: false),
            RulerScale(major: 300, minorCount: 5, showsFrames: false),
            RulerScale(major: 600, minorCount: 5, showsFrames: false),
        ]
        return candidates.first { $0.major * pps >= minimumLabelSpacing } ?? candidates[candidates.count - 1]
    }

    /// 刻度标签：`mm:ss`，按帧分档时 `mm:ss:ff`（ff = 这一秒里的第几帧）。
    func label(_ seconds: Double, frameRate: ProjectFrameRate) -> String {
        let fps = frameRate.fps
        // 先换成整帧再拆，免得 0.9999… 秒被截成上一秒。
        let frames = Int((seconds * Double(fps)).rounded())
        let whole = frames / fps
        let base = String(format: "%02d:%02d", whole / 60, whole % 60)
        return showsFrames ? base + String(format: ":%02d", frames % fps) : base
    }
}

/// 缩放区间与步长（工具栏按钮、滑块、捏合共用这一份，入口是
/// `VideoEditProject.setPixelsPerSecond`）。
///
/// 上限 2026-09-23 从 120 抬到 4800（24fps 下一帧约 200pt）：放大是为了看清声音、
/// 在字与字之间下刀、画音量曲线。再往上没有意义 —— 预览合成的时间刻度是 1/600 秒，
/// 到这儿剪点已经不能更细。
enum VideoEditZoom {
    static let range: ClosedRange<Double> = 4...4800
    /// 工具栏放大 / 缩小一下乘除多少。区间有 1200 倍宽，1.5 倍一步从最小到最大十几下。
    static let step = 1.5
}

/// 缩略图每一格取哪一帧：按网格对齐，缩放时尽量还是同一张图。
enum ThumbnailGrid {
    /// 网格步长：不小于一帧；比一帧粗时取 2 的整数次幂秒。
    /// 缩放时网格只在翻倍 / 减半时才变，格子大多还是同一张图 —— 按连续的格宽取的话，
    /// 捏合缩放的每一拍都要把整屏缩略图重取一遍。
    static func step(forSecondsPerTile seconds: Double, frameRate: Double) -> Double {
        let frame = 1 / max(1, frameRate)
        guard seconds > frame else { return frame }
        return pow(2, (log2(seconds)).rounded(.up))
    }

    /// 网格上这一格的代表时刻（格子中点，免得落在帧的边界上两头跳）。
    static func snap(_ time: Double, step: Double) -> Double {
        ((time / step).rounded(.down) + 0.5) * step
    }
}
