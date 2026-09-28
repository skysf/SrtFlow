import CoreGraphics
import Foundation
import SrtFlowMCPKit

// MARK: - 看一段素材的画面：黑边、主体在哪
//
// 管什么：edit_clip 要「去黑边」「铺满时对准主体（主体走动就跟着走）」时，从这一段用到的那一截里抽帧（AIFrameSampler），
// 交给纯值的规则算（AIBlackBars、AISubjectFocus、AIFollowSubject；认主体用 Vision，AIVision），再把看到的写成 AI 读得懂的
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

    /// 每秒两帧、至少 5 帧、最多 30 帧：固定的窗取中位数 5 帧就够，跟拍要看得出主体怎么走（第四块）。
    static func subjectSampleCount(duration: Double) -> Int {
        min(max(Int((duration * 2).rounded()), sampleCount), 30)
    }

    /// 这一段里主体在哪：沿着用到的那一截均匀抽帧，每帧让 Vision 认人脸 / 人 / 显眼的东西（源秒 + 认出来的框）。
    static func subjectSamples(of clip: EditClip) async -> [AIFollowSubject.Sample] {
        let count = clip.isStillImage ? 1 : subjectSampleCount(duration: clip.timelineDuration)
        let frames = await AIFrameSampler.frames(of: clip, count: count, maxSide: 640)
        var samples: [AIFollowSubject.Sample] = []
        for frame in frames {
            samples.append(.init(time: frame.time, findings: await AIVision.analyze(frame.image, .subject).subject))
        }
        return samples
    }

    /// 写给 AI：认出了什么、对准哪；跟拍了就说几个关键帧，没跟但走动大就提醒。
    static func json(_ subject: AISubjectFocus.Result?, window: CGSize, followKeyframes: Int?) -> JSONValue {
        guard let subject else { return "none found: filled around the centre" }
        var object: [String: JSONValue] = [
            "kind": .string(subject.kind.rawValue),
            "x": AIFormat.seconds(subject.point.x), "y": AIFormat.seconds(subject.point.y),
            "seen_in_frames": .number(Double(subject.frames))
        ]
        if let followKeyframes {
            object["follows"] = .number(Double(followKeyframes))
            object["note"] = .string(
                "The subject moves around, so the crop follows it with \(followKeyframes) position keyframes. "
                    + "Pass follow=false for one fixed crop."
            )
        } else if AISubjectFocus.movesTooMuch(subject, window: window) {
            object["note"] = .string(
                "The subject moves around in this clip, so one fixed crop may lose it. "
                    + "Leave follow on to follow it with keyframes, or split the clip where it moves."
            )
        }
        return .object(object)
    }
}
