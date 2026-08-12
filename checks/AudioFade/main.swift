import AVFoundation
import Foundation
import SrtFlowCore

// **声音渐入渐出的真实回归**：不测纯函数，测两条生产管线真的把声音渐变出来了。
//
// - 导出：调真实的 `VideoEditExportGraph.plan()` 拿生产 ffmpeg 参数，真跑一遍，
//   再把成品解码成 PCM 量音量包络。
// - 预览：调真实的 `VideoEditCompositionBuilder.build()`，用它返回的 audioMix
//   经 `AVAssetReaderAudioMixOutput` 读出 PCM，量同样几个窗口。
//
// 两条管线必须给出同一条包络 —— 「预览听着对、成片不对」正是这套东西最容易
// 出的问题（同 docs/architecture/project-frame-rate.md 里帧率那次的教训）。
//
// 每组都带**反例对照**（同一时间线去掉渐变）：只断言「开头很轻」是不够的，
// 素材本身若是静音起头，断言照样绿。对照组要求开头就是满音量。
//
// 编译方式见 scripts/check-audio-fade.sh。长期约束见
// docs/architecture/audio-fades.md。

var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL [line \(line)] \(message)")
    }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String, line: Int = #line) {
    check(actual == expected, "\(message): got \(actual), expected \(expected)", line: line)
}

let ffmpegPath = ProcessInfo.processInfo.environment["SRTFLOW_FFMPEG"]
    ?? FileManager.default.currentDirectoryPath + "/vendor/ffmpeg"

let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("srtflow-audiofade-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

// 所有出口都是 exit()，而 exit() 不跑 defer —— 统一走 finish() 清临时目录
//（ExportFrameRate 那边攒过 8 个目录，别再重演）。
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

// MARK: - 素材：**恒定音量**的 4 秒正弦

/// 恒定振幅是这套断言的前提：素材自己不能有起伏，量出来的包络才只能来自渐变。
func makeTone(_ name: String, withVideo: Bool) -> URL {
    let url = root.appendingPathComponent(name)
    var args = [
        "-y", "-hide_banner", "-loglevel", "error",
        "-f", "lavfi", "-i", "sine=frequency=440:duration=4:sample_rate=48000",
    ]
    if withVideo {
        args += ["-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30:duration=4"]
        args += ["-map", "1:v", "-c:v", "libx264", "-pix_fmt", "yuv420p"]
        args += ["-map", "0:a"]
    }
    args += ["-c:a", "aac", "-b:a", "192k", "-ac", "2", "-t", "4", url.path]
    let (code, out) = run(ffmpegPath, args)
    if code != 0 { print("造素材失败：\(out)") }
    return url
}

// MARK: - 量包络

/// 把文件解成单声道 f32 PCM。
func decodePCM(_ url: URL) -> [Float] {
    let raw = root.appendingPathComponent("pcm-\(UUID().uuidString).raw")
    let (code, log) = run(ffmpegPath, [
        "-y", "-hide_banner", "-loglevel", "error",
        "-i", url.path, "-map", "0:a",
        "-f", "f32le", "-ac", "1", "-ar", "48000", raw.path,
    ])
    guard code == 0, let data = try? Data(contentsOf: raw) else {
        print("解码失败：\(log)")
        return []
    }
    return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

/// 预览侧：从真实合成 + audioMix 里读 PCM（单声道 f32）。
func previewPCM(_ built: VideoEditCompositionBuilder.Built) async -> [Float] {
    await previewPCM(built.composition, mix: built.audioMix)
}

func previewPCM(_ asset: AVMutableComposition, mix: AVMutableAudioMix?) async -> [Float] {
    guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty,
          let reader = try? AVAssetReader(asset: asset) else { return [] }
    let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 1,
    ])
    output.audioMix = mix
    guard reader.canAdd(output) else { return [] }
    reader.add(output)
    guard reader.startReading() else { return [] }

    var samples: [Float] = []
    while let buffer = output.copyNextSampleBuffer() {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
        let length = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: length)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes)
                == kCMBlockBufferNoErr else { continue }
        bytes.withUnsafeBytes { raw in
            samples.append(contentsOf: raw.bindMemory(to: Float.self))
        }
    }
    return samples
}

