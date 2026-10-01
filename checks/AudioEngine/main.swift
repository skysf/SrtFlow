import AVFoundation
import Foundation
import SrtFlowCore

// **音频引擎的等价自检**：同一条时间线，纯 Swift 的 oracle 混音器（Oracle.swift：ffmpeg 解码 + 逐采样乘增益表）
// 和引擎离线渲染出来的声音逐 10 ms 窗口比 RMS，差不许超过容差；一边有声一边静音算错；引擎渲染期间不许欠载。
// 素材是现造的恒定振幅正弦（check-audio-fade 同一套），两边的差只能来自引擎的「水管」。
// 2026-10-01 PR1a–PR3a 期间参照是 AVFoundation 那份混音（AVAssetReaderAudioMixOutput）；PR3b 删掉那条路之前换成 oracle。
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

/// 2 秒「语音样」的噪声（粉红噪声再高通 100Hz、低通 4kHz），立体声 AAC：声音场景要量带宽、混响，正弦量不出
/// （和 check-audio-fade 的第 9 组同一种素材）。
func makeSpeechNoise(_ name: String) -> URL {
    let url = root.appendingPathComponent(name)
    let (code, out) = run(ffmpegPath, [
        "-y", "-hide_banner", "-loglevel", "error",
        "-f", "lavfi", "-i", "anoisesrc=color=pink:duration=2:sample_rate=48000:seed=7,highpass=f=100,lowpass=f=4000,volume=0.3",
        "-c:a", "aac", "-b:a", "256k", "-ac", "2", url.path,
    ])
    if code != 0 { print("造噪声素材失败：\(out)") }
    return url
}

