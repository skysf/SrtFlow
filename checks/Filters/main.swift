import AVFoundation
import CoreImage
import Foundation
import SrtFlowCore

// 时间轴滤镜（调色）的回归。三组：
//
// 一、**LUT 的数学**。核心是那条等式 —— 「先把表按强度插值、再查表」等于
//    「先查满强度表、再按强度混回原色」。预览和导出都走前者，而用户心里想的
//    是后者；这条不成立，强度这个参数就是骗人的。
//
// 二、**模型**：层号的落层/收拢规则、生效顺序、滤镜不算时间线总长。
//
// 三、**预览 vs 导出，逐像素比对**（这一刀的验收项）。三方对齐：
//    配方算出来的值 ↔ CoreImage 渲出来的值 ↔ 真跑 ffmpeg 出片后解出来的值。
//    反向验证过：把 .cube 的通道顺序写反，这一组当场变红（2026-09-21）。
//    `interp=trilinear` 是由**参数断言**守的，不是像素 —— 理由写在
//    scripts/check-filters.sh 的开头。
//
// 编译方式见 scripts/check-filters.sh。

var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL [line \(line)] \(message)")
    }
}

func checkClose(
    _ actual: Double, _ expected: Double, _ tolerance: Double, _ message: String, line: Int = #line
) {
    checks += 1
    if abs(actual - expected) > tolerance {
        failures += 1
        print("FAIL [line \(line)] \(message)：得 \(actual)，期望 \(expected)±\(tolerance)")
    }
}

let ffmpegPath = ProcessInfo.processInfo.environment["SRTFLOW_FFMPEG"]
    ?? FileManager.default.currentDirectoryPath + "/vendor/ffmpeg"

