import Foundation

// MARK: - 播放跟随：时间线什么时候滚、滚到哪（纯值）
//
// 管什么：播放中播放头快滚出视口时，时间线横向滚到哪。翻页式：播放头走到视口右边 80pt 以内
//（或左边 40pt 以内）才推一下，推到视口左侧 15% 的位置，后面还留着一大段能看；平时不跟着走
//（每帧都居中会看得人晕）。开关关着（默认，2026-10-01 用户拍板）什么都不推：播放头可以走出视口，
// 停下来也不滚回来。
// 不管什么：什么时候调（TimelinePlayheadLines 在时钟每一跳调，只在播放中）、怎么滚和夹到
// 滚得动的范围（TimelineScrollGeometry）。
// 不 import AppKit：scripts/check-timeline-zoom.sh 单独编它。

enum PlayheadFollow {
    /// 视口左右各留多宽算「快滚出去了」。
    static let leftMargin = 40.0
    static let rightMargin = 80.0
    /// 推完之后播放头落在视口的几成处。
    static let landing = 0.15

    /// 要推就给出横向滚动量（内容坐标，可能是负的 —— 由滚动几何夹住），不推给 nil。
    static func scrollTarget(playheadX x: Double, offsetX: Double, viewportWidth: Double, enabled: Bool) -> Double? {
        guard enabled, viewportWidth > rightMargin else { return nil }
        let leftEdge = offsetX + leftMargin
        let rightEdge = offsetX + viewportWidth - rightMargin
        guard x < leftEdge || x > rightEdge else { return nil }
        return x - viewportWidth * landing
    }
}
