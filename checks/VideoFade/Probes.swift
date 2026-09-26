import Foundation

// 成品探针：从真导出的成片里抽一帧量亮度 / 某个像素，读成片时长。
// 管什么：只读成品、只回答数；不管场景怎么搭、断言怎么写（在 main.swift 和各个用例文件里）。
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
