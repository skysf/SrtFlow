import CoreGraphics
import Foundation

// MARK: - 叠在画面上的图怎么进导出的滤镜图（形状、文字）
//
// 管什么：形状和文字渲出来的 PNG 在导出里的三种接法（单张拉成持续的流 / 序列播一遍 / 序列循环）、序列末尾多渲一帧，
// 以及按叠放次序一层层 overlay 到画面上。
// 不管什么：图里画什么、怎么切段（`ShapeOverlayExport` / `TextOverlayExport`），画面本身（`ShapePNGRenderer` / `TextRenderer`）。
// 2026-10-03 从 VideoEditTextExport.swift 和 VideoEditExportGraph.swift 拆出来：形状有了入场 / 出场动画也要逐帧序列，
// 两份接法只留这一份（docs/architecture/shapes.md、text-overlays.md「导出：只逐帧渲动画进行中的那段」）。

/// 一层叠加（一段形状 / 文字切出来的一个片段）。
struct OverlayExportFile {
    enum Source {
        /// 单张 PNG：`-loop 1` 拉成持续的流。
        case still
        /// PNG 序列播一遍：`-itsoffset` 推到落点。
        case sequence(frames: Int)
        /// PNG 序列无限循环：只有一个周期的帧，`loop` 滤镜铺满整段。
        case looping(frames: Int)
    }

    /// 单张是文件名，序列是 `printf` 模式（`text0-in_%05d.png`）。
    var pattern: String
    var source: Source
    /// 位图左上角在输出画面上的像素位置（可以是负的：文字探出画面；形状是整幅画布，恒为 0）。
    var origin: CGPoint
    var timelineStart: Double
    var timelineEnd: Double

    /// 序列末尾多渲一帧。
    ///
    /// 实测：序列的最后一帧落在 `end - 1/fps`，而 `enable` 的区间一直开到 `end`；那之间的输出帧会撞上输入流的 EOF，
    /// `eof_action=pass` 当场把这一层整个撤掉 —— 动画最后一帧闪一下没了。多渲一帧就把这个缝堵上了。
    static let sequenceTailFrames = 1

    /// 播一遍的序列要渲几帧：区间里的每一帧，再多一帧。
    static func sequenceFrameCount(span: Double, fps: Double) -> Int {
        max(1, Int(ceil(max(0, span) * fps)) + sequenceTailFrames)
    }

    /// 按给的顺序（= 叠放次序：先形状、后文字）一层层贴到 `video` 上。三种接法的实测依据：
    ///   · 单张：`-loop 1` 拉成持续流。
    ///   · 一次性序列：`-itsoffset` 把序列推到落点，帧与时间线精确对齐。
    ///   · 循环段：只有一个周期的帧，`loop` 滤镜铺满，`setpts` 补回时间轴。
    static func append(
        _ files: [OverlayExportFile], fps: Double, total: Double,
        inputArguments: inout [String], inputs: inout [String],
        video: inout String, filters: inout [String], nextLabel: (String) -> String
    ) {
        let fmt = VideoEditExportGraph.fmt
        for file in files {
            let stream: String
            switch file.source {
            case .still:
                inputArguments += ["-loop", "1", "-t", fmt(total), "-i", file.pattern]
                stream = "\(inputs.count):v"
                inputs.append(file.pattern)

            case .sequence:
                inputArguments += [
                    "-itsoffset", fmt(file.timelineStart),
                    "-framerate", fmt(fps), "-start_number", "0", "-i", file.pattern
                ]
                stream = "\(inputs.count):v"
                inputs.append(file.pattern)

            case .looping(let frames):
                inputArguments += ["-framerate", fmt(fps), "-start_number", "0", "-i", file.pattern]
                let index = inputs.count
                inputs.append(file.pattern)
                let looped = nextLabel("tl")
                // `loop` 之后 PTS 要自己重建（N 是帧序号），再整体推到落点。
                filters.append(
                    "[\(index):v]loop=loop=-1:size=\(frames):start=0," +
                    "setpts=N/\(fmt(fps))/TB+\(fmt(file.timelineStart))/TB[\(looped)]"
                )
                stream = looped
            }

            let outV = nextLabel("v")
            filters.append(
                "[\(video)][\(stream)]overlay=x=\(fmt(file.origin.x)):y=\(fmt(file.origin.y))" +
                ":eof_action=pass:enable='between(t,\(fmt(file.timelineStart)),\(fmt(file.timelineEnd)))'[\(outV)]"
            )
            video = outV
        }
    }
}
