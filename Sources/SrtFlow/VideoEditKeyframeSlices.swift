import Foundation
import SrtFlowCore

// MARK: - 关键帧动画在预览合成里的切片时刻（纯值）
//
// 管什么：一段画面的关键帧动画要在哪些时间线时刻断片。片内一切都线性（setTransformRamp / setOpacityRamp），所以：
//   1. 每个关键帧处断一片（位置 / 缩放 / 不透明度的直线段两端取值就是精确重建）；
//   2. 旋转相邻帧之间按 ≤ 6°/片加密（矩阵线性插值走弦不走弧，角度大了明显缩水变形）；
//   3. **带缓动的段按帧加密**（曲线靠密集折线逼近，每片两端的值落在曲线上；线性段一片不多）；
//   4. 不透明度动画 × 转场衰减是二次曲线，转场窗口内按 0.1 s 加密。
//   一段（相邻两帧之间）最多 400 片：十几圈的疯转、十几秒的慢推宁可略糙，别把指令表撑爆。
// 为什么单独成文件：2026-09-30 加缓动时从 VideoEditCompositionBuilder 拆出来（那个文件登记在基线里只许降），
// 这份纯值自检也够得着（checks/PreviewComposition 数片、量亮度）。
// 不管什么：边界落格子去重（CompositionSlices）、片里怎么求值（builder 自己）、导出（预渲染用同一份合成）。
// 长期约束：docs/architecture/keyframe-animation.md「预览切片」「缓动」。

enum KeyframeSliceTimes {
    /// 旋转相邻两帧之间每片最多转多少度。
    static let maximumDegreesPerSlice = 6.0
    /// 一段（相邻两帧之间）最多切多少片。
    static let maximumSlicesPerSegment = 400

    /// 要断片的时间线时刻（含每个关键帧那一刻；段的起止不在这里，调用方按开区间收）。
    /// `fadeWindows`：这段开头 / 结尾的转场衰减窗口（时间线秒），不透明度有动画时在窗口里按 0.1 s 加密。
    static func times(
        animation: ClipAnimation, clip: EditClip, frameRate: ProjectFrameRate,
        fadeWindows: [(start: Double, end: Double)]
    ) -> [Double] {
        var times: [Double] = []
        // source 空间去重容差含 speed（见 KeyframeTrack.sourceTolerance）
        let keyTolerance = KeyframeTrack.sourceTolerance(frameRate: frameRate, speed: clip.speed)
        for sourceTime in animation.allKeyTimes(tolerance: keyTolerance) {
            times.append(clip.timelineTime(atSource: sourceTime))
        }

        let frameStep = 1.0 / Double(max(1, frameRate.fps))
        func densify(_ track: KeyframeTrack, degrees: Bool) {
            guard track.keys.count >= 2 else { return }
            for index in 1..<track.keys.count {
                let a = track.keys[index - 1], b = track.keys[index]
                let start = clip.timelineTime(atSource: a.time), end = clip.timelineTime(atSource: b.time)
                var steps = degrees ? Int((abs(b.value - a.value) / maximumDegreesPerSlice).rounded(.up)) : 1
                if a.easing != .linear { steps = max(steps, Int((abs(end - start) / frameStep).rounded(.up))) }
                steps = min(maximumSlicesPerSegment, steps)
                guard steps > 1 else { continue }
                for step in 1..<steps { times.append(start + (end - start) * Double(step) / Double(steps)) }
            }
        }
        densify(animation.centerX, degrees: false)
        densify(animation.centerY, degrees: false)
        densify(animation.width, degrees: false)
        densify(animation.height, degrees: false)
        densify(animation.rotation, degrees: true)
        densify(animation.opacity, degrees: false)

        if !animation.opacity.isEmpty {
            for window in fadeWindows {
                var t = window.start
                while t < window.end {
                    times.append(t)
                    t += 0.1
                }
            }
        }
        return times
    }
}
