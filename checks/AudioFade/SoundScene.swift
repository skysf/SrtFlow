import AVFoundation
import Foundation

// MARK: - 9. 声音场景：真的改了声音、余音越过段尾、效果在段增益之后、响度补偿、成片 = 预览
//
// 声音场景跑在合成音轨的 tap 里（SceneTrackRenderer），预览和成片是同一份（成片离线读同一个合成）。
// 这一组量真实的 PCM：预览走真实 build() + 离线读，成片走真实 plan() + ffmpeg。
// 合同见 docs/architecture/sound-scenes.md。

/// 2 秒「语音样」的噪声（粉红噪声再高通 100Hz、低通 4kHz），立体声 AAC：频谱像人声，
/// 带通、混响、响度补偿都能量出东西（正弦只有一根谱线，量不出带宽）。
func makeSpeechNoise(_ name: String, broadband: Bool = false) -> URL {
    let url = root.appendingPathComponent(name)
    let shaping = broadband ? "" : ",highpass=f=100,lowpass=f=4000"
    let (code, out) = run(ffmpegPath, [
        "-y", "-hide_banner", "-loglevel", "error",
        "-f", "lavfi", "-i", "anoisesrc=color=pink:duration=2:sample_rate=48000:seed=7" + shaping,
        "-c:a", "aac", "-b:a", "256k", "-ac", "2", url.path,
    ])
    if code != 0 { print("造噪声素材失败：\(out)") }
    return url
}

/// 二阶高通（RBJ），量「某个频率以上还剩多少能量」用。
func highpassed(_ samples: [Float], cutoff: Double) -> [Float] {
    let w = 2 * Double.pi * cutoff / 48_000
    let alpha = sin(w) / (2 * 0.7071)
    let a0 = 1 + alpha
    let b0 = (1 + cos(w)) / 2 / a0, b1 = -(1 + cos(w)) / a0, b2 = (1 + cos(w)) / 2 / a0
    let a1 = -2 * cos(w) / a0, a2 = (1 - alpha) / a0
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
    return samples.map { sample in
        let x = Double(sample)
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return Float(y)
    }
}

/// 一条 5 秒的时间线：音频轨上 [0.5, 2.5] 一段噪声（挂 `scene`），主轨一段静音的视频撑到 5 秒
/// （给余音留地方）。这一段就是它那条合成音轨上的最后一段 —— 余音靠垫在后面的那截素材才出得来。
func sceneTimeline(_ noise: URL, video: URL, scene: SoundScene?, fadeOut: Double = 0) -> TimelineState {
    var clip = EditClip(
        sourceURL: noise, isAudioOnly: true, sourceDuration: 2, timelineStart: 0.5, audioAssetDuration: 2
    )
    clip.soundScene = scene
    clip.fadeOutDuration = fadeOut
    var picture = EditClip(sourceURL: video, sourceDuration: 4, timelineStart: 0, info: videoInfo)
    picture.isMuted = true
    var tail = EditClip(sourceURL: video, sourceDuration: 1, timelineStart: 4, info: videoInfo)
    tail.isMuted = true
    var state = TimelineState()
    state.frameRate = .fps30
    state.canvasRatio = .wide16x9
    state.mainClips = [picture, tail]
    state.audioTracks = [EditLane(clips: [clip])]
    return state
}

