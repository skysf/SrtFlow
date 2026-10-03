import CoreGraphics
import Foundation
import SrtFlowCore

// MARK: - 形状的导出落点
//
// 管什么：把每一块形状渲成整幅透明 PNG 写进导出的工作目录，切成几段告诉导出图怎么叠（接法是 `OverlayExportFile`，文字同一份）。
// 不管什么：画面本身（`ShapePNGRenderer`，和预览、AI 的「看」同一份路径）、动画求值（`ShapeAnimator`）、盖一块（不画东西）。
//
// 和文字同一个切法（docs/architecture/text-overlays.md「导出：只逐帧渲动画进行中的那段」）：没有动画的整段一张图；
// 有动画的只逐帧渲入场和出场那两截，中间画面一帧都没变，一张图 + 一个时间区间。一段 5 秒、入场出场各 0.6 秒的圆环，
// 30fps 下渲 2 × 19 帧 + 1 张，不是 150 帧。

enum ShapeOverlayExport {
    /// 顺序 = `shapes` 的顺序 = 叠放次序；同一块的几个片段按时间先后排。渲不出来的跳过。
    static func renderFiles(
        _ shapes: [ShapeAnnotation], canvas: CGSize,
        frameRate: ProjectFrameRate, into workspace: URL
    ) throws -> [OverlayExportFile] {
        var files: [OverlayExportFile] = []
        for (index, shape) in shapes.enumerated() {
            files += try renderOne(shape, index: index, canvas: canvas, frameRate: frameRate, into: workspace)
        }
        return files
    }

    private static func renderOne(
        _ shape: ShapeAnnotation, index: Int, canvas: CGSize,
        frameRate: ProjectFrameRate, into workspace: URL
    ) throws -> [OverlayExportFile] {
        guard !shape.animation.isEmpty else {
            // 没有动画：整段一张图（文件名和以前一样）。
            guard try writeStill(shape, name: "shape\(index).png", canvas: canvas, into: workspace) else { return [] }
            return [OverlayExportFile(
                pattern: "shape\(index).png", source: .still, origin: .zero,
                timelineStart: shape.timelineStart, timelineEnd: shape.timelineEnd
            )]
        }

        let window = shape.animation.window(span: shape.duration)
        let middleStart = shape.timelineStart + window.fadeIn
        // FadeWindow 保证入场 + 出场不超过段长，这里再夹一下免得两段在时间上重叠（同一刻贴两张图会变浓）。
        let middleEnd = max(middleStart, shape.timelineEnd - window.fadeOut)
        var files: [OverlayExportFile] = []
        if window.fadeIn > 0 {
            files += try writeSequence(shape, name: "shape\(index)-in", from: shape.timelineStart, to: middleStart,
                                       canvas: canvas, frameRate: frameRate, into: workspace)
        }
        if middleEnd > middleStart + 0.0005,
           try writeStill(shape, name: "shape\(index)-mid.png", canvas: canvas, into: workspace) {
            files.append(OverlayExportFile(
                pattern: "shape\(index)-mid.png", source: .still, origin: .zero,
                timelineStart: middleStart, timelineEnd: middleEnd
            ))
        }
        if window.fadeOut > 0 {
            files += try writeSequence(shape, name: "shape\(index)-out", from: middleEnd, to: shape.timelineEnd,
                                       canvas: canvas, frameRate: frameRate, into: workspace)
        }
        return files
    }

    /// 不动的一张（没有动画的整段，或者动画中间那截）。
    private static func writeStill(_ shape: ShapeAnnotation, name: String, canvas: CGSize, into workspace: URL) throws -> Bool {
        guard let png = ShapePNGRenderer.render(shape, canvas: canvas) else { return false }
        try png.write(to: workspace.appendingPathComponent(name))
        return true
    }

    /// 入场或出场那一截，逐帧渲。时刻先钉到工程帧的网格上（预览同一把尺子：`TextAnimator.quantize`）。
    private static func writeSequence(
        _ shape: ShapeAnnotation, name: String, from: Double, to: Double,
        canvas: CGSize, frameRate: ProjectFrameRate, into workspace: URL
    ) throws -> [OverlayExportFile] {
        let fps = Double(max(1, frameRate.fps))
        let count = OverlayExportFile.sequenceFrameCount(span: to - from, fps: fps)
        var written = 0
        for frame in 0..<count {
            let time = TextAnimator.quantize(from + Double(frame) / fps, frameRate: frameRate)
            guard let png = ShapePNGRenderer.render(shape, canvas: canvas, state: ShapeAnimator.state(for: shape, at: time)) else { break }
            try png.write(to: workspace.appendingPathComponent(String(format: "%@_%05d.png", name, frame)))
            written += 1
        }
        // 序列中间断了一帧，ffmpeg 读到断号就当序列结束 —— 宁可整截不要，也不交一截半路停住的动画。
        guard written == count else { return [] }
        return [OverlayExportFile(
            pattern: "\(name)_%05d.png", source: .sequence(frames: count), origin: .zero,
            timelineStart: from, timelineEnd: to
        )]
    }
}
