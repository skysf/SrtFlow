import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// **带透明的图**（2026-10-03，docs/bugfixes/2026-10-03-png-transparency-lost.md）：真用到了透明的 PNG 转成预乘过的
// ProRes 4444 + 一份灰度遮罩；带 alpha 通道其实全不透明的、没有 alpha 通道的照旧 H.264。量的是生产参数的真产物：
// 透明处 alpha 是 0、存在透明处的白色被预乘清掉、不透明处原色；遮罩透明处黑、不透明处白；工厂按图挑对了文件名，
// 老名字（2026-10-03 之前把透明图转成的黑方块）不再认。素材用 CoreGraphics 画（不用被测的 ffmpeg 造）。

/// 64×48：左边 1/4 全透明、接着 1/4 半透明的绿（PNG 里存的是直通的 (0,255,0,128) —— 预乘之后绿是 128）、右半不透明蓝。
/// `alpha: false` 画成没有 alpha 通道的。
private func drawImage(_ name: String, transparentLeft: Bool, alpha: Bool = true) -> URL {
    let url = root.appendingPathComponent(name)
    let width = 64, height = 48
    let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info
    )!
    context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    if transparentLeft {
        context.clear(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 0.5))
        context.fill(CGRect(x: width / 4, y: 0, width: width / 4, height: height))
    }
    let image = context.makeImage()!
    let sink = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(sink, image, nil)
    _ = CGImageDestinationFinalize(sink)
    return url
}

/// 某个视频第一帧某个像素的 RGBA（ffmpeg 解成 rgba）。
private func rgba(_ url: URL, x: Int, y: Int) -> [UInt8]? {
    let raw = root.appendingPathComponent("\(url.lastPathComponent)-\(x)x\(y).rgba")
    let (code, _) = run(ffmpegPath, [
        "-hide_banner", "-loglevel", "error", "-y", "-i", url.path, "-frames:v", "1",
        "-vf", "format=rgba,crop=1:1:\(x):\(y)", "-f", "rawvideo", "-pix_fmt", "rgba", raw.path,
    ])
    guard code == 0, let data = try? Data(contentsOf: raw), data.count >= 4 else { return nil }
    return Array(data.prefix(4))
}

/// 等一个 async 的结果（工厂的 stillVideo）；detached，别和顶层代码抢主线程。
private func wait<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) -> T? {
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: T?
    Task.detached {
        result = try? await work()
        semaphore.signal()
    }
    semaphore.wait()
    return result
}

