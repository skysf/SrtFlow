import AVFoundation
import CoreGraphics
import Foundation
import SrtFlowCore

// **优化媒体的自检**：判据是纯函数、关键帧间隔真的扫出来、解码速度量得出、一块真的转出来（0.5 秒内必有关键帧、
// 没有 B 帧、尺寸 / 时长 / 帧数对、首尾帧和源同一时刻的画面一样、不带声音）、缓存按身份存取、超了上限丢最久没用的；
// V3：上限从设置读（默认 10 GB、低于下限按下限）、几档、过期的天数、清空之后什么都不剩且还能再落块。
// 编译方式见 scripts/check-optimized-media.sh；方案 docs/plans/2026-10-01-video-optimized-media.md；
// 长期约束 docs/architecture/optimized-media.md。

var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL [line \(line)] \(message)")
    }
}

let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("srtflow-optimizedmedia-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

func finish(_ code: Int32) -> Never {
    try? FileManager.default.removeItem(at: root)
    exit(code)
}

func info(keyframeInterval: Double?, frameRate: Double = 30, codec: String = "h264") -> MediaInfo {
    MediaInfo(duration: 60, displaySize: CGSize(width: 1920, height: 1080), frameRate: frameRate, videoCodec: codec,
              audioCodec: nil, hasAudio: false, audioCanCopyToMP4: false, fileBytes: 1, keyframeInterval: keyframeInterval)
}

let semaphore = DispatchSemaphore(value: 0)
Task {
    // ---- 1. 判据与参数（纯函数）----
    print("==> 1. 判据：长 GOP 才转、按这台机器的解码速度算、全帧内 / 静帧 / 不知道的不转；尺寸、码率、分块")
    check(OptimizedMediaPolicy.needsProxy(info: info(keyframeInterval: 10), isStillImage: false, decodeFPS: 500),
          "10 秒一个关键帧、500 fps 的机器：一个 GOP 要解 0.6 秒，远超两帧，要转")
    check(!OptimizedMediaPolicy.needsProxy(info: info(keyframeInterval: 0.5), isStillImage: false, decodeFPS: 500),
          "0.5 秒一个关键帧：15 帧 30 ms 就解完，不转")
    check(OptimizedMediaPolicy.needsProxy(info: info(keyframeInterval: 1), isStillImage: false, decodeFPS: 100),
          "1 秒一个关键帧在慢机器（100 fps）上要解 0.3 秒，要转")
    check(!OptimizedMediaPolicy.needsProxy(info: info(keyframeInterval: 1), isStillImage: false, decodeFPS: 2000),
          "同样的源在快机器（2000 fps）上 15 ms 就解完，不转 —— 机器的解码速度决定")
    check(!OptimizedMediaPolicy.needsProxy(info: info(keyframeInterval: nil), isStillImage: false, decodeFPS: 500), "没探过的源不转")
    check(!OptimizedMediaPolicy.needsProxy(info: info(keyframeInterval: 0), isStillImage: false, decodeFPS: 500), "全帧内（间隔 0）不转")
    check(!OptimizedMediaPolicy.needsProxy(info: info(keyframeInterval: 10, codec: "apcn"), isStillImage: false, decodeFPS: 500), "ProRes 不转")
    check(!OptimizedMediaPolicy.needsProxy(info: info(keyframeInterval: 10), isStillImage: true, decodeFPS: 500), "静帧不转")
    check(!OptimizedMediaPolicy.needsProxy(info: info(keyframeInterval: 10), isStillImage: false, decodeFPS: 0), "解码速度没量过（0）不转")
    check(OptimizedMediaPolicy.targetSize(forNatural: CGSize(width: 1920, height: 1080)) == CGSize(width: 1920, height: 1080), "1080p 原分辨率")
    check(OptimizedMediaPolicy.targetSize(forNatural: CGSize(width: 3840, height: 2160)) == CGSize(width: 1920, height: 1080), "4K 减半")
    check(OptimizedMediaPolicy.targetSize(forNatural: CGSize(width: 1080, height: 1920)) == CGSize(width: 1080, height: 1920), "竖屏 1080p 不动")
    check(OptimizedMediaPolicy.targetSize(forNatural: CGSize(width: 1919, height: 1081)) == CGSize(width: 1920, height: 1082), "宽高取偶数")
    check(OptimizedMediaPolicy.bitRate(for: CGSize(width: 1920, height: 1080)) == 12_000_000, "1080p 12 Mbps")
    check(abs(Double(OptimizedMediaPolicy.bitRate(for: CGSize(width: 1280, height: 720))) - 5_333_333) < 2, "720p 按像素等比 ≈ 5.33 Mbps")
    check(OptimizedMediaPolicy.bitRate(for: CGSize(width: 64, height: 36)) == 2_000_000, "小图封在 2 Mbps")
    check(OptimizedMediaPolicy.chunkIndex(forSourceSeconds: 9.999) == 0 && OptimizedMediaPolicy.chunkIndex(forSourceSeconds: 10) == 1, "10 秒一块")
    check(OptimizedMediaPolicy.coveringChunks(sourceStart: 3, sourceDuration: 9, sourceLength: 12) == 0...1, "3–12 秒正好盖住第 0、1 块（不留余量）")
    check(OptimizedMediaPolicy.coveringChunks(sourceStart: 10, sourceDuration: 2, sourceLength: 12) == 1...1, "10–12 秒只用第 1 块")
    check(OptimizedMediaPolicy.coveringChunks(sourceStart: 19.9995, sourceDuration: 0.001, sourceLength: 20) == 1...1, "贴着块尾的一丁点不算下一块")
    check(OptimizedMediaPolicy.coveringChunks(sourceStart: 25, sourceDuration: 3, sourceLength: 12) == 1...1, "起点在源的结尾之外也不超过最后一块")
    check(OptimizedMediaPolicy.proxyFrameDuration(sourceFPS: 29.97) == CMTime(value: 1001, timescale: 30000), "29.97 → 1001/30000")
    check(OptimizedMediaPolicy.proxyFrameDuration(sourceFPS: 30) == CMTime(value: 1, timescale: 30), "30 → 1/30")
    check(OptimizedMediaPolicy.proxyFrameDuration(sourceFPS: 23.976) == CMTime(value: 1001, timescale: 24000), "23.976 → 1001/24000")
    check(OptimizedMediaPolicy.proxyFrameDuration(sourceFPS: 60) == CMTime(value: 1, timescale: 60), "60 → 1/60")
    check(OptimizedMediaPolicy.proxyFrameDuration(sourceFPS: 7.3) == CMTime(value: 1, timescale: 30), "变帧率录屏报的平均帧率（7.3）→ 按 30")
    check(OptimizedMediaPolicy.proxyFrameDuration(sourceFPS: 0) == CMTime(value: 1, timescale: 30), "读不出帧率 → 按 30")
    check(OptimizedMediaPolicy.chunkRange(1) == 10...20, "第 1 块是源的 10–20 秒")
    check(OptimizedMediaPolicy.chunks(sourceStart: 12, sourceDuration: 5, sourceLength: 60) == 0...2, "12–17 秒的段用第 1 块，两边各留一块")
    check(OptimizedMediaPolicy.chunks(sourceStart: 55, sourceDuration: 5, sourceLength: 60) == 4...5, "贴着源结尾的段不超过最后一块")
    check(OptimizedMediaPolicy.chunks(sourceStart: 0, sourceDuration: 3, sourceLength: 60) == 0...1, "开头的段只往后留一块")

    // ---- 2. 关键帧间隔：真的扫出来；进 MediaInfo 存盘往返 ----
    print("==> 2. 关键帧间隔：扫采样表不解码，长 GOP 量得出、全帧内是 0；MediaInfo 存盘往返、老工程缺键是 nil")
    let longGOP: URL
    let intra: URL
    do {
        longGOP = try await makeRampVideo(seconds: 12, fps: 30, size: CGSize(width: 640, height: 360), keyframeEvery: 240, name: "long-gop.mp4")
        intra = try await makeRampVideo(seconds: 2, fps: 30, size: CGSize(width: 320, height: 180), keyframeEvery: 1, name: "intra.mp4")
    } catch {
        check(false, "造素材失败：\(error)")
        finish(1)
    }
    let longInterval = await MediaKeyframeProbe.interval(of: longGOP)
    check((longInterval ?? 0) >= 2, "8 秒一个关键帧的源（编码器可以提前，但至少 2 秒）量到 \(longInterval ?? -1)")
    let intraInterval = await MediaKeyframeProbe.interval(of: intra)
    check(intraInterval == 0, "全帧内的源量到 0（实际 \(intraInterval ?? -1)）")
    check(await MediaKeyframeProbe.interval(of: root.appendingPathComponent("nope.mp4")) == nil, "读不出的文件是 nil")
    let probed = await MediaProbe.probe(url: longGOP, ffmpeg: nil)
    if case .success(let probedInfo) = probed {
        check(probedInfo.keyframeInterval == longInterval, "MediaProbe 把关键帧间隔带进 MediaInfo（\(probedInfo.keyframeInterval ?? -1)）")
        let data = try! JSONEncoder().encode(probedInfo)
        let back = try! JSONDecoder().decode(MediaInfo.self, from: data)
        check(back.keyframeInterval == probedInfo.keyframeInterval, "存盘往返保留关键帧间隔")
        check(String(data: data, encoding: .utf8)!.contains("keyframeInterval"), "键写进了 JSON")
    } else {
        check(false, "MediaProbe 探不出素材")
    }
    let legacy = try! JSONDecoder().decode(MediaInfo.self, from: Data("""
    {"duration":4,"displaySize":[1920,1080],"frameRate":30,"videoCodec":"h264","hasAudio":false,"audioCanCopyToMP4":false,"fileBytes":1}
    """.utf8))
    check(legacy.keyframeInterval == nil, "老工程的 info 没有这个键：nil（不知道），不是 0")

    // ---- 3. 解码速度 ----
    print("==> 3. 解码速度：解 120 帧量得出一个正数；记忆的键带机型和系统大版本")
    let fps = await DecodeSpeedProbe.measure(sample: longGOP, frames: 120)
    check((fps ?? 0) > 30, "解码速度量到 \(fps ?? -1) fps（该远大于实时）")
    check(DecodeSpeedProbe.machineKey.hasPrefix("optimizedMedia.decodeFPS."), "键的前缀对")
    let defaults = UserDefaults(suiteName: "srtflow-optimizedmedia-check-\(ProcessInfo.processInfo.processIdentifier)")!
    check(DecodeSpeedProbe.remembered(defaults: defaults) == nil, "没量过就是 nil")
    DecodeSpeedProbe.remember(421, defaults: defaults)
    check(DecodeSpeedProbe.remembered(defaults: defaults) == 421, "记住的读得回来")

    // ---- 4. 转一块 ----
    print("==> 4. 转一块：0.5 秒内必有关键帧、没有 B 帧、尺寸 / 时长 / 帧数对、首尾帧和源一样、不带声音；最后一块到源的结尾")
    OptimizedMediaStore.rootOverride = root.appendingPathComponent("cache", isDirectory: true)
    let loaded = await OptimizedMediaTranscoder.load(longGOP)
    guard case .success(let source) = loaded else {
        check(false, "加载源失败：\(loaded)")
        finish(1)
    }
    nonisolated(unsafe) let transcodeSource = source
    let started = ProcessInfo.processInfo.systemUptime
    let chunk0 = await MediaReadQueue.run(on: MediaReadQueue.proxy) { OptimizedMediaTranscoder.transcode(transcodeSource, chunk: 0) }
    let elapsed = ProcessInfo.processInfo.systemUptime - started
    guard case .success(let chunk0URL) = chunk0 else {
        check(false, "第 0 块转码失败：\(chunk0)")
        finish(1)
    }
    print(String(format: "  第 0 块（10 秒 640×360）转了 %.2f 秒", elapsed))
    if let stats = await passthroughStats(of: longGOP) { check(stats.frames == 360, "素材本身 360 帧（直通读取跳过零采样的标记），实际 \(stats.frames)") }
    let chunkInterval = await MediaKeyframeProbe.interval(of: chunk0URL)
    check((chunkInterval ?? 99) <= OptimizedMediaPolicy.keyframeInterval + 1.0 / 30 + 0.001,
          "块里 0.5 秒内必有关键帧（量到 \(chunkInterval ?? -1)）")
    if let stats = await passthroughStats(of: chunk0URL) {
        check(stats.frames == 300, "第 0 块该有 300 帧（10 秒 × 30），实际 \(stats.frames)")
        check(stats.reordered == 0, "没有 B 帧（解码时间戳 = 显示时间戳），重排的帧 \(stats.reordered)")
    } else {
        check(false, "块读不出采样")
    }
    let chunkAsset = AVURLAsset(url: chunk0URL)
    if let track = try? await chunkAsset.loadTracks(withMediaType: .video).first,
       let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform),
       let duration = try? await chunkAsset.load(.duration) {
        check(natural == CGSize(width: 640, height: 360), "尺寸和源一样（\(natural)）")
        check(transform == source.preferredTransform, "旋转矩阵照抄")
        check(abs(duration.seconds - 10) < 0.05, "第 0 块正好 10 秒（\(duration.seconds)）")
    } else {
        check(false, "块读不出画面轨")
    }
    check(((try? await chunkAsset.loadTracks(withMediaType: .audio))?.isEmpty) ?? false, "块不带声音")
    let sourceHead = await brightness(of: longGOP, at: 0.5), chunkHead = await brightness(of: chunk0URL, at: 0.5)
    let sourceTail = await brightness(of: longGOP, at: 9.5), chunkTail = await brightness(of: chunk0URL, at: 9.5)
    check(abs(sourceHead - chunkHead) < 0.05, String(format: "0.5 秒处的画面和源一样（源 %.3f、块 %.3f）", sourceHead, chunkHead))
    check(abs(sourceTail - chunkTail) < 0.05, String(format: "9.5 秒处的画面和源一样（源 %.3f、块 %.3f）", sourceTail, chunkTail))
    check(sourceTail - sourceHead > 0.5, "素材本身是从黑到白的渐变（否则上面两条没意义）")
    check(OptimizedMediaStore.chunkURL(for: longGOP, chunk: 0) == chunk0URL, "缓存里记下了第 0 块")
    let chunk1 = await MediaReadQueue.run(on: MediaReadQueue.proxy) { OptimizedMediaTranscoder.transcode(transcodeSource, chunk: 1) }
    if case .success(let chunk1URL) = chunk1, let duration = try? await AVURLAsset(url: chunk1URL).load(.duration) {
        check(abs(duration.seconds - 2) < 0.05, "最后一块到源的结尾：12 秒的源第 1 块是 2 秒（\(duration.seconds)）")
        let tail = await brightness(of: chunk1URL, at: 1.5)
        let sourceAt11_5 = await brightness(of: longGOP, at: 11.5)
        check(abs(tail - sourceAt11_5) < 0.05, String(format: "第 1 块的 1.5 秒 = 源的 11.5 秒（%.3f vs %.3f）", tail, sourceAt11_5))
    } else {
        check(false, "第 1 块转码失败：\(chunk1)")
    }
    let chunk2 = await MediaReadQueue.run(on: MediaReadQueue.proxy) { OptimizedMediaTranscoder.transcode(transcodeSource, chunk: 2) }
    if case .failure = chunk2 { check(true, "") } else { check(false, "源结尾之外的块该失败") }
    var cancelled = false
    let cancelledResult = await MediaReadQueue.run(on: MediaReadQueue.proxy) {
        OptimizedMediaTranscoder.transcode(transcodeSource, chunk: 0, isCancelled: { cancelled = true; return true })
    }
    check(cancelledResult == .failure(.cancelled) && cancelled, "取消标记一亮就停、报 cancelled")
    check(OptimizedMediaStore.chunkURL(for: longGOP, chunk: 0) == chunk0URL, "取消的那次不碰已有的块")

    // ---- 4b. 变帧率的源（录屏：静止期没有帧）+ 块头落在两帧之间 ----
    print("==> 4b. 变帧率的源：静止期没有帧也要连续盖住整块、块头那一帧对齐块头、块尾到源结尾")
    do {
        // 12 秒 30 fps，每帧往后挪 1/60 秒（块头 10.0 落在两帧之间），第 60–239 帧（2–8 秒）不写。
        let vfr = try await makeRampVideo(
            seconds: 12, fps: 30, size: CGSize(width: 64, height: 36), keyframeEvery: 300, name: "vfr.mp4",
            firstFrameOffset: CMTime(value: 1, timescale: 60), gap: 60..<240
        )
        guard case .success(let source) = await OptimizedMediaTranscoder.load(vfr) else {
            check(false, "变帧率的源 load 失败")
            finish(1)
        }
        // 源一共 12 + 1/60 秒（每帧都挪了 1/60）：第 0 块 10 秒整、第 1 块到源结尾 2 + 1/60 秒。帧在 30 fps 的格子上，
        // 合成器只在画面变了才出一帧：第 0 块 0.0 … 2.0 共 61 帧 + 8.033 … 9.967 共 59 帧 = 120 帧（静止期 2.0 那一帧撑 6 秒）；
        // 第 1 块 10.0 … 12.0 共 61 帧。
        for chunk in 0...1 {
            let result = await MediaReadQueue.run(on: MediaReadQueue.proxy) { OptimizedMediaTranscoder.transcode(source, chunk: chunk) }
            guard case .success(let url) = result else {
                check(false, "变帧率的源第 \(chunk) 块转不出来：\(result)")
                continue
            }
            let asset = AVURLAsset(url: url)
            let track = try? await asset.loadTracks(withMediaType: .video).first
            let range = (try? await track?.load(.timeRange)) ?? .invalid
            let expected = min(10.0, source.duration - Double(chunk) * 10)
            let expectedFrames = chunk == 0 ? 120 : 61
            check(abs(range.start.seconds) < 0.0001, "第 \(chunk) 块的轨从 0 起（块头那一帧挪到了块头），实测 \(range.start.seconds)")
            check(abs(range.duration.seconds - expected) < 0.002, "第 \(chunk) 块正好 \(expected) 秒（到源结尾），实测 \(range.duration.seconds)")
            let stats = await passthroughStats(of: url)
            check(stats?.frames == expectedFrames, "第 \(chunk) 块 \(expectedFrames) 帧（画面变了才出帧、静止期一帧撑住），实测 \(stats?.frames ?? -1)")
            if chunk == 0 {
                // 静止期（2–8 秒）里显示的是第 59 帧（灰度 59/359）；块尾 9.5 秒是第 285 帧。
                let during = await brightness(of: url, at: 5.0)
                check(abs(during - 59.0 / 359) < 0.06, "静止期里的画面是停住前的最后一帧，实测 \(during)（应约 \(59.0 / 359)）")
                let late = await brightness(of: url, at: 9.5)
                check(abs(late - 285.0 / 359) < 0.06, "块尾 9.5 秒的画面对（第 285 帧），实测 \(late)")
            }
        }
    }

    // ---- 4c. 整块都在静止期里 + 29.97 fps 的格子 ----
    print("==> 4c. 整块都在静止期里只有块头那一帧也要盖住整块；29.97 的源块头落在两帧之间也从 0 起")
    do {
        // 25 秒的源，第 60–659 帧（2–22 秒）不写：第 1 块 [10, 20) 整块在静止期里。
        let idle = try await makeRampVideo(seconds: 25, fps: 30, size: CGSize(width: 64, height: 36), keyframeEvery: 300, name: "idle.mp4", gap: 60..<660)
        if case .success(let source) = await OptimizedMediaTranscoder.load(idle) {
            let result = await MediaReadQueue.run(on: MediaReadQueue.proxy) { OptimizedMediaTranscoder.transcode(source, chunk: 1) }
            if case .success(let url) = result {
                let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first
                let range = (try? await track?.load(.timeRange)) ?? .invalid
                check(abs(range.start.seconds) < 0.0001 && abs(range.duration.seconds - 10) < 0.002,
                      "整块都在静止期里的第 1 块正好 10 秒（实测 \(range.start.seconds) + \(range.duration.seconds)）")
                let stats = await passthroughStats(of: url)
                check(stats?.frames == 1, "整块都在静止期里：只有块头那一帧（实测 \(stats?.frames ?? -1)）")
                let shown = await brightness(of: url, at: 5.0)
                check(abs(shown - 59.0 / 749) < 0.06, "静止期里显示的是停住前的那一帧（灰度 59/749），实测 \(shown)")
            } else {
                check(false, "整块都在静止期里的第 1 块转不出来：\(result)")
            }
        } else {
            check(false, "静止期的源 load 失败")
        }
        // 29.97 fps：帧在 k × 1001/30000 上，块头 10 秒落在两帧之间（9.977 和 10.010）。
        let ntsc = try await makeRampVideo(seconds: 12, fps: 30, size: CGSize(width: 64, height: 36), keyframeEvery: 300, name: "ntsc.mp4",
                                           frameDuration: CMTime(value: 1001, timescale: 30000))
        if case .success(let source) = await OptimizedMediaTranscoder.load(ntsc) {
            check(OptimizedMediaPolicy.proxyFrameDuration(sourceFPS: source.nominalFrameRate) == CMTime(value: 1001, timescale: 30000),
                  "29.97 的源按 1001/30000 的格子（标称 \(source.nominalFrameRate)）")
            let result = await MediaReadQueue.run(on: MediaReadQueue.proxy) { OptimizedMediaTranscoder.transcode(source, chunk: 1) }
            if case .success(let url) = result {
                let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first
                let range = (try? await track?.load(.timeRange)) ?? .invalid
                check(abs(range.start.seconds) < 0.0001, "29.97 的源第 1 块的轨从 0 起（块头先出一帧），实测 \(range.start.seconds)")
                check(abs(range.duration.seconds - (source.duration - 10)) < 0.002, "29.97 的源第 1 块到源结尾，实测 \(range.duration.seconds)")
                let stats = await passthroughStats(of: url)
                check(stats?.frames == 60, "29.97 的源第 1 块 60 帧（块头一帧 + 格子上的 59 帧），实测 \(stats?.frames ?? -1)")
            } else {
                check(false, "29.97 的源第 1 块转不出来：\(result)")
            }
        } else {
            check(false, "29.97 的源 load 失败")
        }
    }

    // ---- 5. 缓存 ----
    print("==> 5. 缓存：身份变了作废、版本变了作废、索引坏了当没转过、超过上限丢最久没用的、太久不用的删掉")
    guard let identity = OptimizedMediaStore.SourceIdentity(url: longGOP) else { check(false, "拿不到身份"); finish(1) }
    let before = OptimizedMediaStore.totalBytes()
    check(before > 0, "总量按索引算出来（\(before) 字节）")
    // 身份变了（原地改写：大小 / 修改时间变）
    let copy = root.appendingPathComponent("copy.mp4")
    try! FileManager.default.copyItem(at: longGOP, to: copy)
    let copyIdentity = OptimizedMediaStore.SourceIdentity(url: copy)!
    check(copyIdentity.key != identity.key, "另一个文件是另一份缓存（路径在身份里）")
    let fake = OptimizedMediaStore.temporaryURL(for: copyIdentity)
    try! Data(repeating: 1, count: 1_000_000).write(to: fake)
    _ = try! OptimizedMediaStore.commit(chunk: 0, temporary: fake, for: copyIdentity, now: Date(timeIntervalSinceNow: -100))
    check(OptimizedMediaStore.chunkURL(for: copy, chunk: 0) != nil, "假块记进了索引")
    let handle = try! FileHandle(forWritingTo: copy)
    try! handle.seekToEnd()
    try! handle.write(contentsOf: Data([0]))
    try! handle.close()
    check(OptimizedMediaStore.chunkURL(for: copy, chunk: 0) == nil, "原地改写过（大小变了）→ 旧块不算数")
    check(!FileManager.default.fileExists(atPath: OptimizedMediaStore.directory(for: copyIdentity).path), "作废的目录顺手删掉")
    // 版本变了
    let staleDirectory = OptimizedMediaStore.directory(for: identity)
    let indexFile = staleDirectory.appendingPathComponent("index.json")
    var json = try! JSONSerialization.jsonObject(with: Data(contentsOf: indexFile)) as! [String: Any]
    json["parametersVersion"] = OptimizedMediaStore.parametersVersion + 1
    try! JSONSerialization.data(withJSONObject: json).write(to: indexFile)
    check(OptimizedMediaStore.chunkURL(for: longGOP, chunk: 0) == nil, "参数版本对不上 → 当没转过")
    check(!FileManager.default.fileExists(atPath: staleDirectory.path), "版本不对的目录删掉")
    // 索引坏了
    try! FileManager.default.createDirectory(at: staleDirectory, withIntermediateDirectories: true)
    try! Data("garbage".utf8).write(to: indexFile)
    check(OptimizedMediaStore.chunkURL(for: longGOP, chunk: 0) == nil && OptimizedMediaStore.index(for: longGOP) == nil, "索引坏了当没转过")
    try? FileManager.default.removeItem(at: staleDirectory)
    // 上限：三块各 1 MB，上限 2.5 MB → 最久没用的那块没了。先清空（4b 的变帧率源也在这个缓存根下，它的块不算进来）。
    OptimizedMediaStore.removeAll()
    let now = Date()
    for (chunk, age) in [(0, 300.0), (1, 200.0), (2, 100.0)] {
        let temp = OptimizedMediaStore.temporaryURL(for: identity)
        try! Data(repeating: UInt8(chunk), count: 1_000_000).write(to: temp)
        _ = try! OptimizedMediaStore.commit(chunk: chunk, temporary: temp, for: identity, now: now.addingTimeInterval(-age))
    }
    check(OptimizedMediaStore.totalBytes() == 3_000_000, "三块共 3 MB")
    OptimizedMediaStore.enforceCapacity(limit: 2_500_000, now: now)
    check(OptimizedMediaStore.chunkURL(for: longGOP, chunk: 0) == nil, "超过上限：最久没用的第 0 块丢了")
    check(OptimizedMediaStore.chunkURL(for: longGOP, chunk: 1) != nil && OptimizedMediaStore.chunkURL(for: longGOP, chunk: 2) != nil, "另外两块还在")
    check(OptimizedMediaStore.totalBytes() == 2_000_000, "总量跟着改（\(OptimizedMediaStore.totalBytes())）")
    OptimizedMediaStore.touch(longGOP, chunks: [1], now: now)
    OptimizedMediaStore.enforceCapacity(limit: 1_500_000, now: now)
    check(OptimizedMediaStore.chunkURL(for: longGOP, chunk: 1) != nil && OptimizedMediaStore.chunkURL(for: longGOP, chunk: 2) == nil,
          "刚用过的第 1 块留下，第 2 块丢了（LRU 看最后用到的时间）")
    OptimizedMediaStore.expire(olderThan: 30, now: now.addingTimeInterval(31 * 86_400))
    check(OptimizedMediaStore.chunkURL(for: longGOP, chunk: 1) == nil, "31 天没用的块删掉")
    check(!FileManager.default.fileExists(atPath: OptimizedMediaStore.directory(for: identity).path), "空了的源目录删掉")

    // ---- 5b. V3：上限从设置读、几档、过期的天数、清空 ----
    print("==> 5b. 上限：没设过是默认 10 GB、设了读得回来、低于下限按下限；几档含默认；过期 30 天；清空之后总量 0、目录没了、再落块照样行")
    let capacitySuite = "srtflow-optimizedmedia-capacity-\(ProcessInfo.processInfo.processIdentifier)"
    let capacityDefaults = UserDefaults(suiteName: capacitySuite)!
    capacityDefaults.removePersistentDomain(forName: capacitySuite)
    check(OptimizedMediaStore.defaultCapacityBytes == 10_000_000_000, "默认 10 GB（十进制：设置里显示的、访达里看到的都是十进制）")
    check(OptimizedMediaStore.capacityBytes(in: capacityDefaults) == OptimizedMediaStore.defaultCapacityBytes, "没设过就是默认")
    OptimizedMediaStore.setCapacityBytes(5_000_000_000, in: capacityDefaults)
    check(OptimizedMediaStore.capacityBytes(in: capacityDefaults) == 5_000_000_000, "设了 5 GB 读回 5 GB")
    OptimizedMediaStore.setCapacityBytes(1, in: capacityDefaults)
    check(OptimizedMediaStore.capacityBytes(in: capacityDefaults) == OptimizedMediaStore.minimumCapacityBytes,
          "设得低于下限按下限（\(OptimizedMediaStore.minimumCapacityBytes)）")
    capacityDefaults.set(Int64(0), forKey: OptimizedMediaStore.capacityDefaultsKey)
    check(OptimizedMediaStore.capacityBytes(in: capacityDefaults) == OptimizedMediaStore.minimumCapacityBytes,
          "别处直接写了 0 也按下限（0 会把刚转好的块当场丢掉）")
    check(OptimizedMediaStore.capacityPresets.contains(OptimizedMediaStore.defaultCapacityBytes), "几档里有默认那一档")
    check(OptimizedMediaStore.capacityPresets == OptimizedMediaStore.capacityPresets.sorted()
              && OptimizedMediaStore.capacityPresets.allSatisfy { $0 >= OptimizedMediaStore.minimumCapacityBytes },
          "几档从小到大、都不低于下限")
    check(OptimizedMediaStore.expiryDays == 30, "过期的天数是 30")
    // 清空：先落两块，清空之后总量 0、根目录没了、块查不到；再落一块照样进得去（目录重建、索引重写）。
    for chunk in 0...1 {
        let temp = OptimizedMediaStore.temporaryURL(for: identity)
        try! Data(repeating: 7, count: 100_000).write(to: temp)
        _ = try! OptimizedMediaStore.commit(chunk: chunk, temporary: temp, for: identity, now: now)
    }
    check(OptimizedMediaStore.totalBytes() == 200_000, "清空前两块 200 KB（\(OptimizedMediaStore.totalBytes())）")
    OptimizedMediaStore.removeAll()
    check(OptimizedMediaStore.totalBytes() == 0, "清空之后总量 0（\(OptimizedMediaStore.totalBytes())）")
    check(!FileManager.default.fileExists(atPath: OptimizedMediaStore.effectiveRoot.path), "清空之后缓存根目录没了")
    check(OptimizedMediaStore.chunkURL(for: longGOP, chunk: 0) == nil, "清空之后块查不到")
    let again = OptimizedMediaStore.temporaryURL(for: identity)
    try! Data(repeating: 8, count: 100_000).write(to: again)
    let landed = try? OptimizedMediaStore.commit(chunk: 3, temporary: again, for: identity, now: now)
    check(landed != nil && OptimizedMediaStore.chunkURL(for: longGOP, chunk: 3) != nil && OptimizedMediaStore.totalBytes() == 100_000,
          "清空之后再落一块照样进得去（目录重建、索引重写）")
    // 过期按 expiryDays：29 天没用的留着，31 天的删（上面第 5 组验过 31 天那条，这里钉的是天数常量真的被用上）。
    OptimizedMediaStore.expire(olderThan: OptimizedMediaStore.expiryDays, now: now.addingTimeInterval(29 * 86_400))
    check(OptimizedMediaStore.chunkURL(for: longGOP, chunk: 3) != nil, "29 天没用的块留着")
    OptimizedMediaStore.expire(olderThan: OptimizedMediaStore.expiryDays, now: now.addingTimeInterval(31 * 86_400))
    check(OptimizedMediaStore.chunkURL(for: longGOP, chunk: 3) == nil, "31 天没用的块按 expiryDays 删掉")
    _ = intra

    print("\(checks) checks, \(failures) failures")
    if failures == 0 { print("All checks passed") }
    semaphore.signal()
}
semaphore.wait()
finish(failures == 0 ? 0 : 1)
