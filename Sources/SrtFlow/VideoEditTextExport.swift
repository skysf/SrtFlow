import CoreGraphics
import Foundation
import ImageIO
import SrtFlowCore
import UniformTypeIdentifiers

// MARK: - 文字的导出落点
//
// 画面本身**一个像素都不在这里画** —— 全部来自 `TextRenderer.render`，与预览
// 同一个函数。这里只管把它切成几段、渲成 PNG、告诉调用方每段怎么进滤镜图。
//
// ## 只逐帧渲动画进行中的那段
//
// 一段 5 秒的标题，入场 0.6s + 出场 0.6s，中间 3.8 秒画面**一帧都没变** ——
// 那 3.8 秒渲成一张图 + 一个时间区间就够了，只有两头的 1.2 秒需要逐帧。
// 30fps 下这是 37 帧 vs 150 帧。
//
// ## 循环动画只渲一个周期
//
// 呼吸是周期性的，整段逐帧渲会随文字时长线性膨胀 —— 10 分钟的呼吸文字能写出
// 几个 GB，把磁盘撑爆。所以中间那段只渲**一个周期**，交给 ffmpeg 的 `loop`
// 滤镜铺满。为此周期必须是**整数帧**（`TextAnimation.breathePeriod(frameRate:)`
// 按帧率取整），否则循环接缝处相位会错开，看起来像卡了一下。
//
// ## 位图尺寸全程固定
//
// 每一帧都按**整段动画的包络**渲（`TextAnimator.envelopeAllowance`），
// 于是 overlay 的 x/y 是一个常数。按当帧算的话尺寸每帧都变，贴图位置得跟着改，
// 动画会抖。

enum TextOverlayExport {

    /// 一段文字在导出里的一个片段。
    struct File {
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
        /// 位图左上角在输出画面上的像素位置（可以是负的：文字探出画面）。
        var origin: CGPoint
        var timelineStart: Double
        var timelineEnd: Double
    }

    /// 序列末尾多渲一帧。
    ///
    /// 实测：序列的最后一帧落在 `end - 1/fps`，而 `enable` 的区间一直开到
    /// `end`；那之间的输出帧会撞上输入流的 EOF，`eof_action=pass` 当场把文字
    /// 整个撤掉 —— 动画最后一帧闪一下没了。多渲一帧就把这个缝堵上了。
    private static let sequenceTailFrames = 1

    /// 把所有文字渲成 PNG 写进工作目录。空文字和渲不出来的直接跳过。
    ///
    /// 顺序 = `overlays` 的顺序 = 叠放次序；同一段文字的几个片段按时间先后排。
    static func renderFiles(
        _ overlays: [TextOverlay], canvas: CGSize,
        frameRate: ProjectFrameRate, into workspace: URL
    ) throws -> [File] {
        var files: [File] = []
        for (index, overlay) in overlays.enumerated() {
            files += try renderOne(overlay, index: index, canvas: canvas,
                                   frameRate: frameRate, into: workspace)
        }
        return files
    }

