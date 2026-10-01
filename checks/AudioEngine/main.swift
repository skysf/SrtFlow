import AVFoundation
import Foundation
import SrtFlowCore

// **音频引擎的等价自检**：同一条时间线，AVFoundation 那份混音（今天的预览和成片）和引擎离线渲染出来的声音
// 逐 10 ms 窗口比 RMS，差不许超过容差；一边有声一边静音算错；引擎渲染期间不许欠载。
// 素材是现造的恒定振幅正弦（check-audio-fade 同一套），两边的差只能来自混音本身。
// 编译方式见 scripts/check-audio-engine.sh；方案见 docs/plans/2026-10-01-audio-engine.md。

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
    .appendingPathComponent("srtflow-audioengine-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

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

/// 恒定振幅的 4 秒正弦（振幅 0.5，免得两段相加过顶）。
func makeTone(_ name: String, frequency: Int, withVideo: Bool, sampleRate: Int = 48_000, channels: Int = 2) -> URL {
    let url = root.appendingPathComponent(name)
    var args = [
        "-y", "-hide_banner", "-loglevel", "error",
        "-f", "lavfi", "-i", "sine=frequency=\(frequency):duration=4:sample_rate=\(sampleRate)",
    ]
    if withVideo {
        args += ["-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30:duration=4"]
        args += ["-map", "1:v", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-map", "0:a"]
    }
    args += ["-af", "volume=0.5", "-c:a", "aac", "-b:a", "192k", "-ac", "\(channels)", "-t", "4", url.path]
    let (code, out) = run(ffmpegPath, args)
    if code != 0 { print("造素材失败：\(out)") }
    return url
}

// MARK: - 两条管线

/// 参照：真实的合成 + audioMix，经 AVAssetReaderAudioMixOutput 读成立体声。
func referencePCM(_ state: TimelineState) async -> Stereo? {
    guard let built = await VideoEditCompositionBuilder.build(from: state) else { return Stereo() }
    guard let tracks = try? await built.composition.loadTracks(withMediaType: .audio), !tracks.isEmpty,
          let reader = try? AVAssetReader(asset: built.composition) else { return Stereo() }
    let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
    ])
    output.audioMix = built.audioMix
    output.audioTimePitchAlgorithm = VideoEditCompositionBuilder.timePitchAlgorithm
    guard reader.canAdd(output) else { return nil }
    reader.add(output)
    guard reader.startReading() else { return nil }
    var pcm = Stereo()
    while let buffer = output.copyNextSampleBuffer() {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
        let length = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: length)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes) == kCMBlockBufferNoErr
        else { continue }
        bytes.withUnsafeBytes { raw in
            let floats = raw.bindMemory(to: Float.self)
            pcm.append(interleaved: floats, frames: floats.count / 2)
        }
    }
    return pcm
}

/// 引擎：同一份时间线算出配置，离线渲到总长。
func enginePCM(_ state: TimelineState) -> (pcm: Stereo, config: AudioEngineConfig, underruns: Int)? {
    let config = AudioEngineConfig.make(from: state)
    guard let engine = try? TimelineAudioEngine(config: config, mode: .offline) else { return nil }
    var pcm = Stereo()
    do {
        try engine.renderOffline(duration: state.duration) { interleaved, frames in
            pcm.append(interleaved: interleaved, frames: frames)
        }
    } catch {
        print("引擎渲染失败：\(error)")
        return nil
    }
    return (pcm, config, engine.underrunFrames)
}

/// 一组：两边都算出来，逐窗口比。
func compare(_ label: String, _ state: TimelineState, tolerance: Double = 0.15, expectSilent: Bool = false) async {
    guard let reference = await referencePCM(state) else {
        check(false, "\(label)：参照读不出来")
        return
    }
    guard let engine = enginePCM(state) else {
        check(false, "\(label)：引擎渲不出来")
        return
    }
    let expected = Int((state.duration * 48_000).rounded())
    check(abs(engine.pcm.frames - expected) <= 1, "\(label)：引擎该正好渲 \(expected) 帧，渲了 \(engine.pcm.frames)")
    check(engine.underruns == 0, "\(label)：离线渲染不许欠载，欠了 \(engine.underruns) 帧")
    let boundaries = engine.config.tracks.flatMap { $0.segments.flatMap { [$0.start, $0.end] } }
    let result = compareWindows(reference: reference, engine: engine.pcm, boundaries: boundaries, tolerance: tolerance)
    let total = rmsDB(engine.pcm.left)
    if expectSilent {
        check(total < -60, "\(label)：引擎该全静音，整段 RMS \(total) dB")
        check(rmsDB(reference.left) < -60, "\(label)：参照也该全静音")
    } else {
        // 素材是 −30 dBFS 左右的正弦，再乘推子会到 −40：门槛放在 −50，静音是 −60 以下。
        check(total > -50, "\(label)：引擎不该是静音（整段 RMS \(total) dB）—— 比对无从谈起")
        check(abs(rmsDB(reference.left) - total) < 0.1, "\(label)：整段 RMS 两边该一样（参照 \(rmsDB(reference.left))，引擎 \(total)）")
    }
    check(result.compared > 0, "\(label)：一个窗口都没比到")
    check(result.failures.isEmpty, "\(label)：\(result.failures.count) 个窗口对不上，前几个：\(result.failures.prefix(4))")
    print(String(format: "  %@：比了 %d 个窗口（跳过边界 %d），最大差 %.3f dB，引擎整段 %.1f dB", label, result.compared, result.skipped, result.maxDiffDB, total))
}

// MARK: - 跑

let toneA = makeTone("a-440.mp4", frequency: 440, withVideo: true)
let toneB = makeTone("b-660.mp4", frequency: 660, withVideo: true)
let toneC = makeTone("c-880.m4a", frequency: 880, withVideo: false)
let toneD = makeTone("d-330.m4a", frequency: 330, withVideo: false)
let toneMono = makeTone("mono-44k.m4a", frequency: 550, withVideo: false, sampleRate: 44_100, channels: 1)

print("==> 1. 一条音频轨一段 + 轨道推子 + 总推子")
await compare("音频轨", plainLane(toneC))
print("==> 2. 渐入渐出 + 音量")
await compare("渐变", fadedLane(toneC))
print("==> 3. 音量曲线 + 渐入")
await compare("曲线", curvedLane(toneD))
print("==> 4. 主轨两段叠化（转场的交叉淡变 + 余料展开）")
await compare("叠化", crossfadedMain(toneA, toneB))
print("==> 5. 主轨接缝 5 毫秒的零头")
await compare("接缝零头", mainWithSliverGap(toneA, toneB))
print("==> 6. 静音的段、隐藏的轨、主轨推子")
await compare("静音与隐藏", mutedAndHidden(toneA, toneC, toneD))
print("==> 7. 上层视频轨叠在主轨上")
await compare("上层轨", overlayOverMain(toneA, toneB))
print("==> 8. 44.1 kHz 单声道素材（重采样、铺到两边）")
await compare("单声道 44.1k", monoLane(toneMono), tolerance: 0.3)
print("==> 9. 空时间线：配置没有轨")
check(AudioEngineConfig.make(from: baseState()).tracks.isEmpty, "空时间线的配置该没有轨")

print("\(checks) checks, \(failures) failures")
if failures == 0 { print("All checks passed") }
finish(failures == 0 ? 0 : 1)