/// 一个时间窗内的 RMS（48kHz 单声道）。
func rms(_ samples: [Float], from: Double, to: Double) -> Double {
    let rate = 48_000.0
    let start = max(0, Int(from * rate))
    let end = min(samples.count, Int(to * rate))
    guard end > start else { return 0 }
    var sum = 0.0
    for index in start..<end {
        let value = Double(samples[index])
        sum += value * value
    }
    return (sum / Double(end - start)).squareRoot()
}

/// 一个时间窗内的**峰值**。RMS 会把几毫秒的爆音摊平（100ms 窗里的 2ms 满幅
/// 只把 RMS 抬到 0.14），抓瞬态必须看峰值。
func peak(_ samples: [Float], from: Double, to: Double) -> Double {
    let rate = 48_000.0
    let start = max(0, Int(from * rate))
    let end = min(samples.count, Int(to * rate))
    guard end > start else { return 0 }
    return samples[start..<end].map { Double(abs($0)) }.max() ?? 0
}

/// 一条包络的四个采样点，全部**相对满音量**归一化 —— 这样断言不依赖编码器
/// 的绝对增益，也不依赖素材音量。
struct Envelope {
    var head: Double    // 0.00–0.10s
    var quarter: Double // 0.20–0.30s（1 秒渐入的四分之一处）
    var half: Double    // 0.45–0.55s
    var body: Double    // 2.00–2.10s（满音量参照）
    var tail: Double    // 3.90–4.00s

    init(_ samples: [Float]) {
        let full = rms(samples, from: 2.0, to: 2.1)
        body = full
        let scale = full > 0 ? full : 1
        head = rms(samples, from: 0, to: 0.1) / scale
        quarter = rms(samples, from: 0.2, to: 0.3) / scale
        half = rms(samples, from: 0.45, to: 0.55) / scale
        tail = rms(samples, from: 3.9, to: 4.0) / scale
    }

    var description: String {
        String(
            format: "head=%.3f quarter=%.3f half=%.3f tail=%.3f (满音量 RMS %.3f)",
            head, quarter, half, tail, body
        )
    }
}

/// 一条**线性**渐入 1s / 渐出 1s 的包络该长什么样。
func checkFadedEnvelope(_ envelope: Envelope, _ label: String) {
    check(envelope.body > 0.01, "\(label)：中段必须真的有声音（量到 \(envelope.description)）")
    // 0–0.1s：增益 0→0.1，RMS 比例 ≈ 0.058。
    check(envelope.head < 0.15, "\(label)：开头必须几乎无声（\(envelope.description)）")
    // 0.2–0.3s：增益 0.2→0.3，RMS 比例 ≈ 0.25。
    check(envelope.quarter > 0.12 && envelope.quarter < 0.40,
          "\(label)：渐入四分之一处应在四分之一音量附近（\(envelope.description)）")
    // 0.45–0.55s：增益 ≈ 0.5 —— 线性曲线的判据，换成等功率曲线这条会红。
    check(envelope.half > 0.38 && envelope.half < 0.62,
          "\(label)：渐入中点应是半音量（线性曲线；\(envelope.description)）")
    check(envelope.tail < 0.15, "\(label)：结尾必须几乎无声（\(envelope.description)）")
}

/// 反例对照：没设渐变的同一条时间线，开头结尾都必须是满音量。
func checkFlatEnvelope(_ envelope: Envelope, _ label: String) {
    check(envelope.body > 0.01, "\(label)：中段必须真的有声音（\(envelope.description)）")
    check(envelope.head > 0.85, "\(label)：没设渐变时开头就该是满音量（\(envelope.description)）")
    check(envelope.tail > 0.85, "\(label)：没设渐变时结尾就该是满音量（\(envelope.description)）")
}

// MARK: - 时间线

// 纯音频段的 info 本来就是 nil（时长走 audioAssetDuration），只有带画面的
// 素材需要它。
let videoInfo = MediaInfo(
    duration: 4, displaySize: CGSize(width: 320, height: 180), frameRate: 30,
    videoCodec: "h264", audioCodec: "aac", hasAudio: true,
    audioCanCopyToMP4: true, fileBytes: 1
)

