import CoreGraphics
import Foundation
import SrtFlowMCPKit

// MARK: - 看一段素材的画面：黑边、主体在哪
//
// 管什么：edit_clip 要「去黑边」「铺满时对准主体」时，从这一段用到的那一截里抽几帧（AIFrameSampler），
// 交给纯值的规则算（AIBlackBars、AISubjectFocus；认主体用 Vision，AIVision），再把看到的写成 AI 读得懂的
// 一小段 JSON。
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

    /// 这一段的主体在哪（铺满时窗对准它）。`window`：铺满的窗有多大（归一化），判断几张脸放不放得下。
    /// 一帧都没认出东西 → nil（照正中铺）。
    static func subject(of clip: EditClip, window: CGSize) async -> AISubjectFocus.Result? {
        let frames = await AIFrameSampler.frames(of: clip, count: sampleCount, maxSide: 640)
        var findings: [AISubjectFocus.FrameFindings] = []
        for frame in frames {
            findings.append(await AIVision.analyze(frame.image, .subject).subject)
        }
        return AISubjectFocus.combine(findings, window: window)
    }

    static func json(_ subject: AISubjectFocus.Result?, window: CGSize) -> JSONValue {
        guard let subject else { return "none found: filled around the centre" }
        var object: [String: JSONValue] = [
            "kind": .string(subject.kind.rawValue),
            "x": AIFormat.seconds(subject.point.x), "y": AIFormat.seconds(subject.point.y),
            "seen_in_frames": .number(Double(subject.frames))
        ]
        if AISubjectFocus.movesTooMuch(subject, window: window) {
            object["note"] = .string(
                "The subject moves around in this clip, so one fixed crop may lose it. "
                + "Split the clip where it moves and fill each part, or check with look."
            )
        }
        return .object(object)
    }
}
