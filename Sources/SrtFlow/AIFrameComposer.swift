import AVFoundation
import CoreImage
import Foundation
import ImageIO
import SrtFlowCore
import SwiftUI

// MARK: - 时间线在某一刻的画面（「看」用）
//
// 管什么：按预览同样的几层合成一帧：视频轨（预览那份合成：摆放、裁切、转场、渐变、藏起来的不画）→ 滤镜
// （预览那串 CIFilter）→ 盖一块（模糊 / 马赛克，`CoverCompositing`：AI 盖了之后靠它核对盖没盖住）→ 形状（导出那份 PNG）→ 文字（唯一的绘制入口 TextRenderer）→ 字幕（预览那个
// SwiftUI 视图，离屏渲）。层序同导出滤镜链（docs/architecture/text-overlays.md）。**每一层都调现成的那一份，
// 不另写**：「看」到的就是用户在预览里看到的。
// 不管什么：素材文件的帧（AIFrameSampler）、描述画面（AIFrameDescription）、拼成一张（AIContactSheet）。
//
// 合成自己建一份（`VideoEditCompositionBuilder.build`，和预览同一个函数），不借播放器上挂着的那一份：AI 刚改完
// 就来看时，预览的重建可能还在防抖里，挂着的是改之前的样子。

enum AIFrameComposer {
    /// 时间线在这几个时刻的画面，每一帧都是画布那么大。
    static func frames(of state: TimelineState, at times: [Double], subtitleStyle: BurnInStyle) async throws -> [AIFrameSampler.Frame] {
        let canvas = VideoEditCompositionBuilder.renderSize(for: state)
        let built = await VideoEditCompositionBuilder.build(from: state)
        // 合成被判无效时播放器一帧都不画，取帧器也只会给黑底：那不是素材黑，是 SrtFlow 的 bug。以前这里照样
        // 把黑帧交给 Vision，描述成「夜空」（2026-09-29 婚礼工程，指令表空出一格那次）。报错，别装作看见了。
        if let built, let video = built.videoComposition {
            let whole = CMTimeRange(start: .zero, duration: built.composition.duration)
            let valid = (try? await video.isValid(for: built.composition, timeRange: whole, validationDelegate: nil)) ?? false
            guard valid else {
                throw AIToolError(
                    "SrtFlow could not render the timeline: its preview composition is invalid, so the preview would be "
                        + "black. This is a SrtFlow bug, not the footage; save the project and report it."
                )
            }
        }
        let generator = built.map { built -> AVAssetImageGenerator in
            let generator = AVAssetImageGenerator(asset: built.composition)
            generator.videoComposition = built.videoComposition
            // 半帧：取到的就是这一刻显示的那一帧，又不必逐帧精确解码。
            let half = CMTime(seconds: 0.5 / Double(max(1, state.frameRate.fps)), preferredTimescale: 6000)
            generator.requestedTimeToleranceBefore = half
            generator.requestedTimeToleranceAfter = half
            return generator
        }
        var frames: [AIFrameSampler.Frame] = []
        for time in times {
            var video: CGImage?
            if let generator, time < state.duration {
                video = try? await generator.image(at: CMTime(seconds: max(0, time), preferredTimescale: 600)).image
            }
            let subtitles = await MainActor.run { subtitleImages(state, at: time, canvas: canvas, style: subtitleStyle) }
            let still = video
            let composed = await MediaReadQueue.run(on: MediaReadQueue.analysis) {
                compose(video: still, subtitles: subtitles, state: state, time: time, canvas: canvas)
                    .map { AIFrameSampler.Frame(time: time, image: $0) }
            }
            if let composed { frames.append(composed) }
        }
        return frames
    }

    /// 把几层叠成一帧（同步，在 `MediaReadQueue.analysis` 上跑：CoreImage 渲染要等 GPU）。
    private static func compose(
        video: CGImage?, subtitles: [CGImage], state: TimelineState, time: Double, canvas: CGSize
    ) -> CGImage? {
        let width = Int(canvas.width), height = Int(canvas.height)
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        let whole = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(whole)
        if let video {
            let covered = CoverCompositing.apply(state.renderedCovers.filter { $0.contains(time: time) }, to: graded(video, stack: FilterStack(in: state, at: time)))
            context.draw(covered, in: whole)
        }
        // 形状：导出那份整幅透明 PNG（位置和预览一致）。
        for shape in state.renderedShapes where shape.contains(time: time) {
            if let data = ShapePNGRenderer.render(shape, canvas: canvas), let image = decode(data) {
                context.draw(image, in: whole)
            }
        }
        // 文字：压在形状之上、字幕之下；时刻先钉到工程帧的网格上（预览和导出的唯一入口）。
        let quantized = TextAnimator.quantize(time, frameRate: state.frameRate)
        for overlay in state.renderedTextOverlays where overlay.contains(time: time) {
            let animation = TextAnimator.state(for: overlay, at: quantized, canvas: canvas, frameRate: state.frameRate)
            guard let text = TextRenderer.render(overlay, canvas: canvas, state: animation) else { continue }
            // RenderedText 的落点是左上原点，CG 是左下原点。
            context.draw(text.image, in: CGRect(
                x: text.origin.x, y: canvas.height - text.origin.y - text.size.height,
                width: text.size.width, height: text.size.height
            ))
        }
        for subtitle in subtitles { context.draw(subtitle, in: whole) }
        return context.makeImage()
    }

    /// 此刻的调色：预览挂在播放器上的就是这串 CIFilter（`FilterStack.ciFilters`），定义域同一个色彩空间。
    private static func graded(_ image: CGImage, stack: FilterStack) -> CGImage {
        let filters = stack.ciFilters()
        guard !filters.isEmpty else { return image }
        // 帧自己带着色彩空间；查表的定义域由滤镜的 inputColorSpace 管（同预览）。
        var output = CIImage(cgImage: image)
        for filter in filters {
            filter.setValue(output, forKey: kCIInputImageKey)
            guard let next = filter.outputImage else { return image }
            output = next
        }
        return gradingContext.createCGImage(
            output, from: CGRect(x: 0, y: 0, width: image.width, height: image.height),
            format: .RGBA8, colorSpace: FilterLUT.workingColorSpace
        ) ?? image
    }

    private static let gradingContext = CIContext(options: [
        .workingColorSpace: FilterLUT.workingColorSpace, .outputColorSpace: FilterLUT.workingColorSpace
    ])

    private static func decode(_ png: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// 此刻的字幕：预览上画字幕的那个视图（`BurnInSubtitleOverlay`），按画布像素离屏渲一张透明图。
    @MainActor
    private static func subtitleImages(_ state: TimelineState, at time: Double, canvas: CGSize, style: BurnInStyle) -> [CGImage] {
        let scale = canvas.height / Double(BurnInStyle.referenceHeight)
        return state.subtitleScreenBlocks().compactMap { block in
            guard let display = block.display(at: time) else { return nil }
            let renderer = ImageRenderer(content: BurnInSubtitleOverlay(
                text: display.text, style: style, scale: scale, boxSize: canvas, layout: block.layout,
                highlights: display.highlights, highlight: block.highlight
            ))
            renderer.scale = 1
            renderer.isOpaque = false
            return renderer.cgImage
        }
    }
}
