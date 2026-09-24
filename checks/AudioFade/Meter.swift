import AVFoundation
import Foundation

// MARK: - 8. 电平表：tap 看到的 × 同一张增益表 = 听到的；总表按位置把各轨加起来
//
// 离线的 AVAssetReaderAudioMixOutput 同样会调 tap（2026-09-23 探针），所以电平表够得着
// 真实管线：同一份合成 + 挂了 tap 的 audioMix 读一遍，看表里记下来的和读出来的对不对得上。
// 合同见 docs/architecture/audio-mixer.md。

/// - Parameter ringCapacity: 环开大一点：离线读比实时快得多，整条时间线都要留得住
///   （默认 2^18 帧 ≈ 5.5 秒，够 4 秒的用例；更长的用例要自己开大，不然前面的位置会被后面的覆盖）。
private func metered(
    _ state: TimelineState, ringCapacity: Int = 1 << 18
) async -> (built: VideoEditCompositionBuilder.Built, engine: AudioMeterEngine, samples: [Float])? {
    guard let built = await VideoEditCompositionBuilder.build(from: state) else {
        check(false, "电平表用例的预览合成没建起来"); return nil
    }
    let engine = AudioMeterEngine(ringCapacity: ringCapacity)
    let mix = VideoEditCompositionBuilder.makeAudioMix(state: state, plan: built.audioPlan, meters: engine)
    let samples = await previewPCM(built.composition, mix: mix)
    guard !samples.isEmpty else { check(false, "电平表用例读不出 PCM"); return nil }
    return (built, engine, samples)
}

private func ratio(_ value: Float, _ reference: Float) -> Double {
    reference > 0 ? Double(value / reference) : 0
}

