import Foundation
import SrtFlowCore

// **盖一块（模糊 / 马赛克）在成片里真的盖了**：不测纯函数，测真导出的成片就是那样。
//
// 调真实的 `VideoEditExportGraph.plan()` 拿生产 ffmpeg 参数、真跑一遍，再把成片抽帧量像素；断言都是**和不带盖一块的基线导出比**
//（同一份素材、同一条管线，只差这一块），不比绝对色值 —— 成片是 yuv420p 有限范围，色值会随色彩范围漂，比差不受影响。
// 素材是 ffmpeg 现造的两种：左红右蓝的阶跃（量模糊的剖面）和 4 像素的黑白棋盘（量哪些像素被改了、马赛克的格子）；
// 造素材用的是 hstack / geq，被测的是 gblur / pixelize，不共用同一个滤镜。
// 守的几条（改 VideoEditCoverExport 或导出图里盖一块的落点之前必读 docs/architecture/cover-blur-mosaic.md）：
// 1. 只改那一块：块外和基线一致，块内被改，改动的外接框就是那块（取偶数）；
// 2. 只在那一段时间里盖；
// 3. 层序：调色之后、形状之前 —— 形状盖在盖一块上面不被糊；
// 4. 模糊是高斯（剖面和理想的阶跃响应比）、马赛克的格子边长对、格子从这一块的左上角起算；
// 5. 藏起来的不导出、不算总长。
// 编法见 scripts/check-cover-export.sh。

var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL [line \(line)] \(message)")
    }
}

let ffmpegPath = ProcessInfo.processInfo.environment["SRTFLOW_FFMPEG"]
    ?? FileManager.default.currentDirectoryPath + "/vendor/ffmpeg"

