import AVFoundation
import CoreGraphics
import Foundation
import SrtFlowCore

// 成品探针：从真导出的成片里抽一帧量亮度 / 某个像素，读成片时长，取生产滤镜图（字符串断言用）；
// 预览那一帧的某个像素（和预览同一个函数 `VideoEditCompositionBuilder`）。
// 管什么：只读成品 / 计划、只回答数和字符串；不管场景怎么搭、断言怎么写（在 main.swift 和各个用例文件里）。
// 从 main.swift 拆出来（那个文件在行数基线里只许降，见 docs/architecture/coding-standards.md）。

/// 成品在某一时刻那一帧的整幅平均亮度（0…1）。
func brightness(_ url: URL, at seconds: Double, name: String) -> Double? {
    let raw = root.appendingPathComponent("\(name)-\(seconds).gray")
    let (code, out) = run(ffmpegPath, [
        "-hide_banner", "-loglevel", "error", "-y",
        "-ss", String(seconds), "-i", url.path,
        "-frames:v", "1", "-vf", "format=gray,scale=1:1",
        "-f", "rawvideo", "-pix_fmt", "gray", raw.path
    ])
    guard code == 0, let data = try? Data(contentsOf: raw), let byte = data.first else {
        check(false, "\(name) 在 \(seconds)s 抽帧失败：\(out.suffix(300))")
        return nil
    }
    return Double(byte) / 255
}

/// 成品在某一时刻、某个像素的亮度（0…1）。
///
/// 量几何用它、不用整幅平均：成品是 yuv420p 有限范围（白≈235、黑≈16），
/// 整幅平均值会随色彩范围漂，算出来的「黑块占比」对不上。逐像素只问
/// 「这里亮还是暗」，范围怎么变都成立。
func pixel(_ url: URL, x: Int, y: Int, at seconds: Double, name: String) -> Double? {
    let raw = root.appendingPathComponent("\(name)-\(x)x\(y)-\(seconds).gray")
    let (code, out) = run(ffmpegPath, [
        "-hide_banner", "-loglevel", "error", "-y",
        "-ss", String(seconds), "-i", url.path,
        "-frames:v", "1", "-vf", "crop=1:1:\(x):\(y),format=gray",
        "-f", "rawvideo", "-pix_fmt", "gray", raw.path
    ])
    guard code == 0, let data = try? Data(contentsOf: raw), let byte = data.first else {
        check(false, "\(name) 在 \(seconds)s 取 (\(x),\(y)) 失败：\(out.suffix(300))")
        return nil
    }
    return Double(byte) / 255
}

/// 成品的时长（秒），从 `ffmpeg -i` 的 Duration 行读。
func mediaDuration(_ url: URL) -> Double? {
    let (_, out) = run(ffmpegPath, ["-hide_banner", "-i", url.path])
    guard let range = out.range(of: "Duration: ") else { return nil }
    let parts = out[range.upperBound...].prefix(11).split(separator: ":")
    guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]),
          let sec = Double(parts[2]) else { return nil }
    return h * 3600 + m * 60 + sec
}

/// 这份时间线的生产滤镜图（字符串断言用）。
func filterGraph(_ state: TimelineState, name: String) async -> String? {
    let output = root.appendingPathComponent("\(name).mp4")
    do {
        let plan = try await VideoEditExportGraph.plan(
            state: state,
            settings: VideoEncodeSettings(),
            subtitleStyle: BurnInStyle(name: "check"),
            subtitleFontURL: nil,
            output: output
        )
        defer { try? FileManager.default.removeItem(at: plan.workspace) }
        guard let index = plan.arguments.firstIndex(of: "-filter_complex"),
              index + 1 < plan.arguments.count else {
            check(false, "\(name) 的参数里没有 -filter_complex")
            return nil
        }
        return plan.arguments[index + 1]
    } catch {
        check(false, "\(name) 的 plan() 失败：\(error)")
        return nil
    }
}

/// 预览那一帧某个像素的 RGB（0…1，读 AVFoundation 的输出）。
func previewRGB(_ state: TimelineState, x: Int, y: Int, at seconds: Double) async -> [Double]? {
    guard let built = await VideoEditCompositionBuilder.build(from: state) else { return nil }
    let generator = AVAssetImageGenerator(asset: built.composition)
    generator.videoComposition = built.videoComposition
    generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 15)
    generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 15)
    guard let image = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image else { return nil }
    var pixel = [UInt8](repeating: 0, count: 4)
    guard let context = CGContext(
        data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    // 把要量的那一点挪到 (0,0)：CG 的原点在左下。
    context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
    return pixel.prefix(3).map { Double($0) / 255 }
}

func previewPixel(_ state: TimelineState, x: Int, y: Int, at seconds: Double) async -> Double? {
    await previewRGB(state, x: x, y: y, at: seconds).map { $0.reduce(0, +) / 3 }
}