func checkMeters(audioSource: URL, videoSource: URL) async {
    func audioClip() -> EditClip {
        EditClip(sourceURL: audioSource, isAudioOnly: true, sourceDuration: 4, timelineStart: 0,
                 audioAssetDuration: 4)
    }

    // ---- 参照：一条轨、什么增益都没有 —— tap 眼里素材本身有多响 ----
    var plain = TimelineState()
    plain.frameRate = .fps30
    plain.audioTracks = [EditLane(clips: [audioClip()])]
    guard let reference = await metered(plain) else { return }
    let plainKey = MeterKey.track(.lane(plain.audioTracks[0].id))
    let tapReference = reference.engine.rawPeak(for: plainKey, from: 1.0, to: 1.5).left
    let readerReference = Float(peak(reference.samples, from: 1.0, to: 1.5))
    check(tapReference > 0.05, "tap 真的看到了声音（峰值 \(tapReference)）")
    check(abs(ratio(reference.engine.rawPeak(for: .master, from: 1.0, to: 1.5).left, tapReference) - 1) < 0.02,
          "只有一条轨时总表就是这条轨")

    // ---- 两条轨 + 推子：A = 轨道 +6 dB；B = 段 +6 dB 且轨道 +6 dB；总推子 +6 dB ----
    // 同一个正弦、同相：A ×2、B ×4，总表 (2 + 4) × 2 = ×12 —— 远远过了 0 dBFS。
    var mixed = TimelineState()
    mixed.frameRate = .fps30
    var loud = audioClip()
    loud.volume = 2
    mixed.audioTracks = [EditLane(clips: [audioClip()], volume: 2), EditLane(clips: [loud], volume: 2)]
    mixed.masterVolume = 2
    if let result = await metered(mixed) {
        let a = MeterKey.track(.lane(mixed.audioTracks[0].id))
        let b = MeterKey.track(.lane(mixed.audioTracks[1].id))
        let aRatio = ratio(result.engine.rawPeak(for: a, from: 1.0, to: 1.5).left, tapReference)
        let bRatio = ratio(result.engine.rawPeak(for: b, from: 1.0, to: 1.5).left, tapReference)
        let masterRatio = ratio(result.engine.rawPeak(for: .master, from: 1.0, to: 1.5).left, tapReference)
        let readerRatio = ratio(Float(peak(result.samples, from: 1.0, to: 1.5)), readerReference)
        check(abs(aRatio - 2) < 0.1, "轨道表是推子之后的：A 应为 ×2（量到 \(aRatio)）")
        check(abs(bRatio - 4) < 0.2, "段音量和轨道推子都乘进去：B 应为 ×4（量到 \(bRatio)）")
        check(abs(masterRatio - 12) < 0.5, "总表 = 各轨按位置相加再乘总推子：×12（量到 \(masterRatio)）")
        check(abs(readerRatio - 12) < 0.5,
              "真实混音也是 ×12（表上看到的就是听到的；量到 \(readerRatio)）")
        let now = 1_000.0
        check(result.engine.reading(for: .master, at: 1.5, now: now).clipped, "总表过了 0 dBFS → 红灯")
        check(!result.engine.reading(for: a, at: 1.5, now: now).clipped, "A 自己没过 0 dBFS → 不亮")
        check(!result.engine.reading(for: b, at: 1.5, now: now).clipped, "B 自己没过 0 dBFS → 不亮")
        result.engine.clearClips()
        check(!result.engine.isClipped(.master), "开播时熄掉上一遍的红灯")
    }

    // ---- 音量曲线：tap 看不到 audioMix 的音量，曲线得靠同一张增益表乘进去 ----
    var curved = plain
    curved.audioTracks[0].clips[0].volumeCurve = KeyframeTrack(keys: [
        Keyframe(time: 0, value: -20), Keyframe(time: 4, value: -20),
    ])
    if let result = await metered(curved) {
        let curveRatio = ratio(result.engine.rawPeak(for: .track(.lane(curved.audioTracks[0].id)),
                                                     from: 1.0, to: 1.5).left, tapReference)
        check(abs(curveRatio - 0.1) < 0.01, "−20 dB 的曲线在表上也是 ×0.1（量到 \(curveRatio)）")
    }

    // ---- 主轨的 A/B 两条合成轨归到同一条表上 ----
    var main = TimelineState()
    main.frameRate = .fps30
    main.canvasRatio = .wide16x9
    main.mainClips = [
        EditClip(sourceURL: videoSource, sourceDuration: 2, timelineStart: 0, info: videoInfo),
        EditClip(sourceURL: videoSource, sourceStart: 2, sourceDuration: 2, timelineStart: 2, info: videoInfo),
    ]
    if let result = await metered(main) {
        let first = ratio(result.engine.rawPeak(for: .track(.main), from: 0.5, to: 1.0).left, tapReference)
        let second = ratio(result.engine.rawPeak(for: .track(.main), from: 2.5, to: 3.0).left, tapReference)
        check(abs(first - 1) < 0.1 && abs(second - 1) < 0.1,
              "主轨两段分在 A/B 两条合成轨上，表上都是主轨那一条（量到 \(first) / \(second)）")
    }
}

// MARK: - 8b. 一条轨上换了源音频格式：tap 不能死，读取不能卡
//
// 2026-09-23 事故（docs/bugfixes/2026-09-23-meter-tap-dies-on-audio-format-change.md）：同一条
// 合成音轨上前后两段的源格式不同（48kHz 立体声的音效后面接 44.1kHz 单声道的配音、mp3 后面接
// mp4 里的 AAC），挂在上面的 tap 被 AVFoundation 重新 prepare 之后再也不被调用 —— 那条轨从此
// 没声音，从换格式之后起播，播放器干脆不走。离线读同样中招（读到一半卡死），所以这里够得着。
// 上面第 8 组全用同一个素材，一条轨上从来没换过格式，所以一直是绿的。

/// 读取卡死时 `await` 永远不回来，自检就挂在那儿 —— 挂住不是失败。看门狗在**普通线程**上，
/// 到点还没解除就判红退出。
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

/// 修法本身的不变量：每条合成音轨上的段都是同一种源格式（不依赖 AVFoundation 此刻的脾气）。
/// 返回混了格式的合成音轨。
private func tracksMixingFormats(_ composition: AVMutableComposition) async -> [CMPersistentTrackID] {
    var mixed: [CMPersistentTrackID] = []
    for track in composition.tracks(withMediaType: .audio) {
        var formats: [CMFormatDescription] = []
        for segment in track.segments where !segment.isEmpty {
            guard let url = segment.sourceURL,
                  let source = try? await AVURLAsset(url: url).loadTrack(withTrackID: segment.sourceTrackID),
                  let format = try? await source.load(.formatDescriptions).first else { continue }
            formats.append(format)
        }
        if let first = formats.first,
           formats.contains(where: { !CompositionAudioTracks.sameStream($0, first) }) {
            mixed.append(track.trackID)
        }
    }
    return mixed
}