func checkAlphaStills() {
    let transparent = drawImage("alpha-transparent.png", transparentLeft: true)
    let opaqueRGBA = drawImage("alpha-opaque.png", transparentLeft: false)
    let rgb = drawImage("alpha-none.png", transparentLeft: false, alpha: false)

    // ---- 哪张图算用到了透明 ----
    check(StillImageClipFactory.hasAlphaChannel(transparent), "透明 PNG：文件头带 alpha 通道")
    check(StillImageClipFactory.usesTransparency(transparent), "透明 PNG：真用到了透明")
    check(StillImageClipFactory.hasAlphaChannel(opaqueRGBA), "全不透明的 RGBA PNG：文件头也带 alpha 通道")
    check(!StillImageClipFactory.usesTransparency(opaqueRGBA), "全不透明的 RGBA PNG：没用到透明（照旧 H.264，不白转一份 ProRes 4444）")
    check(!StillImageClipFactory.hasAlphaChannel(rgb), "没有 alpha 通道的 PNG：文件头不带")
    check(!StillImageClipFactory.usesTransparency(rgb), "没有 alpha 通道的 PNG：没用到透明")

    // ---- 生产参数的真产物 ----
    let still = root.appendingPathComponent("x-alpha-v1.mov")
    let (stillCode, stillOut) = run(ffmpegPath, StillImageClipFactory.alphaConversionArguments(
        image: transparent, output: still, nativeResolution: false
    ))
    check(stillCode == 0, "透明静帧转码失败：\(stillOut.suffix(300))")
    check(frameCount(still) == StillImageClipFactory.stillFrameCount, "透明静帧帧数应为 \(StillImageClipFactory.stillFrameCount)")
    let (_, probe) = run(ffmpegPath, ["-hide_banner", "-i", still.path])
    check(probe.contains("prores") && probe.contains("yuva444"), "透明静帧是带 alpha 的 ProRes 4444：\(probe.suffix(200))")
    if let left = rgba(still, x: 6, y: 24), let half = rgba(still, x: 24, y: 24), let right = rgba(still, x: 56, y: 24) {
        check(left[3] <= 2 && left[0] <= 2 && left[1] <= 2 && left[2] <= 2, "全透明处 alpha 和颜色都是 0：\(left)")
        check(abs(Int(half[3]) - 128) <= 4, "半透明处 alpha 是一半：\(half)")
        check(abs(Int(half[1]) - 128) <= 6, "半透明处的绿是预乘过的（128，不是直通的 255 —— 预览的合成器把源当预乘的用）：\(half)")
        check(right[3] >= 253 && right[2] >= 250 && right[0] <= 4, "不透明处是原来的蓝：\(right)")
    } else {
        check(false, "透明静帧取不出像素")
    }

    let matte = StillAlphaNaming.matteURL(forStill: still)
    let (matteCode, matteOut) = run(ffmpegPath, StillImageClipFactory.matteConversionArguments(
        image: transparent, output: matte, nativeResolution: false
    ))
    check(matteCode == 0, "遮罩转码失败：\(matteOut.suffix(300))")
    check(frameCount(matte) == StillImageClipFactory.stillFrameCount, "遮罩帧数和静帧一样")
    if let left = rgba(matte, x: 6, y: 24), let half = rgba(matte, x: 24, y: 24), let right = rgba(matte, x: 56, y: 24) {
        check(left[0] <= 3, "遮罩：透明处黑：\(left)")
        check(abs(Int(half[0]) - 128) <= 6, "遮罩：半透明处灰：\(half)")
        check(right[0] >= 252, "遮罩：不透明处白：\(right)")
    } else {
        check(false, "遮罩取不出像素")
    }

    // ---- 起名的合同 ----
    check(StillAlphaNaming.isAlphaStill(still), "x-alpha-v1.mov 认作透明静帧")
    check(StillAlphaNaming.isAlphaStill(URL(fileURLWithPath: "/c/x-alpha-native-v1.mov")), "原生政策的也认")
    check(!StillAlphaNaming.isAlphaStill(matte), "遮罩不是透明静帧")
    check(!StillAlphaNaming.isAlphaStill(URL(fileURLWithPath: "/c/x-v3.mp4")), "老的 H.264 静帧不是")
    check(!StillAlphaNaming.isAlphaStill(URL(fileURLWithPath: "/c/x-opaque-v1.mp4")), "带 alpha 通道的不透明静帧不是")
    check(matte.lastPathComponent == "x-alpha-v1-matte.mp4", "遮罩就在静帧旁边、同名接 -matte.mp4：\(matte.lastPathComponent)")

    // ---- 工厂按图挑文件、命中缓存（真缓存目录：用完删掉自己转的那几份） ----
    guard FileManager.default.isExecutableFile(atPath: ffmpegPath) else { return }
    let ffmpeg = URL(fileURLWithPath: ffmpegPath)
    // 2026-10-03 之前透明图和别的图一样转成 H.264 老名字：造一份这样的老缓存，它不许再被认出来。
    let legacy = StillImageClipFactory.cacheFileURL(for: transparent, nativeResolution: false)
    if let legacy { try? Data(repeating: 1, count: 64).write(to: legacy) }
    check(StillImageClipFactory.cachedStillVideo(for: transparent, nativeResolution: false) == nil,
          "透明图的老 H.264 缓存（黑方块）不再认：打开老工程时重转")
    let made = [transparent, opaqueRGBA, rgb].map { image in
        wait { try await StillImageClipFactory.stillVideo(for: image, ffmpeg: ffmpeg) }
    }
    if let alphaStill = made[0], let opaqueStill = made[1], let plainStill = made[2] {
        check(StillAlphaNaming.isAlphaStill(alphaStill), "透明图转成透明静帧：\(alphaStill.lastPathComponent)")
        check(FileManager.default.fileExists(atPath: StillAlphaNaming.matteURL(forStill: alphaStill).path), "透明静帧旁边有遮罩")
        check(opaqueStill.lastPathComponent.hasSuffix("-opaque-v1.mp4"), "带 alpha 通道的不透明图：-opaque-v1.mp4：\(opaqueStill.lastPathComponent)")
        check(plainStill.lastPathComponent.hasSuffix("-v3.mp4") && !plainStill.lastPathComponent.contains("opaque"),
              "没有 alpha 通道的图照旧 -v3.mp4：\(plainStill.lastPathComponent)")
        check(StillImageClipFactory.cachedStillVideo(for: transparent, nativeResolution: false) == alphaStill, "转完再查命中透明静帧")
        check(StillImageClipFactory.cachedStillVideo(for: opaqueRGBA, nativeResolution: false) == opaqueStill, "转完再查命中不透明的")
        check(StillImageClipFactory.cachedStillVideo(for: rgb, nativeResolution: false) == plainStill, "转完再查命中老名字")
        // 遮罩没了：透明静帧不算命中（带关键帧的上层轨段导出要用它），下次两样一起重转。
        try? FileManager.default.removeItem(at: StillAlphaNaming.matteURL(forStill: alphaStill))
        check(StillImageClipFactory.cachedStillVideo(for: transparent, nativeResolution: false) == nil, "遮罩没了：透明静帧不算命中")
        for url in [alphaStill, opaqueStill, plainStill] { try? FileManager.default.removeItem(at: url) }
    } else {
        check(false, "工厂转不出来：\(made)")
    }
    if let legacy { try? FileManager.default.removeItem(at: legacy) }
}