/// 前 2 秒 440 Hz、后 2 秒 880 Hz 的正弦：变速那组靠「什么时候换音」验证拉伸真的按倍速走（恒定的音量和音高
/// 验不出 1 倍速和 2 倍速的区别）。
func makeSwitchTone(_ name: String) -> URL {
    let url = root.appendingPathComponent(name)
    let (code, out) = run(ffmpegPath, [
        "-y", "-hide_banner", "-loglevel", "error",
        "-f", "lavfi", "-i", "aevalsrc=0.5*sin(2*PI*t*if(lt(t\\,2)\\,440\\,880)):s=48000:d=4",
        "-c:a", "aac", "-b:a", "192k", "-ac", "2", "-t", "4", url.path,
    ])
    if code != 0 { print("造换音素材失败：\(out)") }
    return url
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

/// 引擎：同一份时间线算出配置，离线渲到总长。
func enginePCM(_ state: TimelineState) -> (pcm: Stereo, config: AudioEngineConfig, underruns: Int)? {
    let config = AudioEngineConfig.make(from: state)
    guard let engine = try? TimelineAudioEngine(config: config, mode: .offline) else { return nil }
    var pcm = Stereo()
    do {
        try engine.renderOffline(duration: state.duration) { interleaved, frames in
            pcm.append(interleaved: interleaved, frames: frames)
            return true
        }
    } catch {
        print("引擎渲染失败：\(error)")
        return nil
    }
    return (pcm, config, engine.underrunFrames)
}

/// 一组：oracle 和引擎都算出来，逐窗口比。
/// `margin`：段的边界两侧各跳过多少秒不比（默认 12 ms；变速段的拉伸算法会把头尾吃掉几十毫秒，给 0.1）。
func compare(_ label: String, _ state: TimelineState, tolerance: Double = 0.15, margin: Double = 0.012,
             totalTolerance: Double = 0.1, expectSilent: Bool = false, extraBoundaries: [Double] = []) async {
    guard let engine = enginePCM(state) else {
        check(false, "\(label)：引擎渲不出来")
        return
    }
    guard let reference = oraclePCM(engine.config) else {
        check(false, "\(label)：oracle 渲不出来")
        return
    }
    let expected = Int((state.duration * 48_000).rounded())
    check(abs(engine.pcm.frames - expected) <= 1, "\(label)：引擎该正好渲 \(expected) 帧，渲了 \(engine.pcm.frames)")
    check(engine.underruns == 0, "\(label)：离线渲染不许欠载，欠了 \(engine.underruns) 帧")
    let boundaries = engine.config.tracks.flatMap { $0.segments.flatMap { [$0.start, $0.end] } } + extraBoundaries
    let result = compareWindows(reference: reference, engine: engine.pcm, boundaries: boundaries, tolerance: tolerance, margin: margin)
    let total = rmsDB(engine.pcm.left)
    if expectSilent {
        check(total < -60, "\(label)：引擎该全静音，整段 RMS \(total) dB")
        check(rmsDB(reference.left) < -60, "\(label)：参照也该全静音")
    } else {
        // 素材是 −30 dBFS 左右的正弦，再乘推子会到 −40：门槛放在 −50，静音是 −60 以下。
        check(total > -50, "\(label)：引擎不该是静音（整段 RMS \(total) dB）—— 比对无从谈起")
        check(abs(rmsDB(reference.left) - total) < totalTolerance, "\(label)：整段 RMS 两边该一样（参照 \(rmsDB(reference.left))，引擎 \(total)）")
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

print("==> 10. 电平表：渲染块按拍把峰值交给无锁的槽，轨道表 = 这条轨听到的，总表 = 混音器出口 × 总推子，静音的段不进表、隐藏的轨没有槽")
do {
    // 主轨一段（推子 0.6）+ 一条静音的音频轨 + 一条隐藏的轨；总推子 0.8。
    var state = mutedAndHidden(toneA, toneC, toneD)
    state.masterVolume = 0.8
    let config = AudioEngineConfig.make(from: state)
    let meters = AudioMeterEngine()
    var pcm = Stereo()
    if let engine = try? TimelineAudioEngine(config: config, mode: .offline, meters: meters) {
        do {
            try engine.renderOffline(duration: state.duration) { interleaved, frames in
                pcm.append(interleaved: interleaved, frames: frames)
                return true
            }
        } catch { check(false, "电平表那组引擎渲染失败：\(error)") }
    } else { check(false, "电平表那组引擎建不起来") }
    // 槽记的是整段渲染里的峰值：渲出来的（已乘总推子）的峰值就是总表的峰值；主轨表是乘总推子之前的。
    let renderedPeak = Double(max(pcm.left.map { abs($0) }.max() ?? 0, pcm.right.map { abs($0) }.max() ?? 0))
    let masterPeak = meters.slotPeak(for: .master) ?? (0, 0)
    let mainPeak = meters.slotPeak(for: .track(.main)) ?? (0, 0)
    check(renderedPeak > 0.001, "该有声音（渲出来的峰值 \(renderedPeak)）")
    check(abs(Double(max(masterPeak.left, masterPeak.right)) - renderedPeak) < renderedPeak * 0.02,
          "总表的峰值该等于渲出来的峰值：表 \(masterPeak)，渲出 \(renderedPeak)")
    check(abs(Double(max(mainPeak.left, mainPeak.right)) * 0.8 - renderedPeak) < renderedPeak * 0.02,
          "主轨表 × 总推子 0.8 该等于渲出来的峰值：表 \(mainPeak)，渲出 \(renderedPeak)")
    let mutedKey = MeterKey.track(.lane(state.audioTracks[0].id))
    let hiddenKey = MeterKey.track(.lane(state.audioTracks[1].id))
    check((meters.slotPeak(for: mutedKey) ?? (0, 0)) == (0, 0), "静音的段不进它那条轨的表")
    check(meters.slotPeak(for: hiddenKey) == nil, "隐藏的轨没有表")
    check(meters.reading(for: .track(.main), at: 1, now: 1).left > -40, "界面读主轨那条表该有电平（取走槽里的峰值）")
    check((meters.slotPeak(for: .track(.main)) ?? (1, 1)) == (0, 0), "界面取走之后槽清零（下一拍从零起记）")
}

print("==> 11. 声音场景：效果链在渲染块里跑（段增益 → 效果 → 推子），强度 0 = 原声，余音越过段尾")
let noise = makeSpeechNoise("speech-noise.m4a")
for kind in [SoundSceneKind.bathroom, .telephone] {
    let state = sceneLane(noise, kind: kind)
    // oracle 不做场景：强度 0 就该和原声一样（效果链在线、干湿比却全是干的）；场景本身在下面验结构。
    var zero = state
    zero.audioTracks[0].clips[0].soundScene?.amount = 0
    await compare("场景 \(kind.rawValue) · 强度 0 = 原声", zero, tolerance: 0.3)
    // 余音：段 2.5 秒结束，之后一小段还有声（浴室的混响散不完；电话的滤波器余音很短，只验浴室）。
    if kind == .bathroom, let engine = enginePCM(state) {
        let after = rmsDB(engine.pcm.left[Int(2.52 * 48_000)..<Int(2.6 * 48_000)])
        check(after > -60, "浴室的混响该越过段尾（2.52–2.60 秒的 RMS \(after) dB）")
        let later = rmsDB(engine.pcm.left[Int(3.9 * 48_000)..<Int(4.0 * 48_000)])
        check(later < after, "余音该越散越小（3.9–4.0 秒 \(later) dB 不该比 2.52–2.60 秒 \(after) dB 响）")
    }
    // 场景真的改了声音：和不挂场景的那条时间线比，整段 RMS 或频谱得不一样。
    var plain = state
    plain.audioTracks[0].clips[0].soundScene = nil
    if let withScene = enginePCM(state), let without = enginePCM(plain) {
        let from = Int(1.0 * 48_000), to = Int(2.0 * 48_000)
        let band = withScene.pcm.left[from..<to].enumerated().reduce(0.0) { $0 + Double(abs($1.element - without.pcm.left[$1.offset + from])) }
        check(band > 0.001 * Double(to - from), "挂了 \(kind.rawValue) 的声音该和原声不一样（逐采样差的均值 \(band / Double(to - from))）")
    }
}

print("==> 12. 变速：保音调地拉伸，时长正好，换音的时刻按倍速落位，音高不变")
do {
    let switching = makeSwitchTone("switch-440-880.m4a")   // 前 2 秒 440 Hz，后 2 秒 880 Hz
    let state = speedLanes(switching)
    // oracle 只按线性插值重采样（音高会变），引擎是 AVAudioUnitTimePitch 保音调地拉伸：包络对得上，但换音的瞬间
    // （时间线 1.0 秒、3.0 秒）保音调算法要过渡几十毫秒、oracle 是瞬间换，那两处两侧各 0.1 秒不比（换音的时刻另有
    // 下面过零数的断言）；段的头尾同理。整段 RMS 差 0.1–0.2 dB 是算法的差，不是混音的。
    await compare("变速", state, tolerance: 1.5, margin: 0.1, totalTolerance: 0.3, extraBoundaries: [1.0, 3.0])
    if let engine = enginePCM(state) {
        /// 一段里过零多少次 → 频率。
        func frequency(_ from: Double, _ to: Double) -> Double {
            let samples = engine.pcm.left[Int(from * 48_000)..<Int(to * 48_000)]
            var crossings = 0
            var previous = samples.first ?? 0
            for sample in samples.dropFirst() {
                if (sample >= 0) != (previous >= 0) { crossings += 1 }
                previous = sample
            }
            return Double(crossings) / 2 / (to - from)
        }
        // 2 倍速：素材 1.0–3.0 秒落在时间线 0.5–1.5 秒，素材 2.0 秒的换音落在时间线 1.0 秒。不拉伸的话换音要到 1.5 秒才来。
        check(abs(frequency(0.55, 0.95) - 440) < 30, "2 倍速 0.55–0.95 秒该是 440 Hz（素材 1.1–1.9），量到 \(frequency(0.55, 0.95))")
        check(abs(frequency(1.05, 1.45) - 880) < 30, "2 倍速 1.05–1.45 秒该是 880 Hz（素材 2.1–2.9），量到 \(frequency(1.05, 1.45))")
        // 0.5 倍速：素材 1.5–2.5 秒落在时间线 2–4 秒，换音落在 3.0 秒。不拉伸的话 2.5 秒就换了。
        check(abs(frequency(2.1, 2.9) - 440) < 30, "0.5 倍速 2.1–2.9 秒该是 440 Hz（素材 1.55–1.95），量到 \(frequency(2.1, 2.9))")
        check(abs(frequency(3.1, 3.9) - 880) < 30, "0.5 倍速 3.1–3.9 秒该是 880 Hz（素材 2.05–2.45），量到 \(frequency(3.1, 3.9))")
        check(rmsDB(engine.pcm.left[Int(1.6 * 48_000)..<Int(1.9 * 48_000)]) < -60, "2 倍速那段 1.5 秒就该结束了（1.6–1.9 秒要静音）")
        check(rmsDB(engine.pcm.left[Int(3.8 * 48_000)..<Int(3.95 * 48_000)]) > -50, "0.5 倍速那段要一直响到 4 秒")
    }
}

print("\(checks) checks, \(failures) failures")
if failures == 0 { print("All checks passed") }
finish(failures == 0 ? 0 : 1)