func checkSoundScenes(videoSource: URL) async {
    let noise = makeSpeechNoise("speech-noise.m4a")
    guard let dry = await previewSamples(sceneTimeline(noise, video: videoSource, scene: nil), name: "场景 · 原声") else { return }
    let body = decibels(rms(dry, from: 1.0, to: 2.0))
    check(body > -40, "原声要有声音（\(body) dB）")
    check(decibels(rms(dry, from: 2.7, to: 3.2)) < -80, "原声在段尾之后是静的（对照）")

    // 电话：6kHz 以上几乎全被削掉。素材得是**宽频**的（上面那份在 4kHz 就低通了，6kHz 以上本来就
    // 没什么可削的，量出来的全是通带漏过来的 —— 2026-09-24 第一版就是这么误红的），量的时候用四阶
    // 高通（两级二阶），通带里的能量漏不进来。
    let broadband = makeSpeechNoise("broadband-noise.m4a", broadband: true)
    if let wide = await previewSamples(sceneTimeline(broadband, video: videoSource, scene: nil), name: "场景 · 宽频原声"),
       let phone = await previewSamples(sceneTimeline(broadband, video: videoSource, scene: SoundScene(kind: .telephone)),
                                        name: "场景 · 电话") {
        let dryHigh = decibels(rms(highpassed(highpassed(wide, cutoff: 6000), cutoff: 6000), from: 1.0, to: 2.0))
        let phoneHigh = decibels(rms(highpassed(highpassed(phone, cutoff: 6000), cutoff: 6000), from: 1.0, to: 2.0))
        check(dryHigh - phoneHigh > 15,
              String(format: "电话要削掉高频：6kHz 以上原声 %.1f dB、电话 %.1f dB", dryHigh, phoneHigh))
    }

    // 大厅：余音越过段尾（这一段是它那条合成音轨上的最后一段），并且慢慢散掉。
    guard let hall = await previewSamples(sceneTimeline(noise, video: videoSource, scene: SoundScene(kind: .hall)),
                                          name: "场景 · 大厅") else { return }
    let early = decibels(rms(hall, from: 2.55, to: 2.95)) - body
    let late = decibels(rms(hall, from: 3.6, to: 4.0)) - body
    check(early > -40, String(format: "大厅的余音要越过段尾（段尾后 0.05–0.45 秒比原声低 %.1f dB）", -early))
    check(late < early - 6, String(format: "余音要慢慢散掉（%.1f → %.1f dB）", early, late))

    // 效果在段增益之后：段尾淡出到 0，人声没了、余音照常散（效果之前乘的增益才会这样）。
    if let faded = await previewSamples(
        sceneTimeline(noise, video: videoSource, scene: SoundScene(kind: .hall), fadeOut: 1), name: "场景 · 大厅 + 淡出") {
        let tail = decibels(rms(faded, from: 2.55, to: 2.95)) - body
        check(tail > -50, String(format: "淡出之后余音照常散（段尾后比原声低 %.1f dB）", -tail))
    }

    // 强度 0 = 原声。
    var none = SoundScene(kind: .hall)
    none.amount = 0
    if let zero = await previewSamples(sceneTimeline(noise, video: videoSource, scene: none), name: "场景 · 强度 0") {
        checkSameEnvelope(zero, dry, from: 0.6, to: 2.4, tolerance: 0.2, "强度 0 就是原声")
        check(decibels(rms(zero, from: 2.7, to: 3.2)) < -80, "强度 0 没有余音")
    }

    // 响度补偿：九个场景各在默认值上，段里的响度和原声差不过 3 dB（换来换去不忽大忽小）。
    for kind in SoundSceneKind.allCases {
        guard let wet = await previewSamples(sceneTimeline(noise, video: videoSource, scene: SoundScene(kind: kind)),
                                             name: "场景 · \(kind.rawValue)") else { continue }
        let level = decibels(rms(wet, from: 1.0, to: 2.0)) - body
        check(abs(level) < 3, String(format: "%@：响度补偿之后和原声差 %.1f dB（应在 ±3 dB 内）", kind.rawValue, level))
    }

    // 成片 = 预览：导出走离线读同一份合成，场景、余音都在里面。
    let hallState = sceneTimeline(noise, video: videoSource, scene: SoundScene(kind: .hall))
    if let exported = await exportSamples(hallState, name: "scene-hall.mp4", audioOnly: false) {
        checkSameEnvelope(exported, hall, from: 0.6, to: 3.8, tolerance: 0.6, "大厅 · 成片 vs 预览")
    }

    // 正在播的预览走的是电平表那份 tap（AudioMeterEngine 缓存的 TapContext），和成片的独立 tap 是
    // 同一个 SceneTrackRenderer：声音要一样，电平表要看得见余音（它量的是改完的声音）。
    if let built = await VideoEditCompositionBuilder.build(from: hallState) {
        let engine = AudioMeterEngine(ringCapacity: 1 << 18)
        let mix = VideoEditCompositionBuilder.makeAudioMix(state: hallState, plan: built.audioPlan, meters: engine)
        let live = await previewPCM(built.composition, mix: mix)
        checkSameEnvelope(live, hall, from: 0.6, to: 3.8, tolerance: 0.1, "大厅 · 带电平表的预览 tap vs 成片的 tap")
        check(engine.rawPeak(for: .master, from: 2.6, to: 3.0).left > 0.001,
              "电平表看得见段尾之后的余音（量的是 tap 处理完的声音）")
    }

    // 分割不改声音：余音越过段尾，切开的两半加起来就是没切的那一份（混响是线性的）。
    var split = hallState
    split.split(clipID: split.audioTracks[0].clips[0].id, at: 1.5)
    if let halves = await previewSamples(split, name: "场景 · 大厅 · 分割") {
        checkSameEnvelope(halves, hall, from: 0.6, to: 3.8, tolerance: 0.5, "分割前后听起来一样")
    }
}
