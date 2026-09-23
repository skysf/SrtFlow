import AVFoundation
import Foundation

// MARK: - 7. 音量曲线与推子：两条生产管线的真实包络
//
// 和前面几组同一个做法：素材是恒定振幅的正弦，量出来的起伏只能来自增益。
// 每个时刻都拿「素材本身在同一个窗口的 RMS」当 0 dB 参照，比值换成 dB 和期望比。
//
// 长期约束见 docs/architecture/audio-volume-curve.md 与 docs/architecture/audio-mixer.md。

/// 某个时刻（时间线秒）附近 40ms 的 RMS 相对素材本身的增益（dB）。
private func gainDB(_ samples: [Float], reference: [Float], at time: Double, sourceTime: Double) -> Double {
    let measured = rms(samples, from: time - 0.02, to: time + 0.02)
    let base = rms(reference, from: sourceTime - 0.02, to: sourceTime + 0.02)
    guard measured > 0, base > 0 else { return -120 }
    return 20 * log10(measured / base)
}

private func checkGains(
    _ samples: [Float], reference: [Float], label: String,
    probes: [(time: Double, sourceTime: Double, expectedDB: Double)], tolerance: Double = 0.5
) {
    check(!samples.contains { $0.isNaN },
          "\(label)：成品里不许有 NaN（表达式里任何一处算出 nan，整段声音都会变 nan）")
    for probe in probes {
        let got = gainDB(samples, reference: reference, at: probe.time, sourceTime: probe.sourceTime)
        check(abs(got - probe.expectedDB) < tolerance,
              String(format: "%@：%.2fs 处应为 %.1f dB，量到 %.2f dB", label, probe.time, probe.expectedDB, got))
    }
}

