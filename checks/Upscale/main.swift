import AVFoundation
import CoreGraphics
import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// **视频 upscale 任务的自检**：范围怎么算（三选一、余料、对齐到整帧、夹在文件里、谁被盖住、「另一处更长」的提示）、
// 起名落盘（原名_宽x高_档位、撞名加编号、文件夹写不进去退路）、封回原声的 ffmpeg 参数（精确裁、画面复制、HEVC 点名 hvc1）、
// 真裁一段（帧数 / 时长 / 尺寸对、首帧就是原片那一刻的画面、没有声音、能取消），以及整条流水线对着假 fal 走一遍
//（裁 → 上传 → 提交 → 等 → 下载 → 封声 → 落盘；整个 mp4 直接上传；取消替 fal 也取消且不留文件；fal 拒绝就没有文件）。
// 编译方式见 scripts/check-upscale.sh；方案 docs/plans/2026-10-02-video-upscale.md；长期约束 docs/architecture/video-upscale.md。

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
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL [line \(line)] \(message): got \(actual), expected \(expected)")
    }
}

func checkClose(_ actual: Double?, _ expected: Double, _ message: String, tolerance: Double = 1e-6, line: Int = #line) {
    checks += 1
    guard let actual, abs(actual - expected) <= tolerance else {
        failures += 1
        print("FAIL [line \(line)] \(message): got \(String(describing: actual)), expected \(expected)")
        return
    }
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("srtflow-upscale-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let ffmpegPath = ProcessInfo.processInfo.environment["SRTFLOW_FFMPEG"]
let ffmpeg = ffmpegPath.map { URL(fileURLWithPath: $0) }

func finish(_ code: Int32) -> Never {
    try? FileManager.default.removeItem(at: root)
    exit(code)
}

func probe(_ url: URL) async -> MediaInfo? {
    if case .success(let info) = await MediaProbe.probe(url: url, ffmpeg: ffmpeg) { return info }
    return nil
}

/// 带声音的原片（ffmpeg 现造：testsrc 画面 + 1 kHz 正弦）。
func makeVideoWithAudio(seconds: Double, name: String) async throws -> URL {
    guard let ffmpeg else { throw FixtureError(description: "没有 ffmpeg（SRTFLOW_FFMPEG）") }
    let url = root.appendingPathComponent(name)
    let process = FFmpegProcess()
    try await process.run(executable: ffmpeg, arguments: [
        "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", "testsrc=size=640x360:rate=24", "-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=48000",
        "-t", String(seconds), "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "48", "-c:a", "aac", "-b:a", "128k", url.path,
    ], workingDirectory: nil)
    return url
}

final class PhaseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [UpscalePhase] = []
    func add(_ phase: UpscalePhase) { lock.lock(); items.append(phase); lock.unlock() }
    var all: [UpscalePhase] { lock.lock(); defer { lock.unlock() }; return items }
}

let semaphore = DispatchSemaphore(value: 0)
Task {
    // ---- 1. 范围 ----
    print("==> 1. 范围：三选一、余料、对齐到整帧、夹在文件里、谁被盖住、「另一处更长」")
    let a = UUID(), b = UUID(), c = UUID()
    let uses = [UpscaleUse(clipID: a, start: 3, duration: 3), UpscaleUse(clipID: b, start: 2, duration: 6), UpscaleUse(clipID: c, start: 8, duration: 2)]
    let mine = UpscaleRange.make(.thisClip, thisClip: a, uses: uses, fileDuration: 12, frameRate: 24)
    checkClose(mine.start, 2, "这一段 3–6：起点往前留 1 秒余料")
    checkClose(mine.end, 7, "…终点往后留 1 秒余料")
    checkEqual(mine.coveredClipIDs, [a], "只盖住这一段（B 用到 8、C 从 8 起：都不在 2–7 里）")
    checkEqual(mine.chosen?.clipID, a, "选的那一处记着（面板写「用了 3.0 s」）")
    let longest = UpscaleRange.make(.longestUse, thisClip: a, uses: uses, fileDuration: 12, frameRate: 24)
    checkClose(longest.start, 1, "最长的那处 2–8：起点 1")
    checkClose(longest.end, 9, "…终点 9")
    checkEqual(Set(longest.coveredClipIDs), Set([a, b]), "盖住 A 和 B，C（8–10）盖不住")
    checkEqual(longest.chosen?.clipID, b, "选的是 B")
    let whole = UpscaleRange.make(.wholeFile, thisClip: a, uses: uses, fileDuration: 12, frameRate: 24)
    checkClose(whole.start, 0, "整个文件：从 0")
    checkClose(whole.end, 12, "…到结尾")
    checkEqual(Set(whole.coveredClipIDs), Set([a, b, c]), "整个文件盖住全部")
    check(whole.chosen == nil, "整个文件没有「选的那一处」")
    let odd = UpscaleRange.make(.thisClip, thisClip: a, uses: [UpscaleUse(clipID: a, start: 3.02, duration: 2.98)], fileDuration: 12, frameRate: 24)
    checkClose(odd.start, 2, "起点对到整帧（往前）", tolerance: 1e-9)
    checkClose(odd.end, 7, "终点对到整帧（往后）", tolerance: 1e-9)
    let edge = UpscaleRange.make(.thisClip, thisClip: a, uses: [UpscaleUse(clipID: a, start: 0.5, duration: 11.4)], fileDuration: 12, frameRate: 24)
    checkClose(edge.start, 0, "余料不出文件头")
    checkClose(edge.end, 12, "余料不出文件尾")
    let gone = UpscaleRange.make(.thisClip, thisClip: UUID(), uses: uses, fileDuration: 12, frameRate: 24)
    checkClose(gone.end, 12, "这一段已经不在了：退到整个文件")
    checkEqual(UpscaleRange.longerUseElsewhere(thisClip: a, uses: uses)?.clipID, b, "点开 A 时提示：B 用得更长")
    check(UpscaleRange.longerUseElsewhere(thisClip: b, uses: uses) == nil, "点开最长的那处：不提示")
    check(UpscaleRange.longerUseElsewhere(thisClip: a, uses: [uses[0], UpscaleUse(clipID: b, start: 0, duration: 3)]) == nil, "一样长：不提示")
    checkClose(UpscaleRange.handle, 1, "余料两头各 1 秒")

    // ---- 2. 起名落盘 ----
    print("==> 2. 起名落盘：原名_宽x高_档位、撞名加编号、文件夹写不进去退路")
    let original = root.appendingPathComponent("Shot_鲸鱼.mp4")
    checkEqual(UpscaleOutputName.stem(original: original, outputSize: CGSize(width: 1890, height: 1080), tier: "topaz-precision"),
               "Shot_鲸鱼_1890x1080_topaz-precision", "文件名 = 原名_宽x高_档位")
    let first = UpscaleOutputName.destination(original: original, outputSize: CGSize(width: 1920, height: 1080), tier: "flux-precise", fallbacks: [], exists: { _ in false })
    checkEqual(first.lastPathComponent, "Shot_鲸鱼_1920x1080_flux-precise.mp4", "不撞名就是它")
    checkEqual(first.deletingLastPathComponent(), original.deletingLastPathComponent(), "放在原片旁边")
    let taken = UpscaleOutputName.destination(original: original, outputSize: CGSize(width: 1920, height: 1080), tier: "flux-precise", fallbacks: []) { $0.lastPathComponent == "Shot_鲸鱼_1920x1080_flux-precise.mp4" }
    checkEqual(taken.lastPathComponent, "Shot_鲸鱼_1920x1080_flux-precise 2.mp4", "撞名加编号（全 App 同一个规矩）")
    let home = root.appendingPathComponent("home"), downloads = root.appendingPathComponent("downloads")
    checkEqual(UpscaleOutputName.folder(original: original, fallbacks: [home, downloads], isWritable: { $0 != original.deletingLastPathComponent() }), home, "原片的文件夹写不进去：退到工程的家")
    checkEqual(UpscaleOutputName.folder(original: original, fallbacks: [home, downloads], isWritable: { $0 == downloads }), downloads, "家也写不进去：退到下载")
    checkEqual(UpscaleOutputName.folder(original: original, fallbacks: [home], isWritable: { _ in false }), original.deletingLastPathComponent(), "哪都写不进去：还是原片旁边（写的时候报错）")

    // ---- 3. 封回原声的参数 ----
    print("==> 3. 封回原声：精确裁原片的声音、画面流复制、HEVC 点名 hvc1")
    let args = UpscaleAudioMux.arguments(upscaled: URL(fileURLWithPath: "/u.mp4"), original: URL(fileURLWithPath: "/o.mp4"), start: 1.5, duration: 2.5, videoCodec: "avc1", output: URL(fileURLWithPath: "/m.mp4"))
    check(args.contains("-c:v") && args[args.firstIndex(of: "-c:v")! + 1] == "copy", "画面流原样复制")
    check(args.contains("-c:a") && args[args.firstIndex(of: "-c:a")! + 1] == "aac", "声音重编成 AAC（流复制只能在帧边界上切）")
    if let ss = args.firstIndex(of: "-ss"), let second = args.lastIndex(of: "-i") {
        check(ss < second, "-ss 在原片的 -i 之前：解码后精确裁，不是流复制的帧边界")
        checkEqual(args[ss + 1], "1.500000", "从原片的 1.5 秒起")
    } else { check(false, "参数里没有 -ss / -i") }
    check(args.contains("-map") && args.contains("0:v:0") && args.contains("1:a:0"), "画面取 upscale 文件的、声音取原片的")
    check(!args.contains("hvc1"), "H.264 不点名 hvc1")
    let hevc = UpscaleAudioMux.arguments(upscaled: URL(fileURLWithPath: "/u.mp4"), original: URL(fileURLWithPath: "/o.mp4"), start: 0, duration: 1, videoCodec: "hvc1", output: URL(fileURLWithPath: "/m.mp4"))
    check(hevc.contains("-tag:v") && hevc.contains("hvc1"), "HEVC 点名 hvc1（不然 AVFoundation 不认）")
    check(UpscaleAudioMux.arguments(upscaled: URL(fileURLWithPath: "/u.mp4"), original: URL(fileURLWithPath: "/o.mp4"), start: 0, duration: 1, videoCodec: "hevc", output: URL(fileURLWithPath: "/m.mp4")).contains("hvc1"), "ffprobe 叫它 hevc 时也点名")

    // ---- 4. 真裁一段 ----
    print("==> 4. 真裁一段：帧数 / 时长 / 尺寸对、首帧是原片那一刻的画面、没有声音、能取消")
    do {
        let ramp = try await makeRampVideo(seconds: 6, fps: 24, size: CGSize(width: 640, height: 360), keyframeEvery: 48, name: "ramp.mp4")
        guard case .success(let source) = await UpscaleSourceTrimmer.load(ramp) else { check(false, "load"); finish(1) }
        let out = root.appendingPathComponent("ramp-cut.mp4")
        let result = await MediaReadQueue.run(on: MediaReadQueue.export) { UpscaleSourceTrimmer.trim(source, start: 1.5, end: 4.0, to: out) }
        guard case .success = result else { check(false, "裁失败：\(result)"); finish(1) }
        let info = await probe(out)
        checkClose(info?.duration, 2.5, "裁出来 2.5 秒", tolerance: 1.0 / 24 + 0.001)
        checkEqual(info?.displaySize, CGSize(width: 640, height: 360), "原分辨率")
        checkEqual(info?.hasAudio, false, "没有声音（做完再从原片封回去）")
        checkEqual(info?.videoCodec.hasPrefix("avc") ?? false, true, "H.264")
        let srcAt15 = await brightness(of: ramp, at: 1.5), cutAt0 = await brightness(of: out, at: 0.0)
        check(abs(srcAt15 - cutAt0) < 0.03, "首帧就是原片 1.5 秒那一帧的画面（\(srcAt15) vs \(cutAt0)）")
        let srcAt39 = await brightness(of: ramp, at: 3.9), cutAt24 = await brightness(of: out, at: 2.4)
        check(abs(srcAt39 - cutAt24) < 0.03, "靠近尾巴也对得上（\(srcAt39) vs \(cutAt24)）")
        checkEqual(UpscaleSourceTrimmer.bitRate(for: CGSize(width: 1280, height: 720), frameRate: 24), 6_635_520, "720p 24 fps 的码率 = 像素 × 帧率 × 0.3")
        checkEqual(UpscaleSourceTrimmer.bitRate(for: CGSize(width: 3840, height: 2160), frameRate: 60), 20_000_000, "封顶 20 Mbps")
        checkEqual(UpscaleSourceTrimmer.bitRate(for: CGSize(width: 320, height: 180), frameRate: 24), 6_000_000, "保底 6 Mbps")
        let cancelled = root.appendingPathComponent("ramp-cancel.mp4")
        let cancelResult = await MediaReadQueue.run(on: MediaReadQueue.export) { UpscaleSourceTrimmer.trim(source, start: 1.5, end: 4.0, to: cancelled, isCancelled: { true }) }
        checkEqual(cancelResult, .failure(.cancelled), "取消了就停")
        check(!FileManager.default.fileExists(atPath: cancelled.path), "取消不留半个文件")

        // ---- 5. 流水线对着假 fal ----
        print("==> 5. 流水线：裁 → 上传 → 提交 → 等 → 下载 → 落盘；整个 mp4 直接上传；取消；fal 拒绝")
        let fakeOutput = try await makeRampVideo(seconds: 2.5, fps: 24, size: CGSize(width: 1920, height: 1080), keyframeEvery: 12, name: "fake-upscaled.mp4")
        let fakeBytes = try Data(contentsOf: fakeOutput)
        let tier = FalUpscaleTiers.tier("bytedance-standard")!
        let queue = "https://queue.fal.run/" + tier.endpoint
        let bucket = "https://storage.googleapis.com/fal/abc?sig=1"
        guard let rampInfo = await probe(ramp) else { check(false, "probe ramp"); finish(1) }
        var polls = 0
        FalStub.reset { seen in
            switch (seen.method, seen.url) {
            case ("POST", "https://rest.fal.ai/storage/upload/initiate?storage_type=fal-cdn-v3"):
                return .init(200, #"{"upload_url":"\#(bucket)","file_url":"https://v3b.fal.media/files/b/in.mp4"}"#)
            case ("PUT", bucket): return .init(200, "")
            case ("POST", queue):
                return .init(200, #"{"request_id":"req-up","status_url":"\#(queue)/requests/req-up/status","response_url":"\#(queue)/requests/req-up","cancel_url":"\#(queue)/requests/req-up/cancel"}"#)
            case ("GET", queue + "/requests/req-up/status"):
                polls += 1
                return .init(200, polls == 1 ? #"{"status":"IN_QUEUE","queue_position":1}"# : (polls == 2 ? #"{"status":"IN_PROGRESS"}"# : #"{"status":"COMPLETED"}"#))
            case ("GET", queue + "/requests/req-up"): return .init(200, #"{"video":{"url":"https://v3b.fal.media/files/b/out.mp4","content_type":"video/mp4"}}"#)
            case ("GET", "https://v3b.fal.media/files/b/out.mp4"): return .init(status: 200, data: fakeBytes)
            default: return .init(404, #"{"detail":"unexpected \#(seen.method) \#(seen.url)"}"#)
            }
        }
        let client = FalClient(session: FalStub.session, pollInterval: { _ in 0.005 }, key: { "id:secret" })
        let work = root.appendingPathComponent("work")
        let range = UpscaleRange.make(.thisClip, thisClip: a, uses: [UpscaleUse(clipID: a, start: 2.5, duration: 0.5)], fileDuration: rampInfo.duration, frameRate: 24)
        checkClose(range.start, 1.5, "这一段 2.5–3.0 加余料：1.5 起")
        let request = UpscaleRequest(originalURL: ramp, originalInfo: rampInfo, range: range, tier: tier, target: .p1080, fallbackFolders: [])
        check(!UpscalePipeline.uploadsWholeFile(request), "只做一段：要裁")
        checkClose(request.estimate, 0.0072 * range.duration, "估价 = 档位 × 送去的秒数", tolerance: 1e-9)
        let phases = PhaseLog()
        do {
            let outcome = try await UpscalePipeline.run(request, client: client, ffmpeg: ffmpeg, workFolder: work) { phases.add($0) }
            checkEqual(outcome.file, root.appendingPathComponent("ramp_1920x1080_bytedance-standard.mp4"), "落在原片旁边、按规矩起名")
            check(FileManager.default.fileExists(atPath: outcome.file.path), "文件真在")
            checkEqual(outcome.info.displaySize, CGSize(width: 1920, height: 1080), "探测的是落盘的那个文件")
            checkClose(outcome.record.sourceOffset, 1.5, "记录：新文件的 0 秒 = 原片的 1.5 秒")
            checkEqual(outcome.record.tier, "bytedance-standard", "记录：档位")
            checkEqual(outcome.record.originalURL, ramp, "记录：原片")
            checkEqual(outcome.record.originalInfo?.displaySize, CGSize(width: 640, height: 360), "记录：原片的探测信息")
            checkEqual(outcome.requestID, "req-up", "fal 的请求号带回来（对账用）")
            check(outcome.audioRestored, "原片没声音：没什么可封，算封好了")
            check(outcome.elapsed >= 0, "耗时")
        } catch {
            check(false, "流水线失败：\(error)")
        }
        checkEqual(phases.all, [.preparing, .uploading, .queued(position: 1), .processing, .downloading, .finishing], "阶段按顺序报")
        let log = FalStub.log
        let put = log.first { $0.method == "PUT" && $0.url == bucket }
        check((put?.body?.count ?? 0) > 0 && (put?.body?.count ?? 0) < (try! Data(contentsOf: ramp)).count, "上传的是裁出来的那一段，不是整个原片")
        let submit = log.first { $0.method == "POST" && $0.url == queue }?.body.flatMap { try? JSONValue.decode($0) }
        checkEqual(submit?["video_url"], "https://v3b.fal.media/files/b/in.mp4", "提交的是上传得到的地址")
        checkEqual(submit?["scale_ratio"], 3, "640×360 到 1080p：3 倍")
        checkEqual(submit?["target_fps"], 24, "帧率照原片")
        checkEqual(submit?["enhancement_preset"], "aigc", "预设")
        check(seenCancel(log) == 0, "正常做完不会取消")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []
        checkEqual(leftovers, [], "中间文件一个不留")

        // 整个 mp4 直接上传
        polls = 0
        let wholeRange = UpscaleRange.make(.wholeFile, thisClip: a, uses: [], fileDuration: rampInfo.duration, frameRate: 24)
        let wholeRequest = UpscaleRequest(originalURL: ramp, originalInfo: rampInfo, range: wholeRange, tier: tier, target: .p1080, fallbackFolders: [])
        check(UpscalePipeline.uploadsWholeFile(wholeRequest), "整个 mp4：直接上传")
        var fluxWhole = wholeRequest
        fluxWhole.tier = FalUpscaleTiers.tier("flux-precise")!
        var longInfo = rampInfo
        longInfo.duration = 25
        fluxWhole.originalInfo = longInfo
        check(!UpscalePipeline.uploadsWholeFile(fluxWhole), "超过模型的时长上限（FLUX 20 秒）：还是要裁")
        do {
            let outcome = try await UpscalePipeline.run(wholeRequest, client: client, ffmpeg: ffmpeg, workFolder: work) { _ in }
            checkClose(outcome.record.sourceOffset, 0, "整个文件：偏移 0")
            checkEqual(outcome.file.lastPathComponent, "ramp_1920x1080_bytedance-standard 2.mp4", "第二次撞名加编号")
            let put = FalStub.log.last { $0.method == "PUT" }
            checkEqual(put?.body, try Data(contentsOf: ramp), "上传的就是原片的字节")
        } catch {
            check(false, "整个文件的流水线失败：\(error)")
        }

        // 带声音的原片：封回去
        if ffmpeg != nil {
            polls = 0
            let withAudio = try await makeVideoWithAudio(seconds: 6, name: "voice.mp4")
            guard let audioInfo = await probe(withAudio) else { check(false, "probe voice"); finish(1) }
            check(audioInfo.hasAudio, "造出来的原片带声音")
            let audioRange = UpscaleRange.make(.thisClip, thisClip: a, uses: [UpscaleUse(clipID: a, start: 2.5, duration: 0.5)], fileDuration: audioInfo.duration, frameRate: 24)
            let audioRequest = UpscaleRequest(originalURL: withAudio, originalInfo: audioInfo, range: audioRange, tier: tier, target: .p1080, fallbackFolders: [])
            do {
                let outcome = try await UpscalePipeline.run(audioRequest, client: client, ffmpeg: ffmpeg, workFolder: work) { _ in }
                check(outcome.audioRestored, "原片的声音封回去了")
                checkEqual(outcome.info.hasAudio, true, "落盘的文件有声音")
                checkEqual(outcome.info.displaySize, CGSize(width: 1920, height: 1080), "画面是 fal 给的")
                checkClose(outcome.info.duration, 2.5, "时长照画面（-shortest）", tolerance: 0.1)
                checkEqual(outcome.file.lastPathComponent, "voice_1920x1080_bytedance-standard.mp4", "起名照旧")
            } catch {
                check(false, "带声音的流水线失败：\(error)")
            }
        } else {
            check(false, "没有 ffmpeg（SRTFLOW_FFMPEG）：封回原声那一段没测到")
        }

        // 取消：替 fal 也取消，不留文件
        FalStub.reset { seen in
            switch (seen.method, seen.url) {
            case ("POST", "https://rest.fal.ai/storage/upload/initiate?storage_type=fal-cdn-v3"):
                return .init(200, #"{"upload_url":"\#(bucket)","file_url":"https://v3b.fal.media/files/b/in.mp4"}"#)
            case ("PUT", bucket): return .init(200, "")
            case ("POST", queue):
                return .init(200, #"{"request_id":"req-c","status_url":"\#(queue)/requests/req-c/status","response_url":"\#(queue)/requests/req-c","cancel_url":"\#(queue)/requests/req-c/cancel"}"#)
            case ("PUT", queue + "/requests/req-c/cancel"): return .init(202, "{}")
            default: return .init(200, #"{"status":"IN_PROGRESS"}"#)
            }
        }
        let before = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let running = Task { try await UpscalePipeline.run(request, client: client, ffmpeg: ffmpeg, workFolder: work) { _ in } }
        for _ in 0..<800 where FalStub.log.filter({ $0.url.hasSuffix("/status") }).count < 2 { try? await Task.sleep(nanoseconds: 10_000_000) }
        running.cancel()
        do {
            _ = try await running.value
            check(false, "取消了不该有结果")
        } catch is CancellationError {
            check(true, "取消")
        } catch {
            check(false, "取消抛的是 \(error)")
        }
        checkEqual(seenCancel(FalStub.log), 1, "替 fal 也取消了")
        let after = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        checkEqual(Set(after), Set(before), "取消不落文件")
        checkEqual((try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? [], [], "取消不留中间文件")

        // fal 拒绝
        FalStub.reset { seen in
            switch (seen.method, seen.url) {
            case ("POST", "https://rest.fal.ai/storage/upload/initiate?storage_type=fal-cdn-v3"):
                return .init(200, #"{"upload_url":"\#(bucket)","file_url":"https://v3b.fal.media/files/b/in.mp4"}"#)
            case ("PUT", bucket): return .init(200, "")
            default: return .init(422, #"{"detail":[{"loc":["body","scale_ratio"],"msg":"too big","type":"x"}]}"#)
            }
        }
        do {
            _ = try await UpscalePipeline.run(request, client: client, ffmpeg: ffmpeg, workFolder: work) { _ in }
            check(false, "fal 拒绝了不该有结果")
        } catch let error as FalError {
            checkEqual(error, .invalidInput("scale_ratio: too big"), "fal 的拒绝原话带回来")
        } catch {
            check(false, "fal 拒绝抛的是 \(error)")
        }
        checkEqual(Set((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []), Set(before), "拒绝不落文件")
    } catch {
        check(false, "素材造不出来：\(error)")
    }

    if failures > 0 {
        print("✗ \(failures) of \(checks) upscale checks failed.")
        finish(1)
    }
    print("All \(checks) upscale checks passed.")
    finish(0)
}

func seenCancel(_ log: [FalSeen]) -> Int { log.filter { $0.method == "PUT" && $0.url.hasSuffix("/cancel") }.count }

semaphore.wait()
