import AVFoundation
import Foundation

// **波形数据（多级峰值）的真实回归**：素材是 ffmpeg 现造的、每个采样都知道该是多少，
// 读法走生产的 `WaveformStore` → `WaveformDecoder` → `ChunkBuilder` 整条路。
//
// 守的是界面看不出来、却会让波形说谎的那几件事：声道没分开、粗的几级把尖峰平均掉了、
// 块与块的接缝上丢了峰值、5.1 素材读成了单声道或读不出来。
// 长期约束见 docs/architecture/audio-waveform.md。

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
    .appendingPathComponent("srtflow-waveform-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

func finish(_ code: Int32) -> Never {
    try? FileManager.default.removeItem(at: root)
    exit(code)
}

/// 用 `aevalsrc` 按表达式造一段 48kHz 的 f32 WAV（每个采样都是算出来的，量得准）。
func make(_ name: String, exprs: String, seconds: Double, layout: String? = nil) -> URL {
    let url = root.appendingPathComponent(name)
    var source = "aevalsrc=exprs='\(exprs)':s=48000:d=\(seconds)"
    if let layout { source += ":c=\(layout)" }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: ffmpegPath)
    process.arguments = ["-y", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", source,
                         "-c:a", "pcm_f32le", url.path]
    let pipe = Pipe()
    process.standardError = pipe
    try? process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        let log = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        print("造素材失败（\(name)）：\(log)")
    }
    return url
}

/// 把一个文件的波形读完，返回最后一份快照（读不了返回 nil）。
func readAll(_ url: URL) async -> (last: WaveformPeaks?, count: Int) {
    var last: WaveformPeaks?
    var count = 0
    for await snapshot in await WaveformStore.shared.peaks(for: url) {
        last = snapshot
        count += 1
    }
    return (last, count)
}

func near(_ a: Float, _ b: Float, _ tolerance: Float = 0.01) -> Bool { abs(a - b) <= tolerance }

/// 死锁时 `await` 永远不回来，整个自检就挂在那儿 —— 挂住不是失败，CI 只会等到超时。
/// 看门狗到点还没被解除就判红退出。它必须是**普通线程**：死锁的正是 Swift 并发的
/// 线程池，放在池子里的看门狗自己也会被饿死。
final class Watchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var disarmed = false

    init(seconds: Double, _ message: String) {
        Thread.detachNewThread { [self] in
            Thread.sleep(forTimeInterval: seconds)
            lock.lock()
            let fire = !disarmed
            lock.unlock()
            guard fire else { return }
            print("FAIL \(message)")
            finish(1)
        }
    }

    func disarm() {
        lock.lock()
        disarmed = true
        lock.unlock()
    }
}