let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("srtflow-filters-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

// 所有出口都是 exit()，而 exit() 不跑 defer —— 清理统一走 finish()
//（同 ExportFrameRate 那条踩过的坑）。
func finish(_ code: Int32) -> Never {
    try? FileManager.default.removeItem(at: root)
    exit(code)
}

@discardableResult
func run(_ launchPath: String, _ args: [String]) -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { return (-1, "启动失败：\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

// MARK: - 一、LUT 的数学

/// 三线性查表。CIColorCube 和 ffmpeg 的 `lut3d=interp=trilinear` 都是这个算法，
/// 这里自己实现一份用来验那条等式（不是抄实现 —— 被测的是**表**，不是查法）。
func lookup(_ table: [Float], _ rgb: (Double, Double, Double)) -> (Double, Double, Double) {
    let n = FilterLUT.dimension
    let scale = Double(n - 1)
    func axis(_ value: Double) -> (low: Int, high: Int, fraction: Double) {
        let position = min(max(value, 0), 1) * scale
        let low = min(Int(position), n - 1)
        let high = min(low + 1, n - 1)
        return (low, high, position - Double(low))
    }
    let (r0, r1, rf) = axis(rgb.0)
    let (g0, g1, gf) = axis(rgb.1)
    let (b0, b1, bf) = axis(rgb.2)
    func sample(_ ri: Int, _ gi: Int, _ bi: Int) -> (Double, Double, Double) {
        let index = ((bi * n + gi) * n + ri) * 4
        return (Double(table[index]), Double(table[index + 1]), Double(table[index + 2]))
    }
    func mix(
        _ a: (Double, Double, Double), _ b: (Double, Double, Double), _ t: Double
    ) -> (Double, Double, Double) {
        (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
    }
    let c00 = mix(sample(r0, g0, b0), sample(r1, g0, b0), rf)
    let c10 = mix(sample(r0, g1, b0), sample(r1, g1, b0), rf)
    let c01 = mix(sample(r0, g0, b1), sample(r1, g0, b1), rf)
    let c11 = mix(sample(r0, g1, b1), sample(r1, g1, b1), rf)
    return mix(mix(c00, c10, gf), mix(c01, c11, gf), bf)
}

func lutMath() {
    let n = FilterLUT.dimension
    let identity = FilterLUT.identityTable
    check(identity.count == n * n * n * 4, "恒等表的大小是 33³×4")

    // 恒等表必须真的是恒等 —— 强度 0 的那一端全靠它。
    var identityExact = true
    for bi in 0..<n {
        for gi in 0..<n {
            for ri in 0..<n {
                let index = ((bi * n + gi) * n + ri) * 4
                let step = 1.0 / Double(n - 1)
                if abs(Double(identity[index]) - Double(ri) * step) > 1e-5
                    || abs(Double(identity[index + 1]) - Double(gi) * step) > 1e-5
                    || abs(Double(identity[index + 2]) - Double(bi) * step) > 1e-5 {
                    identityExact = false
                }
            }
        }
    }
    check(identityExact, "恒等表每个格点都等于它自己的坐标")

    let preset = FilterPreset.coldIron
    let full = FilterLUT.fullTable(for: preset)
    check(FilterLUT.table(for: preset, strength: 0) == identity, "强度 0 = 恒等表（原片）")
    check(FilterLUT.table(for: preset, strength: 1) == full, "强度 1 = 满强度表")
    check(FilterLUT.table(for: preset, strength: -3) == identity, "强度夹在下界")
    check(FilterLUT.table(for: preset, strength: 9) == full, "强度夹在上界")

    // **核心等式**：lerp(identity, LUT, s) 查表 == lerp(c, LUT(c), s)。
    // 预览和导出都用左边（一张插值好的表），用户心里想的是右边（按比例混回
    // 原色）。三线性插值对线性函数无误差，所以两者应当严格相等。
    let samples: [(Double, Double, Double)] = [
        (0.706, 0.353, 0.235), (0.1, 0.9, 0.5), (0.33, 0.33, 0.33), (0.87, 0.21, 0.64),
    ]
    var equationHolds = true
    for strength in [0.25, 0.5, 0.72, 0.9] {
        let blended = FilterLUT.table(for: preset, strength: strength)
        for sample in samples {
            let viaTable = lookup(blended, sample)
            let graded = lookup(full, sample)
            let viaMix = (
                sample.0 + (graded.0 - sample.0) * strength,
                sample.1 + (graded.1 - sample.1) * strength,
                sample.2 + (graded.2 - sample.2) * strength
            )
            if abs(viaTable.0 - viaMix.0) > 1e-4
                || abs(viaTable.1 - viaMix.1) > 1e-4
                || abs(viaTable.2 - viaMix.2) > 1e-4 {
                equationHolds = false
            }
        }
    }
    check(equationHolds, "先插值后查表 == 先查表后混色（强度这个参数的定义）")

    // .cube 文本和 CIColorCube 的数据必须是**同一份表的两种写法**：
    // 同样的顺序（r 变最快）、同样的值。写反了导出就是另一个味道。
    let text = FilterLUT.cubeFileText(for: preset, strength: 0.6)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    check(lines.first == "LUT_3D_SIZE \(n)", "第一行是 LUT_3D_SIZE")
    check(lines.count == n * n * n + 1, ".cube 的数据行数 = 33³")
    let table = FilterLUT.table(for: preset, strength: 0.6)
    var textMatches = true
    for index in [0, 1, n, n * n, n * n * n - 1, 12345] {
        let parts = lines[index + 1].split(separator: " ").compactMap { Double($0) }
        guard parts.count == 3 else { textMatches = false; continue }
        for channel in 0..<3 where abs(parts[channel] - Double(table[index * 4 + channel])) > 1e-5 {
            textMatches = false
        }
    }
    check(textMatches, ".cube 的每一行都对上表里同一个格点（顺序：r 变最快）")
}

// MARK: - 二、模型

func model() {
    var state = TimelineState()

    check(state.lowestFreeFilterLayer(start: 0, end: 3) == 0, "空时间线落在第 0 层")

    state.filters = [FilterClip(preset: .coldIron, timelineStart: 0, duration: 3, layer: 0)]
    check(state.lowestFreeFilterLayer(start: 1, end: 4) == 1, "撞上了就摞到上一层")
    check(state.lowestFreeFilterLayer(start: 3, end: 6) == 0, "首尾紧挨着不算重叠，复用第 0 层")
    check(state.lowestFreeFilterLayer(start: 10, end: 13) == 0, "错开的时间段复用第 0 层")

    state.filters.append(FilterClip(preset: .coldIron, timelineStart: 1, duration: 3, layer: 1))
    check(state.lowestFreeFilterLayer(start: 2, end: 5) == 2, "两层都占了就开第 2 层")
    check(state.filterLayerCount == 2, "层数 = 最大层号 + 1")

    // 收拢：删掉中间那层之后层号要连续，且**相对顺序不变**（所以画面不跳）。
    state.filters = [
        FilterClip(preset: .coldIron, timelineStart: 0, duration: 3, layer: 0),
        FilterClip(preset: .coldIron, timelineStart: 0, duration: 3, layer: 2),
        FilterClip(preset: .coldIron, timelineStart: 0, duration: 3, layer: 5),
    ]
    let orderBefore = state.orderedFilters.map(\.id)
    state.compactFilterLayers()
    check(state.filters.map(\.layer).sorted() == [0, 1, 2], "收拢后层号连续")
    check(state.orderedFilters.map(\.id) == orderBefore, "收拢不改相对顺序")

    // 生效顺序：层号小的先作用。
    let low = FilterClip(preset: .coldIron, timelineStart: 0, duration: 5, layer: 0)
    let high = FilterClip(preset: .coldIron, timelineStart: 0, duration: 5, layer: 1)
    state.filters = [high, low]
    check(state.orderedFilters.map(\.layer) == [0, 1], "orderedFilters 按层号升序，不看数组顺序")
    check(state.activeFilters(at: 2).count == 2, "两段都盖住 2s 处")
    check(state.activeFilters(at: 7).isEmpty, "区间外不生效")
    check(state.activeFilters(at: 5).isEmpty, "右端开区间：正好在终点不生效")

    // 滤镜**不算**时间线总长（反例守卫：算进去会让成片凭空多一截黑场）。
    var withClip = TimelineState()
    withClip.mainClips = [
        EditClip(sourceURL: URL(fileURLWithPath: "/tmp/x.mp4"), sourceDuration: 4, timelineStart: 0)
    ]
    let baseDuration = withClip.duration
    withClip.filters = [FilterClip(preset: .coldIron, timelineStart: 30, duration: 3, layer: 0)]
    checkClose(withClip.duration, baseDuration, 1e-9, "拖到片尾之外的滤镜不该把工程撑长")

    // 存盘、v17 登记与往返保真在 checks/ProjectFile/main.swift 第 25 节。
}

// MARK: - 三、预览 vs 导出，逐像素

/// 预览那条路：同一份表交给 CIColorCubeWithColorSpace，渲一个 1×1 出来。
///
/// 位图和渲染都钉在 `FilterLUT.workingColorSpace` 上 —— 定义域必须和 ffmpeg
/// 那边（解码出来的 709 编码值直接进 lut3d）是同一个，否则比的是两件事。
func previewPixel(
    _ input: (UInt8, UInt8, UInt8), preset: FilterPreset, strength: Double
) -> (Double, Double, Double)? {
    let space = FilterLUT.workingColorSpace
    guard let filter = FilterLUT.previewFilter(for: preset, strength: strength, name: "check")
    else { return nil }
    let source = Data([input.0, input.1, input.2, 255])
    let image = CIImage(
        bitmapData: source, bytesPerRow: 4, size: CGSize(width: 1, height: 1),
        format: .RGBA8, colorSpace: space
    )
    filter.setValue(image, forKey: kCIInputImageKey)
    guard let output = filter.outputImage else { return nil }
    let context = CIContext(options: [
        .workingColorSpace: space, .outputColorSpace: space,
    ])
    var pixel = [UInt8](repeating: 0, count: 4)
    context.render(
        output, toBitmap: &pixel, rowBytes: 4,
        bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
        format: .RGBA8, colorSpace: space
    )
    return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
}

/// 从一个视频文件的指定时刻取一个像素（取画面正中，避开边缘）。
func exportedPixel(_ url: URL, at seconds: Double) -> (Double, Double, Double)? {
    let raw = root.appendingPathComponent("pixel-\(UUID().uuidString).raw")
    let (code, out) = run(ffmpegPath, [
        "-hide_banner", "-loglevel", "error",
        "-i", url.path, "-ss", String(seconds), "-frames:v", "1",
        "-vf", "crop=8:8:(iw-8)/2:(ih-8)/2,scale=1:1",
        "-f", "rawvideo", "-pix_fmt", "rgb24", raw.path,
    ])
    guard code == 0, let data = try? Data(contentsOf: raw), data.count >= 3 else {
        print("取像素失败：\(out)")
        return nil
    }
    return (Double(data[0]) / 255, Double(data[1]) / 255, Double(data[2]) / 255)
}

func parity() async {
    // 纯色素材：颜色是平的，编码损失可以忽略，取到的像素就是管线算出来的值。
    // 刻意选一个**远离夹取区**的中间色（见 FilterLUT.apply：白/黑附近会被
    // clamp，那里的表不再局部线性，三方就对不齐了 —— 那是数学，不是 bug）。
    let input: (UInt8, UInt8, UInt8) = (180, 90, 60)
    let source = root.appendingPathComponent("flat.mp4")
    let hex = String(format: "0x%02X%02X%02X", input.0, input.1, input.2)
    let (makeCode, makeOut) = run(ffmpegPath, [
        "-y", "-hide_banner", "-loglevel", "error",
        "-f", "lavfi", "-i", "color=c=\(hex):size=320x180:rate=30:duration=3",
        "-c:v", "libx264", "-crf", "0", "-pix_fmt", "yuv420p", source.path,
    ])
    guard makeCode == 0 else { print("造纯色素材失败：\(makeOut)"); finish(1) }

    // 素材本身解出来是什么颜色（yuv 往返会差一两个码值）—— 比对要以它为准，
    // 拿名义色当基准的话，差的是编码误差，不是管线误差。
    guard let decoded = exportedPixel(source, at: 1.0) else {
        check(false, "素材像素取不到"); return
    }
    let decoded8 = (
        UInt8((decoded.0 * 255).rounded()),
        UInt8((decoded.1 * 255).rounded()),
        UInt8((decoded.2 * 255).rounded())
    )

    let preset = FilterPreset.coldIron
    let info = MediaInfo(
        duration: 3, displaySize: CGSize(width: 320, height: 180), frameRate: 30,
        videoCodec: "h264", audioCodec: nil, hasAudio: false,
        audioCanCopyToMP4: false, fileBytes: 1
    )

    for strength in [1.0, 0.6] {
        var state = TimelineState()
        state.frameRate = .fallback
        state.canvasRatio = .wide16x9
        state.mainClips = [
            EditClip(sourceURL: source, sourceDuration: 3, timelineStart: 0, info: info)
        ]
        // 只盖住 1.0…2.5s：区间外必须是原色，这是 `enable` 那一项的回归。
        state.filters = [
            FilterClip(
                preset: preset, strength: strength,
                timelineStart: 1.0, duration: 1.5, layer: 0
            )
        ]

        let output = root.appendingPathComponent("graded-\(strength).mp4")
        let plan: VideoEditExportGraph.Plan
        do {
            plan = try await VideoEditExportGraph.plan(
                state: state,
                settings: VideoEncodeSettings(),
                subtitleStyle: BurnInStyle(name: "check"),
                subtitleFontURL: nil,
                output: output
            )
        } catch {
            check(false, "plan() 失败：\(error)")
            continue
        }
        defer { try? FileManager.default.removeItem(at: plan.workspace) }

        let joined = plan.arguments.joined(separator: " ")
        check(joined.contains("lut3d=file=filter0.cube"), "滤镜链真的用上了 lut3d（强度 \(strength)）")
        check(joined.contains("interp=trilinear"), "必须显式写 interp=trilinear（默认是 tetrahedral）")
        check(joined.contains("format=gbrp"), "lut3d 之前要把像素格式钉成 RGB")
        check(joined.contains("enable='between(t,1,2.5)'"), "enable 区间就是滤镜段的起止")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = plan.arguments
        process.currentDirectoryURL = plan.workspace
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        let log = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            check(false, "ffmpeg 跑失败：\(String(data: log, encoding: .utf8) ?? "")")
            continue
        }
        try? FileManager.default.moveItem(at: plan.tempOutput, to: output)

        // ① 配方算出来的值（三方里的「应该是多少」）。
        let normalized = (
            Double(decoded8.0) / 255, Double(decoded8.1) / 255, Double(decoded8.2) / 255
        )
        let graded = FilterLUT.apply(preset.recipe, normalized)
        let expected = (
            normalized.0 + (graded.r - normalized.0) * strength,
            normalized.1 + (graded.g - normalized.1) * strength,
            normalized.2 + (graded.b - normalized.2) * strength
        )

        // ② 预览那条路。
        guard let preview = previewPixel(decoded8, preset: preset, strength: strength) else {
            check(false, "CoreImage 渲不出来"); continue
        }
        // CoreImage 只有 8bit 量化误差，容差给 1.5/255。
        checkClose(preview.0, expected.0, 1.5 / 255, "预览 R 对得上配方（强度 \(strength)）")
        checkClose(preview.1, expected.1, 1.5 / 255, "预览 G 对得上配方（强度 \(strength)）")
        checkClose(preview.2, expected.2, 1.5 / 255, "预览 B 对得上配方（强度 \(strength)）")

        // ③ 导出那条路。多一趟 yuv 往返 + 一次有损编码，容差给 4/255。
        guard let exported = exportedPixel(output, at: 1.6) else {
            check(false, "成片像素取不到"); continue
        }
        checkClose(exported.0, expected.0, 4 / 255, "成片 R 对得上配方（强度 \(strength)）")
        checkClose(exported.1, expected.1, 4 / 255, "成片 G 对得上配方（强度 \(strength)）")
        checkClose(exported.2, expected.2, 4 / 255, "成片 B 对得上配方（强度 \(strength)）")

        // ④ 预览和导出互相对得上（这一刀的验收项本身）。
        checkClose(exported.0, preview.0, 4 / 255, "预览 R == 成片 R（强度 \(strength)）")
        checkClose(exported.1, preview.1, 4 / 255, "预览 G == 成片 G（强度 \(strength)）")
        checkClose(exported.2, preview.2, 4 / 255, "预览 B == 成片 B（强度 \(strength)）")

        // ⑤ `enable` 区间之外必须是原片。
        guard let before = exportedPixel(output, at: 0.4) else {
            check(false, "区间外像素取不到"); continue
        }
        checkClose(before.0, normalized.0, 4 / 255, "滤镜段之前是原色 R（强度 \(strength)）")
        checkClose(before.1, normalized.1, 4 / 255, "滤镜段之前是原色 G（强度 \(strength)）")
        checkClose(before.2, normalized.2, 4 / 255, "滤镜段之前是原色 B（强度 \(strength)）")
    }

    // 强度 0 整条跳过：成片应当和原片一样，滤镜图里连 lut3d 都不该有。
    var zero = TimelineState()
    zero.frameRate = .fallback
    zero.canvasRatio = .wide16x9
    zero.mainClips = [
        EditClip(sourceURL: source, sourceDuration: 3, timelineStart: 0, info: info)
    ]
    zero.filters = [
        FilterClip(preset: preset, strength: 0, timelineStart: 0, duration: 3, layer: 0)
    ]
    do {
        let plan = try await VideoEditExportGraph.plan(
            state: zero,
            settings: VideoEncodeSettings(),
            subtitleStyle: BurnInStyle(name: "check"),
            subtitleFontURL: nil,
            output: root.appendingPathComponent("zero.mp4")
        )
        defer { try? FileManager.default.removeItem(at: plan.workspace) }
        check(
            !plan.arguments.joined(separator: " ").contains("lut3d"),
            "强度 0 的滤镜段不进滤镜图（原片应当逐像素不变）"
        )
    } catch {
        check(false, "强度 0 的 plan() 失败：\(error)")
    }
}

func main() async {
    guard FileManager.default.isExecutableFile(atPath: ffmpegPath) else {
        print("找不到 ffmpeg：\(ffmpegPath)（跑 scripts/vendor-ffmpeg.sh，或设 SRTFLOW_FFMPEG）")
        finish(1)
    }
    lutMath()
    model()
    await parity()

    print("\(checks) checks, \(failures) failures")
    if failures > 0 { finish(1) }
    print("All checks passed")
    finish(0)
}

await main()