    private static func renderOne(
        _ overlay: TextOverlay, index: Int, canvas: CGSize,
        frameRate: ProjectFrameRate, into workspace: URL
    ) throws -> [File] {
        let animation = overlay.animation
        let span = overlay.duration

        guard overlay.needsPerFrameRendering else {
            guard let still = try writeStill(
                overlay, at: overlay.timelineStart, name: "text\(index).png",
                canvas: canvas, frameRate: frameRate, into: workspace
            ) else { return [] }
            return [File(
                pattern: "text\(index).png", source: .still, origin: still,
                timelineStart: overlay.timelineStart, timelineEnd: overlay.timelineEnd
            )]
        }

        let window = animation.window(span: span)
        let start = overlay.timelineStart
        // 头部逐帧的长度是「入场动画」和「数字滚动」里更长的那个 ——
        // 数字滚完之前画面每一帧都在变，只按入场时长切的话，滚动的后半截
        // 会被冻成一张静止图。
        let head = overlay.animatedHead(window: window)
        let middleStart = start + head
        // 头和尾加起来可能超过整段（滚动比入场长时），夹一下免得两段在时间上
        // 重叠 —— 重叠的话同一刻会贴两张图，文字会明显变浓。
        let middleEnd = max(middleStart, overlay.timelineEnd - window.fadeOut)
        var files: [File] = []

        if head > 0 {
            files += try writeSequence(
                overlay, name: "text\(index)-in", from: start, to: middleStart,
                canvas: canvas, frameRate: frameRate, looping: false, into: workspace
            )
        }
        if middleEnd > middleStart + 0.0005 {
            if animation.emphasis == .none {
                // 中间画面一帧都没变：一张图 + 一个时间区间。
                if let origin = try writeStill(
                    overlay, at: middleStart, name: "text\(index)-mid.png",
                    canvas: canvas, frameRate: frameRate, into: workspace
                ) {
                    files.append(File(
                        pattern: "text\(index)-mid.png", source: .still, origin: origin,
                        timelineStart: middleStart, timelineEnd: middleEnd
                    ))
                }
            } else {
                files += try writeSequence(
                    overlay, name: "text\(index)-mid", from: middleStart, to: middleEnd,
                    canvas: canvas, frameRate: frameRate, looping: true, into: workspace
                )
            }
        }
        if window.fadeOut > 0 {
            files += try writeSequence(
                overlay, name: "text\(index)-out", from: middleEnd, to: overlay.timelineEnd,
                canvas: canvas, frameRate: frameRate, looping: false, into: workspace
            )
        }
        return files
    }

    // MARK: - 落盘

    /// 单帧。返回贴图落点；渲不出来返回 nil（调用方据此整段跳过）。
    private static func writeStill(
        _ overlay: TextOverlay, at time: Double, name: String,
        canvas: CGSize, frameRate: ProjectFrameRate, into workspace: URL
    ) throws -> CGPoint? {
        let state = TextAnimator.state(
            for: overlay,
            at: TextAnimator.quantize(time, frameRate: frameRate),
            canvas: canvas, frameRate: frameRate
        )
        guard let rendered = TextRenderer.render(overlay, canvas: canvas, state: state),
              let data = pngData(rendered.image) else { return nil }
        try data.write(to: workspace.appendingPathComponent(name))
        return rendered.origin
    }

    /// 一段逐帧序列。`looping` 时只渲一个呼吸周期。
    private static func writeSequence(
        _ overlay: TextOverlay, name: String, from: Double, to: Double,
        canvas: CGSize, frameRate: ProjectFrameRate, looping: Bool, into workspace: URL
    ) throws -> [File] {
        let fps = Double(max(1, frameRate.fps))
        let span = max(0, to - from)
        let count: Int
        if looping {
            // 循环段只渲一个周期，且周期必须是整数帧 —— 否则接缝处相位错开。
            let period = TextAnimation.breathePeriod(frameRate: frameRate)
            count = max(1, min(Int((period * fps).rounded()), Int(ceil(span * fps))))
        } else {
            count = max(1, Int(ceil(span * fps)) + sequenceTailFrames)
        }

        var origin: CGPoint?
        for frame in 0..<count {
            let time = from + Double(frame) / fps
            let state = TextAnimator.state(
                for: overlay,
                at: TextAnimator.quantize(time, frameRate: frameRate),
                canvas: canvas, frameRate: frameRate
            )
            guard let rendered = TextRenderer.render(overlay, canvas: canvas, state: state),
                  let data = pngData(rendered.image) else { continue }
            try data.write(to: workspace.appendingPathComponent(
                String(format: "%@_%05d.png", name, frame)
            ))
            // 包络是整段动画算出来的，每一帧都一样 —— 取第一帧的就够。
            if origin == nil { origin = rendered.origin }
        }
        guard let origin else { return [] }
        return [File(
            pattern: "\(name)_%05d.png",
            source: looping ? .looping(frames: count) : .sequence(frames: count),
            origin: origin,
            timelineStart: from,
            timelineEnd: to
        )]
    }

    private static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
