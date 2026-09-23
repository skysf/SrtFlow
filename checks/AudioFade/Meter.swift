import AVFoundation
import Foundation

// MARK: - 8. 电平表：tap 看到的 × 同一张增益表 = 听到的；总表按位置把各轨加起来
//
// 离线的 AVAssetReaderAudioMixOutput 同样会调 tap（2026-09-23 探针），所以电平表够得着
// 真实管线：同一份合成 + 挂了 tap 的 audioMix 读一遍，看表里记下来的和读出来的对不对得上。
// 合同见 docs/architecture/audio-mixer.md。

private func metered(_ state: TimelineState) async -> (engine: AudioMeterEngine, samples: [Float])? {
    guard let built = await VideoEditCompositionBuilder.build(from: state) else {
        check(false, "电平表用例的预览合成没建起来"); return nil
    }
    // 环开大一点：离线读比实时快得多，4 秒的素材要整条都留得住。
    let engine = AudioMeterEngine(ringCapacity: 1 << 18)
    let mix = VideoEditCompositionBuilder.makeAudioMix(state: state, plan: built.audioPlan, meters: engine)
    let samples = await previewPCM(built.composition, mix: mix)
    guard !samples.isEmpty else { check(false, "电平表用例读不出 PCM"); return nil }
    return (engine, samples)
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
