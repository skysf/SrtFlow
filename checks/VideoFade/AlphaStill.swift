import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// **带透明的静帧**（2026-10-03，docs/bugfixes/2026-10-03-png-transparency-lost.md）：透明 PNG 放在上层轨，透明的地方要露出
// 下面那一层 —— 以前整张成了黑方块（转码丢了 alpha），带关键帧时连遮罩也只管摆放框。
// 一张画布大小的 PNG（左半透明、右半不透明的黑）经**生产的** `StillImageClipFactory` 转成静帧，放在白色主轨上面：
// - 预览（`VideoEditCompositionBuilder`，和预览同一个函数）：左半白、右半黑；
// - 成片（生产导出）：静态的段、带关键帧（走 fill + matte 预渲染）的段都是左半白、右半黑；
// - 滤镜图：叠之前标明预乘、缩放完反预乘。
// 素材用 CoreGraphics 画（不用被测的 ffmpeg 造）。编法见 scripts/check-video-fade.sh。

private func drawHalfTransparentPNG(size: CGSize) -> URL {
    let url = root.appendingPathComponent("alpha-half.png")
    let width = Int(size.width), height = Int(size.height)
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
    let sink = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(sink, context.makeImage()!, nil)
    _ = CGImageDestinationFinalize(sink)
    return url
}

func checkAlphaStill(white: URL, info: MediaInfo) async {
    let size = info.displaySize
    let png = drawHalfTransparentPNG(size: size)
    guard let still = try? await StillImageClipFactory.stillVideo(for: png, ffmpeg: URL(fileURLWithPath: ffmpegPath)) else {
        check(false, "透明 PNG 转不成静帧")
        return
    }
    check(StillAlphaNaming.isAlphaStill(still), "透明 PNG 转成了带透明的静帧：\(still.lastPathComponent)")
    var stillInfo = info
    stillInfo.duration = StillImageClipFactory.stillDuration
    var upper = EditClip(sourceURL: still, sourceDuration: 4, timelineStart: 0, info: stillInfo)
    upper.stillImageURL = png
    check(upper.isAlphaStill, "这一段认作带透明的静帧")
    var state = TimelineState()
    state.mainClips = [EditClip(sourceURL: white, sourceDuration: 4, timelineStart: 0, info: info)]
    state.overlayTracks = [EditLane(clips: [upper])]
    let left = (x: Int(size.width) / 4, y: Int(size.height) / 2)
    let right = (x: Int(size.width) * 3 / 4, y: Int(size.height) / 2)

    // ---- 预览 ----
    if let clear = await previewPixel(state, x: left.x, y: left.y, at: 2),
       let solid = await previewPixel(state, x: right.x, y: right.y, at: 2) {
        check(clear > 0.85, "预览：透明的左半露出主轨的白（以前是黑方块），实测 \(clear)")
        check(solid < 0.15, "预览：不透明的右半是图上的黑，实测 \(solid)")
    } else {
        check(false, "预览取不出帧")
    }

    // ---- 底下什么都没有（透明静帧单独在 V1）：透明处是黑 ----
    // 预览那边还要垫黑底：默认合成器在混合路径上不认 backgroundColor，播放器的 YUV 输出里透明处是暗绿 —— 取帧器出的是
    // BGRA，看不见这个（2026-10-03 反向验证过：撤掉垫底这里照样绿）。垫底由 checks/project-file-wiring.sh 钉、真窗口里人工看一眼。
    var alone = TimelineState()
    var onMain = upper
    onMain.timelineStart = 0
    alone.mainClips = [onMain]
    if let rgb = await previewRGB(alone, x: left.x, y: left.y, at: 2) {
        check(rgb.allSatisfy { $0 < 0.1 }, "预览：底下什么都没有时透明处是黑，实测 \(rgb)")
    } else {
        check(false, "预览（单独在 V1）取不出帧")
    }
    if let product = await export(alone, name: "alpha-alone.mp4"),
       let clear = pixel(product, x: left.x, y: left.y, at: 2, name: "alpha-alone-left") {
        check(clear < 0.15, "成片：底下什么都没有时透明处是黑，实测 \(clear)")
    }

    // ---- 成片：静态的段（叠之前标明预乘、缩放完反预乘） ----
    if let graph = await filterGraph(state, name: "alpha-static-graph") {
        check(graph.contains("setparams=alpha_mode=premultiplied") && graph.contains("unpremultiply=inplace=1"),
              "滤镜图：透明静帧叠之前标明预乘、缩放完反预乘")
    }
    if let product = await export(state, name: "alpha-static.mp4"),
       let clear = pixel(product, x: left.x, y: left.y, at: 2, name: "alpha-static-left"),
       let solid = pixel(product, x: right.x, y: right.y, at: 2, name: "alpha-static-right") {
        check(clear > 0.85, "成片（静态）：透明的左半露出主轨的白，实测 \(clear)")
        check(solid < 0.15, "成片（静态）：不透明的右半是黑，实测 \(solid)")
    }

    // ---- 成片：带关键帧的段（fill + matte 预渲染，matte 要用图自己的 alpha） ----
    var animated = state
    var keyed = upper
    var animation = ClipAnimation()
    animation.opacity = KeyframeTrack(keys: [Keyframe(time: 0, value: 1), Keyframe(time: 4, value: 1)])
    keyed.animation = animation
    animated.overlayTracks = [EditLane(clips: [keyed])]
    check(keyed.needsPerFrameRender, "带关键帧的透明静帧走预渲染")
    if let product = await export(animated, name: "alpha-keyed.mp4"),
       let clear = pixel(product, x: left.x, y: left.y, at: 2, name: "alpha-keyed-left"),
       let solid = pixel(product, x: right.x, y: right.y, at: 2, name: "alpha-keyed-right") {
        check(clear > 0.85, "成片（带关键帧）：透明的左半露出主轨的白（以前纯白的 matte 让它成了黑方块），实测 \(clear)")
        check(solid < 0.15, "成片（带关键帧）：不透明的右半是黑，实测 \(solid)")
    }
    for url in [still, StillAlphaNaming.matteURL(forStill: still)] { try? FileManager.default.removeItem(at: url) }
}