let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("srtflow-cover-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

/// 所有出口都是 exit()，而 exit() 不跑 defer —— 统一走 finish() 清临时目录。
func finish(_ code: Int32) -> Never {
    try? FileManager.default.removeItem(at: root)
    exit(code)
}

@discardableResult
func run(_ launchPath: String, _ args: [String], in directory: URL? = nil) -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.currentDirectoryURL = directory
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { return (-1, "启动失败：\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// 画布 320×180：1080p 基准的力度乘 1/6 就是成片像素（力度 54 → 高斯半径 9 像素、力度 48 → 8 像素一格）。
let canvas = CGSize(width: 320, height: 180)

func info(seconds: Double) -> MediaInfo {
    MediaInfo(
        duration: seconds, displaySize: canvas, frameRate: 10,
        videoCodec: "h264", audioCodec: nil, hasAudio: false,
        audioCanCopyToMP4: false, fileBytes: 1
    )
}

/// 用 ffmpeg 的 lavfi 现造素材（h264、接近无损）。
func makeVideo(_ name: String, graph: String) -> URL? {
    let url = root.appendingPathComponent(name)
    let (code, out) = run(ffmpegPath, [
        "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", graph,
        "-c:v", "libx264", "-crf", "8", "-pix_fmt", "yuv420p", url.path
    ])
    guard code == 0 else { check(false, "造素材 \(name) 失败：\(out.suffix(400))"); return nil }
    return url
}

/// 跑一遍**生产**导出，返回成品路径。
func export(_ state: TimelineState, name: String) async -> URL? {
    let output = root.appendingPathComponent(name)
    let plan: VideoEditExportGraph.Plan
    do {
        plan = try await VideoEditExportGraph.plan(
            state: state, settings: VideoEncodeSettings(), subtitleStyle: BurnInStyle(name: "check"),
            subtitleFontURL: nil, output: output
        )
    } catch {
        check(false, "\(name) 的 plan() 失败：\(error)")
        return nil
    }
    // 形状的 PNG、调色的 .cube 在参数里都是相对路径：和生产导出一样，在工作目录里跑。
    let (code, out) = run(ffmpegPath, plan.arguments, in: plan.workspace)
    guard code == 0 else {
        try? FileManager.default.removeItem(at: plan.workspace)
        check(false, "\(name) 的 ffmpeg 执行失败：\(out.suffix(800))")
        return nil
    }
    // `tempOutput` 就在 workspace 里，清掉 workspace 等于把成品一起删了 —— 先搬出来再清。
    let kept = root.appendingPathComponent("product-\(name)")
    try? FileManager.default.removeItem(at: kept)
    do { try FileManager.default.copyItem(at: plan.tempOutput, to: kept) } catch {
        try? FileManager.default.removeItem(at: plan.workspace)
        check(false, "\(name) 的成品搬不出来：\(error)")
        return nil
    }
    try? FileManager.default.removeItem(at: plan.workspace)
    return kept
}

/// 这份时间线的生产滤镜图（字符串断言用）。
func filterGraph(_ state: TimelineState, name: String) async -> String? {
    let output = root.appendingPathComponent("\(name).mp4")
    do {
        let plan = try await VideoEditExportGraph.plan(
            state: state, settings: VideoEncodeSettings(), subtitleStyle: BurnInStyle(name: "check"),
            subtitleFontURL: nil, output: output
        )
        defer { try? FileManager.default.removeItem(at: plan.workspace) }
        guard let index = plan.arguments.firstIndex(of: "-filter_complex"), index + 1 < plan.arguments.count else {
            check(false, "\(name) 的参数里没有 -filter_complex")
            return nil
        }
        return plan.arguments[index + 1]
    } catch {
        check(false, "\(name) 的 plan() 失败：\(error)")
        return nil
    }
}

/// 成品某一时刻那一帧的 RGB（整幅）。
struct Frame {
    var width: Int
    var height: Int
    var rgb: [UInt8]

    func pixel(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let i = (y * width + x) * 3
        return (Int(rgb[i]), Int(rgb[i + 1]), Int(rgb[i + 2]))
    }

    /// 和另一帧逐像素比，最大通道差。
    func difference(_ other: Frame, x: Int, y: Int) -> Int {
        let a = pixel(x, y), b = other.pixel(x, y)
        return max(abs(a.r - b.r), max(abs(a.g - b.g), abs(a.b - b.b)))
    }

    /// 和另一帧差超过 `threshold` 的像素的外接框（左闭右开），没有就是 nil。
    func changedBounds(from other: Frame, threshold: Int) -> (x0: Int, y0: Int, x1: Int, y1: Int)? {
        var box: (x0: Int, y0: Int, x1: Int, y1: Int)?
        for y in 0..<height {
            for x in 0..<width where difference(other, x: x, y: y) > threshold {
                box = box.map { (min($0.x0, x), min($0.y0, y), max($0.x1, x + 1), max($0.y1, y + 1)) } ?? (x, y, x + 1, y + 1)
            }
        }
        return box
    }
}

func frame(_ url: URL, at seconds: Double, name: String) -> Frame? {
    let raw = root.appendingPathComponent("\(name)-\(seconds).rgb")
    let (code, out) = run(ffmpegPath, [
        "-hide_banner", "-loglevel", "error", "-y", "-ss", String(seconds), "-i", url.path,
        "-frames:v", "1", "-pix_fmt", "rgb24", "-f", "rawvideo", raw.path
    ])
    let width = Int(canvas.width), height = Int(canvas.height)
    guard code == 0, let data = try? Data(contentsOf: raw), data.count == width * height * 3 else {
        check(false, "\(name) 在 \(seconds)s 抽帧失败：\(out.suffix(300))")
        return nil
    }
    return Frame(width: width, height: height, rgb: [UInt8](data))
}

func mediaDuration(_ url: URL) -> Double? {
    let (_, out) = run(ffmpegPath, ["-hide_banner", "-i", url.path])
    guard let range = out.range(of: "Duration: ") else { return nil }
    let parts = out[range.upperBound...].prefix(11).split(separator: ":")
    guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2]) else { return nil }
    return h * 3600 + m * 60 + sec
}

func main() async {
    guard FileManager.default.isExecutableFile(atPath: ffmpegPath) else {
        print("找不到 ffmpeg：\(ffmpegPath)（跑 scripts/vendor-ffmpeg.sh，或设 SRTFLOW_FFMPEG）")
        finish(1)
    }
    runPureChecks()
    guard let redBlue = makeVideo("redblue.mp4", graph: "color=c=0xE01010:s=160x180:r=10:d=4[l];color=c=0x1010E0:s=160x180:r=10:d=4[r];[l][r]hstack"),
          let checker = makeVideo("checker.mp4", graph: "nullsrc=s=320x180:r=10:d=4,geq=lum='if(mod(floor(X/4)+floor(Y/4),2),235,16)':cb=128:cr=128")
    else { finish(1) }
    await runExportChecks(redBlue: redBlue, checker: checker)
    if failures > 0 {
        print("✗ \(failures) of \(checks) checks failed")
        finish(1)
    }
    print("All \(checks) checks passed.")
    finish(0)
}

await main()