func main() async {
    guard FileManager.default.isExecutableFile(atPath: ffmpegPath) else {
        print("找不到 ffmpeg：\(ffmpegPath)（跑 scripts/vendor-ffmpeg.sh，或设 SRTFLOW_FFMPEG）")
        finish(1)
    }

    // ---- 1. 立体声：两个声道各是各的，合并时取两者的包络 ----
    // L = 0.5 正弦、R = 0.25 正弦（前 3 秒）；3.5s 处两个声道各一个 0.9 的单采样尖峰；其余静音。
    let spikeFrame = 168_000
    let stereo = make(
        "stereo.wav",
        exprs: "if(lt(t,3),0.5*sin(2*PI*440*t),if(eq(n,\(spikeFrame)),0.9,0))"
            + "|if(lt(t,3),0.25*sin(2*PI*440*t),if(eq(n,\(spikeFrame)),0.9,0))",
        seconds: 4
    )
    let (peaksOrNil, _) = await readAll(stereo)
    guard let peaks = peaksOrNil else {
        check(false, "立体声素材读不出波形"); finish(1)
    }
    check(peaks.isComplete, "读完的快照要标成完整")
    check(peaks.channelCount == 2, "立体声读成两个声道（量到 \(peaks.channelCount)）")
    check(peaks.sampleRate == 48_000, "采样率按素材原样（量到 \(peaks.sampleRate)）")
    check(peaks.framesAvailable == 192_000, "4 秒 = 192000 帧，一帧不多一帧不少（量到 \(peaks.framesAvailable)）")

    if let left = peaks.extremes(channel: 0, from: 24_000, to: 48_000, level: 0),
       let right = peaks.extremes(channel: 1, from: 24_000, to: 48_000, level: 0),
       let merged = peaks.extremes(channel: nil, from: 24_000, to: 48_000, level: 0) {
        check(near(left.max, 0.5) && near(left.min, -0.5), "左声道是 ±0.5（量到 \(left)）")
        check(near(right.max, 0.25) && near(right.min, -0.25), "右声道是 ±0.25，没被左声道串进来（量到 \(right)）")
        check(near(merged.max, 0.5) && near(merged.min, -0.5), "合成一条时取两个声道的包络（量到 \(merged)）")
    } else {
        check(false, "有声的那一段取不出峰值")
    }
    if let silence = peaks.extremes(channel: nil, from: 150_000, to: 160_000, level: 0) {
        check(abs(silence.max) < 0.001 && abs(silence.min) < 0.001, "静音段就是 0（量到 \(silence)）")
    }
    // 单采样的尖峰在每一级都得看得见：粗的几级是 min/max 合并，不是平均。
    for level in 0..<WaveformPeaks.levelCount {
        let range = peaks.extremes(channel: 1, from: 160_000, to: 176_000, level: level)
        check(near(range?.max ?? 0, 0.9), "第 \(level) 级也看得见那个单采样尖峰（量到 \(String(describing: range))）")
    }

    // ---- 2. 选级：最粗、但一个桶不超过一个像素的那一级 ----
    check(WaveformPeaks.level(forFramesPerPixel: 10) == 0, "一个像素 10 个采样 → 第 0 级")
    check(WaveformPeaks.level(forFramesPerPixel: 300) == 1, "一个像素 300 个采样 → 第 1 级（256）")
    check(WaveformPeaks.level(forFramesPerPixel: 5000) == 3, "一个像素 5000 个采样 → 第 3 级（4096）")
    check(WaveformPeaks.level(forFramesPerPixel: 1e9) == WaveformPeaks.levelCount - 1, "再粗也不超过最粗那一级")

    // ---- 3. 长素材：跨块的接缝上不许丢峰值 ----
    // 一块 = 1048576 帧。接缝两侧各放一个单采样尖峰（一正一负）。
    let boundary = WaveformPeaks.framesPerChunk
    let long = make(
        "long.wav",
        exprs: "if(eq(n,\(boundary - 1)),-0.7,if(eq(n,\(boundary)),0.6,0))",
        seconds: 50
    )
    if let longPeaks = await readAll(long).last {
        check(longPeaks.chunks.count == 3, "50 秒 = 2 整块 + 1 块零头（量到 \(longPeaks.chunks.count)）")
        check(longPeaks.framesAvailable == 2_400_000, "长素材的帧数对得上（量到 \(longPeaks.framesAvailable)）")
        let across = longPeaks.extremes(channel: nil, from: boundary - 500, to: boundary + 500, level: 0)
        check(near(across?.max ?? 0, 0.6) && near(across?.min ?? 0, -0.7),
              "跨块取峰值：接缝两侧的尖峰都在（量到 \(String(describing: across))）")
        let coarse = longPeaks.extremes(channel: nil, from: 0, to: 2_400_000, level: WaveformPeaks.levelCount - 1)
        check(near(coarse?.max ?? 0, 0.6) && near(coarse?.min ?? 0, -0.7),
              "缩到最小时整条也看得见两个尖峰（量到 \(String(describing: coarse))）")
    } else {
        check(false, "长素材读不出波形")
    }

    // ---- 4. 5.1：读的时候混成立体声，不许读成空的 ----
    let surround = make(
        "surround.wav",
        exprs: "0.4*sin(2*PI*440*t)|0.4*sin(2*PI*440*t)|0|0|0|0",
        seconds: 1,
        layout: "5.1"
    )
    if let surroundPeaks = await readAll(surround).last {
        check(surroundPeaks.channelCount == 2, "5.1 混成两个声道（量到 \(surroundPeaks.channelCount)）")
        let range = surroundPeaks.extremes(channel: nil, from: 0, to: 48_000, level: 0)
        check((range?.max ?? 0) > 0.1, "混出来的立体声有声音（量到 \(String(describing: range))）")
    } else {
        check(false, "5.1 素材读不出波形")
    }

    // ---- 4b. 深度放大时的原始采样块：按秒切、时间戳按读出来的算 ----
    // 第 3 块 = 第 144000…192000 帧，尖峰在第 168000 帧（右声道 0.9）。
    let detail = WaveformDetailCache.shared
    detail.request(url: stereo, indices: 3...3, sampleRate: 48_000, channels: 2)
    var tile: WaveformDetailTile?
    for _ in 0..<100 where tile == nil {
        try? await Task.sleep(nanoseconds: 20_000_000)
        tile = detail.tile(url: stereo, index: 3)
    }
    if let tile {
        check(tile.startFrame == 144_000, "第 3 块从第 144000 帧起（量到 \(tile.startFrame)）")
        check(tile.frameCount == 48_000, "一块一秒 = 48000 帧（量到 \(tile.frameCount)）")
        let spike = tile.extremes(channel: 1, from: spikeFrame, to: spikeFrame + 1)
        check(near(spike?.max ?? 0, 0.9), "原始采样里那个尖峰就在第 168000 帧（量到 \(String(describing: spike))）")
        let quiet = tile.extremes(channel: nil, from: spikeFrame + 10, to: spikeFrame + 2000)
        check(abs(quiet?.max ?? 1) < 0.001, "尖峰之后是静音（量到 \(String(describing: quiet))）")
    } else {
        check(false, "原始采样块两秒内没读回来")
    }
    // 第 0 块：左声道是 ±0.5 的正弦，原样读得出来（单采样精度，不是 64 采样的桶）。
    detail.request(url: stereo, indices: 0...0, sampleRate: 48_000, channels: 2)
    var head: WaveformDetailTile?
    for _ in 0..<100 where head == nil {
        try? await Task.sleep(nanoseconds: 20_000_000)
        head = detail.tile(url: stereo, index: 0)
    }
    if let head {
        // 440Hz 的四分之一个周期 ≈ 27 帧：峰值在第 27 帧附近，第 0 帧是 0。
        let first = head.extremes(channel: 0, from: 0, to: 1)
        let crest = head.extremes(channel: 0, from: 20, to: 35)
        check(abs(first?.max ?? 1) < 0.01, "第 0 帧是正弦的起点 0（量到 \(String(describing: first))）")
        check(near(crest?.max ?? 0, 0.5), "四分之一周期处到峰值 0.5（量到 \(String(describing: crest))）")
    } else {
        check(false, "第 0 块两秒内没读回来")
    }

    // ---- 5. 同一个文件第二次要：直接拿缓存，一次就给完整的 ----
    let again = await readAll(stereo)
    check(again.count == 1 && again.last?.isComplete == true, "读过的文件再要一次，直接给完整快照")

    // ---- 6. 读不了的文件：一份快照都不给，流照样结束（界面不会一直等）----
    let bogus = root.appendingPathComponent("not-audio.m4a")
    try? Data("definitely not audio".utf8).write(to: bogus)
    let none = await readAll(bogus)
    check(none.last == nil && none.count == 0, "读不了的文件不交快照，流也要结束")

    // ---- 7. 很多文件同时读（打开工程就是这样）：全部读完，不许把线程池堵死 ----
    // 2026-09-23 事故：读 PCM 的阻塞循环跑在 Swift 并发的协作线程池里，同一档 QoS 下同时读的
    // 文件一凑满 CPU 核数（8 核机器上 7 个没事、8 个就死锁），整档 QoS 从此什么都不跑 ——
    // 打开 43 个素材的工程，波形和缩略图全空。上面几节一次只读一个文件，所以一直是绿的。
    // 文件数取核数的两倍（至少 16），哪台机器都盖得过线程池的宽度；封顶 40 是因为下面还要
    // 往原始采样块缓存里放同样多块，那边最多留 48 块。
    let cores = ProcessInfo.processInfo.activeProcessorCount
    let crowd = min(40, max(16, 2 * cores))
    let seed = make("crowd.wav", exprs: "0.5*sin(2*PI*440*t)|0.25*sin(2*PI*440*t)", seconds: 0.5)
    // 仓库按文件认：同一份内容拷成不同的文件，才是「不同的素材一起读」。
    let crowdFiles: [URL] = (0..<crowd).map { index in
        let copy = root.appendingPathComponent("crowd-\(index).wav")
        try? FileManager.default.copyItem(at: seed, to: copy)
        return copy
    }
    let overviewWatchdog = Watchdog(
        seconds: 30,
        "同时读 \(crowd) 个文件的波形（\(cores) 核），30 秒没读完：读取把线程池堵死了（MediaReadQueue 没接上？）"
    )
    let completed = await withTaskGroup(of: Bool.self) { group in
        for url in crowdFiles {
            group.addTask { await readAll(url).last?.isComplete == true }
        }
        var count = 0
        for await ok in group where ok { count += 1 }
        return count
    }
    overviewWatchdog.disarm()
    check(completed == crowd, "同时读 \(crowd) 个文件，每个都读完（读完 \(completed) 个）")

    // 深度放大的原始采样块同一个道理（在 userInitiated 那一档）：一次要这么多个文件的块。
    let detailWatchdog = Watchdog(
        seconds: 30,
        "同时要 \(crowd) 个文件的原始采样块（\(cores) 核），30 秒没读完：读取把线程池堵死了（MediaReadQueue 没接上？）"
    )
    for url in crowdFiles {
        detail.request(url: url, indices: 0...0, sampleRate: 48_000, channels: 2)
    }
    var tilesReady = 0
    for _ in 0..<1000 {
        tilesReady = crowdFiles.filter { detail.tile(url: $0, index: 0) != nil }.count
        if tilesReady == crowd { break }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    detailWatchdog.disarm()
    check(tilesReady == crowd, "同时要 \(crowd) 个文件的原始采样块，每块都读回来（读回 \(tilesReady) 块）")

    print("\(checks) checks, \(failures) failures")
    if failures == 0 { print("All checks passed") }
    finish(failures == 0 ? 0 : 1)
}

let semaphore = DispatchSemaphore(value: 0)
Task { await main(); semaphore.signal() }
semaphore.wait()