func audioOnlyTimeline(_ source: URL, fadeIn: Double, fadeOut: Double) -> TimelineState {
    var clip = EditClip(
        sourceURL: source, isAudioOnly: true, sourceDuration: 4, timelineStart: 0,
        audioAssetDuration: 4
    )
    clip.fadeInDuration = fadeIn
    clip.fadeOutDuration = fadeOut
    var state = TimelineState()
    state.frameRate = .fps30
    state.audioTracks = [EditLane(clips: [clip])]
    return state
}

func mainTrackTimeline(_ source: URL, fadeIn: Double, fadeOut: Double) -> TimelineState {
    var clip = EditClip(sourceURL: source, sourceDuration: 4, timelineStart: 0, info: videoInfo)
    clip.fadeInDuration = fadeIn
    clip.fadeOutDuration = fadeOut
    var state = TimelineState()
    state.frameRate = .fps30
    state.canvasRatio = .wide16x9
    state.mainClips = [clip]
    return state
}

/// 跑一遍真实导出，返回成品解出来的 PCM。
func exportSamples(_ state: TimelineState, name: String, audioOnly: Bool) async -> [Float]? {
    let output = root.appendingPathComponent(name)
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
        check(false, "\(name) 的 plan() 失败：\(error)")
        return nil
    }
    defer { try? FileManager.default.removeItem(at: plan.workspace) }
    checkEqual(plan.isAudioOnly, audioOnly, "\(name) 走的导出分支要符合预期")

    let (code, out) = run(ffmpegPath, plan.arguments)
    guard code == 0 else {
        check(false, "\(name) 的 ffmpeg 执行失败：\(out.suffix(500))")
        return nil
    }
    let samples = decodePCM(plan.tempOutput)
    guard !samples.isEmpty else {
        check(false, "\(name) 的成品解不出 PCM")
        return nil
    }
    return samples
}

/// 真实预览合成（含 audioMix）读出来的 PCM。
func previewSamples(_ state: TimelineState, name: String) async -> [Float]? {
    guard let built = await VideoEditCompositionBuilder.build(from: state) else {
        check(false, "\(name) 的预览合成没建起来")
        return nil
    }
    let samples = await previewPCM(built)
    guard !samples.isEmpty else {
        check(false, "\(name) 的预览合成读不出 PCM")
        return nil
    }
    return samples
}

func exportEnvelope(_ state: TimelineState, name: String, audioOnly: Bool) async -> Envelope? {
    await exportSamples(state, name: name, audioOnly: audioOnly).map(Envelope.init)
}

func previewEnvelope(_ state: TimelineState, name: String) async -> Envelope? {
    await previewSamples(state, name: name).map(Envelope.init)
}