func checkVolumeCurvesAndFaders(audioSource: URL, videoSource: URL) async {
    let reference = decodePCM(audioSource)
    guard !reference.isEmpty else { check(false, "参照素材解不出 PCM"); return }

    // ---- 7a. 音频轨：曲线 × 轨道推子 × 总推子 ----
    // 曲线（源时间）：0.5s 0 dB → 1.5s −20 dB → 2.5s −20 dB → 3.5s 0 dB。
    // 轨道推子 −6 dB、总推子 +3 dB，合计 −3 dB 乘在整条曲线上。
    var clip = EditClip(sourceURL: audioSource, isAudioOnly: true, sourceDuration: 4,
                        timelineStart: 0, audioAssetDuration: 4)
    clip.volumeCurve = KeyframeTrack(keys: [
        Keyframe(time: 0.5, value: 0), Keyframe(time: 1.5, value: -20),
        Keyframe(time: 2.5, value: -20), Keyframe(time: 3.5, value: 0),
    ])
    var curved = TimelineState()
    curved.frameRate = .fps30
    curved.audioTracks = [EditLane(clips: [clip], volume: AudioGain.linear(fromDecibels: -6))]
    curved.masterVolume = AudioGain.linear(fromDecibels: 3)
    let mix = -3.0
    let curveProbes: [(Double, Double, Double)] = [
        (0.25, 0.25, 0 + mix), (1.0, 1.0, -10 + mix), (2.0, 2.0, -20 + mix),
        (3.0, 3.0, -10 + mix), (3.8, 3.8, 0 + mix),
    ]
    if let samples = await exportSamples(curved, name: "curve.m4a", audioOnly: true) {
        checkGains(samples, reference: reference, label: "音频轨曲线 · 导出", probes: curveProbes)
    }
    if let samples = await previewSamples(curved, name: "音频轨曲线 · 预览") {
        checkGains(samples, reference: reference, label: "音频轨曲线 · 预览", probes: curveProbes)
    }
    // 反例对照：同一条时间线去掉曲线，整段就是推子那 −3 dB（证明上面的起伏真是曲线给的）。
    var flat = curved
    flat.audioTracks[0].clips[0].volumeCurve = KeyframeTrack()
    let flatProbes: [(Double, Double, Double)] = [(1.0, 1.0, mix), (2.0, 2.0, mix), (3.0, 3.0, mix)]
    if let samples = await exportSamples(flat, name: "curve-flat.m4a", audioOnly: true) {
        checkGains(samples, reference: reference, label: "去掉曲线的对照 · 导出", probes: flatProbes)
    }
    if let samples = await previewSamples(flat, name: "去掉曲线的对照 · 预览") {
        checkGains(samples, reference: reference, label: "去掉曲线的对照 · 预览", probes: flatProbes)
    }

    // ---- 7b. 变速：点锚在源时间上 ----
    // 2 倍速：源 1.8s（0 dB）→ 2.2s（−30 dB）落在时间线 0.9s → 1.1s。
    var fast = EditClip(sourceURL: audioSource, isAudioOnly: true, sourceDuration: 4, speed: 2,
                        timelineStart: 0, audioAssetDuration: 4)
    fast.volumeCurve = KeyframeTrack(keys: [Keyframe(time: 1.8, value: 0), Keyframe(time: 2.2, value: -30)])
    var fastState = TimelineState()
    fastState.frameRate = .fps30
    fastState.audioTracks = [EditLane(clips: [fast])]
    // 变速之后源素材的 RMS 仍是同一个常数（恒定振幅正弦），参照取素材同一处即可。
    let fastProbes: [(Double, Double, Double)] = [(0.6, 1.2, 0), (1.5, 3.0, -30)]
    if let samples = await exportSamples(fastState, name: "curve-speed.m4a", audioOnly: true) {
        checkGains(samples, reference: reference, label: "2 倍速曲线 · 导出", probes: fastProbes)
    }
    if let samples = await previewSamples(fastState, name: "2 倍速曲线 · 预览") {
        checkGains(samples, reference: reference, label: "2 倍速曲线 · 预览", probes: fastProbes)
    }

    // ---- 7c. 主轨 + 转场 + 首帧定格：曲线的时间轴要减掉 renderHoldHead ----
    //
    // 两段都用满了 4 秒素材、首尾相接带 1 秒叠化 —— 没有余料可借，渲染副本在后一段
    // 头上补一截**首帧定格**（`adelay` 垫的静音）。曲线的 `aeval` 放在它前面
    //（它后面读不到可靠的时间），于是链上的第 0 秒是段的第 renderHoldHead 秒，
    // 时间轴不减的话整条曲线往后错一截（2026-09-23 反向验证：6.0s 处量到 −5 dB）。
    var first = EditClip(sourceURL: videoSource, sourceDuration: 4, timelineStart: 0, info: videoInfo)
    first.transitionAfter = .crossFade
    first.transitionDuration = 1
    var second = EditClip(sourceURL: videoSource, sourceDuration: 4, timelineStart: 4, info: videoInfo)
    second.volumeCurve = KeyframeTrack(keys: [Keyframe(time: 1, value: 0), Keyframe(time: 3, value: -20)])
    var seam = TimelineState()
    seam.frameRate = .fps30
    seam.canvasRatio = .wide16x9
    seam.mainClips = [first, second]
    let rendered = seam.expandingTransitionHandles()
    check(rendered.mainClips.count == 2 && rendered.mainClips[1].renderHoldHead > 0.01,
          "用例的前提：后一段头上真的补了首帧定格（否则测不到时间轴那一减）")
    // 后一段源 2.0s（−10 dB）落在时间线 6.0s；源 2.6s（−16 dB）落在 6.6s。
    let seamProbes: [(Double, Double, Double)] = [(2.0, 2.0, 0), (6.0, 2.0, -10), (6.6, 2.6, -16)]
    if let samples = await exportSamples(seam, name: "curve-seam.mp4", audioOnly: false) {
        checkGains(samples, reference: reference, label: "主轨接缝后的曲线 · 导出", probes: seamProbes)
    }
    if let samples = await previewSamples(seam, name: "主轨接缝后的曲线 · 预览") {
        checkGains(samples, reference: reference, label: "主轨接缝后的曲线 · 预览", probes: seamProbes)
    }

    // ---- 7d. 预览的钉点规则对曲线段照样成立（第 4b 组的不变量）----
    var late = clip
    late.timelineStart = 2.7183
    var lateState = TimelineState()
    lateState.frameRate = .fps30
    lateState.audioTracks = [EditLane(clips: [late])]
    if let built = await VideoEditCompositionBuilder.build(from: lateState),
       let params = built.audioMix?.inputParameters.first {
        var start: Float = -1, end: Float = -1
        var range = CMTimeRange.zero
        _ = params.getVolumeRamp(for: .zero, startVolume: &start, endVolume: &end, timeRange: &range)
        check(range.start.seconds <= 0.0005,
              "曲线段也得从时间 0 起就有确定的音量（第一个设定点在 \(range.start.seconds)s）")
    } else {
        check(false, "钉点用例的预览合成没建起来")
    }

    // ---- 7e. 快路径：只改曲线 / 推子时换 mix 与整条重建等价 ----
    guard let built = await VideoEditCompositionBuilder.build(from: flat) else {
        check(false, "快路径用例的预览合成没建起来"); return
    }
    check(curved.differsOnlyInAudioMix(from: flat), "加曲线 + 动推子只该换 audioMix")
    let fastMix = VideoEditCompositionBuilder.makeAudioMix(state: curved, plan: built.audioPlan)
    let fastPath = await previewPCM(built.composition, mix: fastMix)
    if let rebuilt = await VideoEditCompositionBuilder.build(from: curved) {
        let slowPath = await previewPCM(rebuilt)
        for probe in [0.25, 1.0, 2.0, 3.0, 3.8] {
            let a = gainDB(fastPath, reference: reference, at: probe, sourceTime: probe)
            let b = gainDB(slowPath, reference: reference, at: probe, sourceTime: probe)
            check(abs(a - b) < 0.2, String(format: "快路径与重建在 %.2fs 处一致（%.2f vs %.2f dB）", probe, a, b))
        }
    } else {
        check(false, "快路径对照的整条重建没建起来")
    }
}