func checkMetersAcrossFormatChange(audioSource: URL, videoSource: URL) async {
    // 第二种格式：44.1kHz 单声道（和 audioSource / videoSource 的 48kHz 立体声不同）。
    let other = makeTone("tone-44k-mono.m4a", withVideo: false, sampleRate: 44_100, channels: 1)
    let otherVideo = makeTone("tone-44k-mono.mp4", withVideo: true, sampleRate: 44_100, channels: 1)

    // ---- 音频轨：0–4s 是 48kHz 立体声，6–10s 是 44.1kHz 单声道 ----
    var lane = TimelineState()
    lane.frameRate = .fps30
    lane.audioTracks = [EditLane(clips: [
        EditClip(sourceURL: audioSource, isAudioOnly: true, sourceDuration: 4, timelineStart: 0,
                 audioAssetDuration: 4),
        EditClip(sourceURL: other, isAudioOnly: true, sourceDuration: 4, timelineStart: 6,
                 audioAssetDuration: 4),
    ])]
    if let built = await VideoEditCompositionBuilder.build(from: lane) {
        let mixed = await tracksMixingFormats(built.composition)
        check(mixed.isEmpty, "一条合成音轨只装一种源格式（混了格式的合成轨：\(mixed)）")
    }
    let laneWatchdog = Watchdog(
        seconds: 60, "一条音频轨上换了源格式，挂着电平表离线读 60 秒没读完：tap 死了，读取卡住（播放器同样会卡）"
    )
    if let result = await metered(lane, ringCapacity: 1 << 20) {
        let key = MeterKey.track(.lane(lane.audioTracks[0].id))
        let before = result.engine.rawPeak(for: key, from: 1.0, to: 3.0).left
        let after = result.engine.rawPeak(for: key, from: 7.0, to: 9.0).left
        check(before > 0.05, "换格式之前表上有声音（峰值 \(before)）")
        check(after > before * 0.5, "换格式之后表上照样有声音（前 \(before)、后 \(after)）")
        let heard = peak(result.samples, from: 7.0, to: 9.0)
        check(heard > 0.05, "换格式之后真实混音里也有这一段（峰值 \(heard)）")
    }
    laneWatchdog.disarm()

    // ---- 主轨：A/B 两个槽上都有 48kHz 立体声，第三段换成 44.1kHz 单声道（又落回 A 槽）----
    var main = TimelineState()
    main.frameRate = .fps30
    main.canvasRatio = .wide16x9
    main.mainClips = [
        EditClip(sourceURL: videoSource, sourceDuration: 4, timelineStart: 0, info: videoInfo),
        EditClip(sourceURL: videoSource, sourceDuration: 4, timelineStart: 4, info: videoInfo),
        EditClip(sourceURL: otherVideo, sourceDuration: 4, timelineStart: 8, info: videoInfo),
    ]
    if let built = await VideoEditCompositionBuilder.build(from: main) {
        let mixed = await tracksMixingFormats(built.composition)
        check(mixed.isEmpty, "主轨的 A/B 槽也按源格式分开（混了格式的合成轨：\(mixed)）")
    }
    let mainWatchdog = Watchdog(
        seconds: 60, "主轨上换了源格式，挂着电平表离线读 60 秒没读完：tap 死了，读取卡住（播放器同样会卡）"
    )
    if let result = await metered(main, ringCapacity: 1 << 20) {
        let after = result.engine.rawPeak(for: .track(.main), from: 9.0, to: 11.0).left
        check(after > 0.05, "主轨换格式之后表上照样有声音（峰值 \(after)）")
        let heard = peak(result.samples, from: 9.0, to: 11.0)
        check(heard > 0.05, "主轨换格式之后真实混音里也有这一段（峰值 \(heard)）")
    }
    mainWatchdog.disarm()
}