func main() async {
    guard FileManager.default.isExecutableFile(atPath: ffmpegPath) else {
        print("找不到 ffmpeg：\(ffmpegPath)（跑 scripts/vendor-ffmpeg.sh，或设 SRTFLOW_FFMPEG）")
        finish(1)
    }
    let audioSource = makeTone("tone.m4a", withVideo: false)
    let videoSource = makeTone("tone.mp4", withVideo: true)
    guard FileManager.default.fileExists(atPath: audioSource.path),
          FileManager.default.fileExists(atPath: videoSource.path) else {
        print("测试素材没造出来"); finish(1)
    }
    // 素材自己必须是恒定音量，不然后面所有断言都失去意义。
    let sourceEnvelope = Envelope(decodePCM(audioSource))
    checkFlatEnvelope(sourceEnvelope, "素材本身")

    // ---- 1. 音频轨（audioChain 分支，纯音频导出）----
    let faded = audioOnlyTimeline(audioSource, fadeIn: 1, fadeOut: 1)
    if let envelope = await exportEnvelope(faded, name: "audio-faded.m4a", audioOnly: true) {
        checkFadedEnvelope(envelope, "音频轨导出")
    }
    if let envelope = await previewEnvelope(faded, name: "音频轨预览") {
        checkFadedEnvelope(envelope, "音频轨预览")
    }
    let flat = audioOnlyTimeline(audioSource, fadeIn: 0, fadeOut: 0)
    if let envelope = await exportEnvelope(flat, name: "audio-flat.m4a", audioOnly: true) {
        checkFlatEnvelope(envelope, "音频轨导出（无渐变对照）")
    }
    if let envelope = await previewEnvelope(flat, name: "音频轨预览（无渐变对照）") {
        checkFlatEnvelope(envelope, "音频轨预览（无渐变对照）")
    }

    // ---- 2. 主轨自带的音轨（段内滤镜分支）----
    let mainFaded = mainTrackTimeline(videoSource, fadeIn: 1, fadeOut: 1)
    if let envelope = await exportEnvelope(mainFaded, name: "main-faded.mp4", audioOnly: false) {
        checkFadedEnvelope(envelope, "主轨导出")
    }
    if let envelope = await previewEnvelope(mainFaded, name: "主轨预览") {
        checkFadedEnvelope(envelope, "主轨预览")
    }
    let mainFlat = mainTrackTimeline(videoSource, fadeIn: 0, fadeOut: 0)
    if let envelope = await exportEnvelope(mainFlat, name: "main-flat.mp4", audioOnly: false) {
        checkFlatEnvelope(envelope, "主轨导出（无渐变对照）")
    }

    // ---- 3. 变速：渐变按**时间线秒**算 ----
    //
    // 2 倍速的 4 秒素材在时间线上是 2 秒。渐入 1 秒应当占**时间线的前半段**；
    // 若淡出起点误用源长度算，afade 会落在 4-1=3 秒（早已越过 2 秒的段尾），
    // 整段尾巴就不会淡出。
    var speedState = audioOnlyTimeline(audioSource, fadeIn: 1, fadeOut: 1)
    speedState.audioTracks[0].clips[0].speed = 2

    /// 2 秒时间线上的参照点：中点满音量，两端静。
    func checkSpeedEnvelope(_ samples: [Float], _ label: String) {
        let full = rms(samples, from: 0.9, to: 1.1)
        let head = rms(samples, from: 0, to: 0.1)
        let tail = rms(samples, from: 1.9, to: 2.0)
        let scale = max(full, 0.0001)
        check(full > 0.01, "\(label)：变速段的中点要有声音（RMS \(full)）")
        check(head / scale < 0.2,
              "\(label)：变速段开头要静下来（渐变按时间线秒算；head/full=\(head / scale)）")
        check(tail / scale < 0.2,
              "\(label)：变速段结尾要静下来 —— 淡出起点若误用源长度会落在段外，"
              + "尾巴不淡（tail/full=\(tail / scale)）")
    }
    if let samples = await exportSamples(speedState, name: "speed.m4a", audioOnly: true) {
        checkSpeedEnvelope(samples, "变速导出")
    }
    if let samples = await previewSamples(speedState, name: "变速预览") {
        checkSpeedEnvelope(samples, "变速预览")
    }

    // ---- 4. 渐入起点不许有爆音（段**不从 0 开始**时的增益跳变）----
    //
    // 2026-08-12 的用户报告：渐入开头「砰」的一下，很短促。根因是
    // AVFoundation 混音器把音量跳变按一个缓冲区（实测约 17ms）平滑过去，而
    // 第一条斜坡之前的音量默认是 1.0 —— 「起点 0」的渐入被拉成一条从满音量
    // 降到 0 的下坡贴在最前面。段从 0 开始时没有这个跳变，所以上面那些
    // 100ms RMS 的断言一条都没红。抓它必须同时满足两点：
    //   1. 段起点**不在 0**（有跳变可平滑）；
    //   2. 看**峰值**而不是 RMS（2ms 满幅只把 100ms 的 RMS 抬到 0.14）。
    let offset = 1.3337
    var offsetClip = EditClip(
        sourceURL: audioSource, isAudioOnly: true, sourceDuration: 3,
        timelineStart: offset, audioAssetDuration: 4
    )
    offsetClip.fadeInDuration = 2
    var offsetState = TimelineState()
    offsetState.frameRate = .fps30
    offsetState.audioTracks = [EditLane(clips: [offsetClip])]

    /// 渐入头 30ms 的峰值必须远低于满音量。线性渐入在 30ms 处的增益是
    /// 30ms/2s = 0.015，留到 5% 已经很宽松；出爆音时这里是 ~97%。
    func checkNoFadeInPop(_ samples: [Float], _ label: String) {
        let full = peak(samples, from: offset + 1.95, to: offset + 2.05)
        let head = peak(samples, from: offset, to: offset + 0.03)
        check(full > 0.01, "\(label)：渐入结束处要有满音量参照（peak \(full)）")
        check(head / max(full, 0.0001) < 0.05,
              "\(label)：渐入起点 30ms 内不许有爆音 —— "
              + "斜坡之前的音量没提前钉住，混音器会把 1.0→0 的跳变平滑成一条"
              + "下坡贴在渐入最前面（head/full=\(head / max(full, 0.0001))）")
    }
    if let samples = await exportSamples(offsetState, name: "offset.m4a", audioOnly: true) {
        checkNoFadeInPop(samples, "段从 1.3337s 起 · 导出")
    }
    if let samples = await previewSamples(offsetState, name: "段从 1.3337s 起 · 预览") {
        checkNoFadeInPop(samples, "段从 1.3337s 起 · 预览")
    }

    // 反例对照：同一个偏移位置、**不设渐入**的段，起点就该是满音量硬起 ——
    // 防止「提前钉音量」这条修复反过来给所有段加上一个平白的软起音。
    var offsetFlat = offsetState
    offsetFlat.audioTracks[0].clips[0].fadeInDuration = 0
    if let samples = await previewSamples(offsetFlat, name: "段从 1.3337s 起 · 无渐入对照") {
        let full = peak(samples, from: offset + 1.95, to: offset + 2.05)
        let head = peak(samples, from: offset + 0.002, to: offset + 0.03)
        check(head / max(full, 0.0001) > 0.85,
              "无渐入的段仍要硬起：提前钉的应当是 body 音量本身，"
              + "不能给它加一个 17ms 的软起音（head/full=\(head / max(full, 0.0001))）")
    }

    // ---- 5. 「只换 audioMix」的快路径必须与整条重建等价 ----
    //
    // 改音量/渐变时预览不重建合成（重建要 replaceCurrentItem，画面会闪），
    // 而是拿建好时记下的 `audioPlan` 重算一份 mix 换上去。两条路一旦分叉，
    // 症状是「拖完滑块的声音」和「下次重建之后的声音」不一样 —— 用户几乎
    // 不可能把这种偶发差异描述清楚，只能靠守卫钉住。
    var fastBase = audioOnlyTimeline(audioSource, fadeIn: 1, fadeOut: 1)
    fastBase.audioTracks[0].clips[0].timelineStart = 0.5   // 非零起点，顺带覆盖钉音量那条
    if let built = await VideoEditCompositionBuilder.build(from: fastBase) {
        check(!built.audioPlan.lanes.isEmpty, "建完预览要记下 audioPlan，否则快路径根本用不上")

        var changed = fastBase
        changed.audioTracks[0].clips[0].volume = 0.35
        changed.audioTracks[0].clips[0].fadeInDuration = 0.4
        changed.audioTracks[0].clips[0].fadeOutDuration = 0.6
        check(changed.differsOnlyInAudioMix(from: fastBase),
              "只改音量/渐变必须判成 audio-only（判错成结构变化只是白重建一次，不致命）")

        // 快路径：**老合成** + 新算的 mix
        let fastMix = VideoEditCompositionBuilder.makeAudioMix(state: changed, plan: built.audioPlan)
        let fast = await previewPCM(built.composition, mix: fastMix)
        // 慢路径：整条重建
        var slow: [Float] = []
        if let rebuilt = await VideoEditCompositionBuilder.build(from: changed) {
            slow = await previewPCM(rebuilt)
        }
        check(!fast.isEmpty && !slow.isEmpty, "两条路都要读得出 PCM")
        // 逐点比包络：渐入中、满音量段、渐出中各取一处。
        for probe in [0.7, 1.2, 2.0, 3.0] {
            let a = rms(fast, from: probe, to: probe + 0.05)
            let b = rms(slow, from: probe, to: probe + 0.05)
            check(abs(a - b) < max(0.02, b * 0.1),
                  "快路径与整条重建在 \(probe)s 处的音量必须一致（快 \(a) vs 重建 \(b)）")
        }

        // 判据的另一侧：动了**结构**就不能走快路径，否则预览会跟状态对不上。
        var moved = fastBase
        moved.audioTracks[0].clips[0].timelineStart += 1
        check(!moved.differsOnlyInAudioMix(from: fastBase), "挪了位置不是 audio-only")
        var trimmed = fastBase
        trimmed.audioTracks[0].clips[0].sourceDuration -= 0.5
        check(!trimmed.differsOnlyInAudioMix(from: fastBase), "裁过头不是 audio-only")
        var muted = fastBase
        muted.audioTracks[0].clips[0].isMuted = true
        check(!muted.differsOnlyInAudioMix(from: fastBase),
              "静音不算 audio-only：主轨/画中画的静音段压根不会进合成音轨，改它会改结构")
        check(!fastBase.differsOnlyInAudioMix(from: fastBase), "跟自己比不算「有差异」")
    } else {
        check(false, "快路径用例的预览合成没建起来")
    }

    // ---- 6. 转场仲裁：接缝那条边归转场管，段内不能再淡一次 ----
    //
    // 两段都设了渐入 1s + 渐出 1s，中间一个转场。期望：
    // 第一段只保留渐入（渐出让给转场），第二段只保留渐出（渐入让给转场）——
    // 全图恰好一条 afade=t=in、一条 afade=t=out。
    // 不仲裁的话是两条两条，接缝处衰减两遍，听感是「声音断了一下」。
    var seamState = TimelineState()
    seamState.frameRate = .fps30
    seamState.canvasRatio = .wide16x9
    var first = EditClip(sourceURL: videoSource, sourceDuration: 4, timelineStart: 0, info: videoInfo)
    first.fadeInDuration = 1
    first.fadeOutDuration = 1
    first.transitionAfter = .crossFade
    first.transitionDuration = 1
    var second = EditClip(sourceURL: videoSource, sourceDuration: 4, timelineStart: 3, info: videoInfo)
    second.fadeInDuration = 1
    second.fadeOutDuration = 1
    seamState.mainClips = [first, second]

    let seamOutput = root.appendingPathComponent("seam.mp4")
    do {
        let plan = try await VideoEditExportGraph.plan(
            state: seamState,
            settings: VideoEncodeSettings(),
            subtitleStyle: BurnInStyle(name: "check"),
            subtitleFontURL: nil,
            output: seamOutput
        )
        defer { try? FileManager.default.removeItem(at: plan.workspace) }
        let joined = plan.arguments.joined(separator: " ")
        checkEqual(joined.components(separatedBy: "afade=t=in").count - 1, 1,
                   "接缝上有转场时，全图只应有一条 afade=t=in（第二段的渐入让给 acrossfade）")
        checkEqual(joined.components(separatedBy: "afade=t=out").count - 1, 1,
                   "同理只应有一条 afade=t=out（第一段的渐出让给 acrossfade）")
        check(joined.contains("acrossfade"), "转场自己的交叉淡变还得在")

        // 参数对了还不够，真跑一遍确认这张滤镜图能编出成品。
        let (code, out) = run(ffmpegPath, plan.arguments)
        check(code == 0, "带转场 + 渐变的滤镜图必须能跑通：\(out.suffix(500))")
    } catch {
        check(false, "接缝用例的 plan() 失败：\(error)")
    }

    print("\(checks) checks, \(failures) failures")
    if failures == 0 { print("All checks passed") }
    finish(failures == 0 ? 0 : 1)
}

let semaphore = DispatchSemaphore(value: 0)
Task { await main(); semaphore.signal() }
semaphore.wait()
