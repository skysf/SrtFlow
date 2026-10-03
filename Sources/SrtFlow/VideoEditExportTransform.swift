import CoreGraphics
import Foundation

// MARK: - 导出里一段画面的 Transform 滤镜链
//
// 管什么：Transform 面板那一套（裁切 → 翻转 → 缩放进摆放框 → 旋转 → 不透明度 → 画面渐变）在 ffmpeg 里的那一串，
// 外加带透明的静帧要先反预乘（静帧是预乘过的 ProRes 4444，`StillAlphaNaming`），主轨和上层轨共用。
// 不管什么：这一段在图里接到哪、和谁叠（`VideoEditExportGraph`）、时间账（trim / setpts 在调用处）。
// 2026-10-03 从 VideoEditExportGraph.swift 拆出来（那个文件在行数基线里只许降，见 docs/architecture/coding-standards.md）。

enum ExportTransformChain {
    /// 摆放框的像素尺寸收成正偶数：yuv420 要偶数，scale 不吃 0。
    private static func evenPixel(_ value: Double) -> Int {
        max(2, Int((value / 2).rounded()) * 2)
    }

    /// Transform 面板的完整滤镜链（接在 fps=<工程帧率> 之后）：
    /// 裁切 → 翻转 → 缩放进摆放框 → 旋转（rgba 透明角）→ 不透明度 → 画面渐变。
    /// 定位用中心表达式 —— 旋转会把输出框撑大（rotw/roth），
    /// 只有中心是不变量。时间账与预览的 fittingTransform 完全同构。
    ///
    /// - Parameter fades: **已经过转场仲裁**的画面渐变窗口（`VideoFade.effective`）。
    ///   渐变挂在链的最末尾，`st` 才对得上时间线秒（见 VideoEditVideoFade.swift）。
    static func steps(
        clip: EditClip,
        renderSize: CGSize,
        fades: FadeWindow
    ) -> (chain: String, overlayX: String, overlayY: String) {
        let target = clip.resolvedPlacement(canvas: renderSize)
            .frame(in: renderSize)
        var steps: [String] = []
        // 带透明的静帧是预乘过的（预览的合成器要的就是预乘），overlay 默认按直通混合：先标明预乘、缩放完再反预乘
        //（在预乘的画面上缩放，边缘不发黑）。ffmpeg 8 起 unpremultiply 看帧上的 alpha_mode，不标它就原样放过去。
        if clip.isAlphaStill { steps.append("setparams=alpha_mode=premultiplied") }
        if let crop = clip.crop, !crop.isEmpty, let display = clip.info?.displaySize {
            let rect = crop.rect(in: display)
            steps.append(
                "crop=\(Int(rect.width.rounded())):\(Int(rect.height.rounded())):" +
                "\(Int(rect.minX.rounded())):\(Int(rect.minY.rounded()))"
            )
        }
        if clip.flippedHorizontally { steps.append("hflip") }
        if clip.flippedVertically { steps.append("vflip") }
        steps.append("scale=\(evenPixel(target.width)):\(evenPixel(target.height))")
        if clip.isAlphaStill { steps.append("unpremultiply=inplace=1") }
        steps.append("setsar=1")
        let rotated = abs(clip.rotationDegrees) > 0.01
        let translucent = clip.opacity < 0.999
        // 渐变是在 alpha 上做的，没有 alpha 通道 `fade=…:alpha=1` 就是空转。
        if rotated || translucent || !fades.isEmpty { steps.append("format=rgba") }
        if rotated {
            let radians = VideoEditExportGraph.fmt(clip.rotationDegrees * .pi / 180)
            steps.append("rotate=\(radians):ow=rotw(\(radians)):oh=roth(\(radians)):c=black@0")
        }
        if translucent { steps.append("colorchannelmixer=aa=\(VideoEditExportGraph.fmt(clip.opacity))") }
        return (
            steps.joined(separator: ",")
                + VideoFade.filterSteps(fades, timelineDuration: clip.timelineDuration),
            "\(Int(target.midX.rounded()))-w/2",
            "\(Int(target.midY.rounded()))-h/2"
        )
    }
}
