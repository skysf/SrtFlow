import CoreGraphics
import Foundation
import SrtFlowMCPKit

// MARK: - 看一段素材的画面：黑边
//
// 管什么：edit_clip 要「去黑边」时，从这一段用到的那一截里抽几帧（AIFrameSampler），交给纯值的规则
// 算（AIBlackBars），再把看到的写成 AI 读得懂的一小段 JSON。
// 不管什么：裁切怎么算（AIFrameFit）、改工程（AIClipTools / AIClipEdit）。

enum AIPictureProbe {
    /// 抽几帧：5 帧够分辨「一直黑的遮幅」和「某一帧碰巧暗」，又不慢（小图，一共一两百毫秒）。
    static let sampleCount = 5

    /// 这一段的黑边。nil = 看不出来（抽不到帧，或者抽到的全是黑场）；`.none` = 看了，没有黑边。
    static func blackBars(of clip: EditClip) async -> AIBlackBars.Insets? {
        let frames = await AIFrameSampler.frames(of: clip, count: sampleCount, maxSide: 320)
        return AIBlackBars.combine(frames.map { frame in
            AIBlackBars.luma(of: frame.image).flatMap(AIBlackBars.bars(in:))
        })
    }

    static func json(_ bars: AIBlackBars.Insets?) -> JSONValue {
        guard let bars else { return "could not tell: the sampled frames were black or unreadable" }
        guard !bars.isEmpty else { return "none" }
        return [
            "top": AIFormat.seconds(bars.top), "bottom": AIFormat.seconds(bars.bottom),
            "left": AIFormat.seconds(bars.left), "right": AIFormat.seconds(bars.right)
        ]
    }
}
