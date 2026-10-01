import AVFoundation
import Foundation

// MARK: - 8. 电平表：槽里记的 = 这条轨听到的（推子之后）；总表 = 混音器出口（含总推子）
//
// 2026-10-01 PR3b 起只有音频引擎这一条路：每条轨的渲染块按拍把峰值交给无锁的槽（MeterSlot），总表从混音器出口取。
// 离线渲染走的是同一批槽（Envelope.swift 的 `enginePCMMetered`：每拍先看槽、再让界面那条路取走并算红灯）。
// 合同见 docs/architecture/audio-engine.md「电平表」。
// （2026-10-01 以前这里离线读挂着 tap 的合成：tap 看不到 audioMix 的音量，得自己乘同一张增益表。）

private func metered(_ state: TimelineState, keys: [MeterKey]) -> (engine: AudioMeterEngine, render: MeteredRender)? {
    let engine = AudioMeterEngine()
    guard let render = enginePCMMetered(state, keys: keys + [.master], meters: engine) else {
        check(false, "电平表用例的引擎渲不出来"); return nil
    }
    guard !render.samples.isEmpty else { check(false, "电平表用例渲不出 PCM"); return nil }
    return (engine, render)
}

private func ratio(_ value: Float, _ reference: Float) -> Double {
    reference > 0 ? Double(value / reference) : 0
}

func checkMeters(audioSource: URL, videoSource: URL) async {
    func audioClip() -> EditClip {
        EditClip(sourceURL: audioSource, isAudioOnly: true, sourceDuration: 4, timelineStart: 0,
                 audioAssetDuration: 4)
    }

    // ---- 参照：一条轨、什么增益都没有 —— 槽里素材本身有多响 ----
    var plain = TimelineState()
    plain.frameRate = .fps30
    plain.audioTracks = [EditLane(clips: [audioClip()])]
    let plainKey = MeterKey.track(.lane(plain.audioTracks[0].id))
    guard let reference = metered(plain, keys: [plainKey]) else { return }
    let slotReference = reference.render.rawPeak(for: plainKey, from: 1.0, to: 1.5)
    let readerReference = Float(peak(reference.render.samples, from: 1.0, to: 1.5))
    check(slotReference > 0.05, "槽里真的看到了声音（峰值 \(slotReference)）")
    check(abs(ratio(reference.render.rawPeak(for: .master, from: 1.0, to: 1.5), slotReference) - 1) < 0.02,
          "只有一条轨时总表就是这条轨")

    // ---- 两条轨 + 推子：A = 轨道 +6 dB；B = 段 +6 dB 且轨道 +6 dB；总推子 +6 dB ----
    // 同一个正弦、同相：A ×2、B ×4，总表 (2 + 4) × 2 = ×12 —— 远远过了 0 dBFS。
    var mixed = TimelineState()
    mixed.frameRate = .fps30
    var loud = audioClip()
    loud.volume = 2
    mixed.audioTracks = [EditLane(clips: [audioClip()], volume: 2), EditLane(clips: [loud], volume: 2)]
    mixed.masterVolume = 2
    let a = MeterKey.track(.lane(mixed.audioTracks[0].id))
    let b = MeterKey.track(.lane(mixed.audioTracks[1].id))
    if let result = metered(mixed, keys: [a, b]) {
        let aRatio = ratio(result.render.rawPeak(for: a, from: 1.0, to: 1.5), slotReference)
        let bRatio = ratio(result.render.rawPeak(for: b, from: 1.0, to: 1.5), slotReference)
        let masterRatio = ratio(result.render.rawPeak(for: .master, from: 1.0, to: 1.5), slotReference)
        let readerRatio = ratio(Float(peak(result.render.samples, from: 1.0, to: 1.5)), readerReference)
        check(abs(aRatio - 2) < 0.1, "轨道表是推子之后的：A 应为 ×2（量到 \(aRatio)）")
        check(abs(bRatio - 4) < 0.2, "段音量和轨道推子都乘进去：B 应为 ×4（量到 \(bRatio)）")
        check(abs(masterRatio - 12) < 0.5, "总表 = 各轨相加再乘总推子：×12（量到 \(masterRatio)）")
        check(abs(readerRatio - 12) < 0.5,
              "真实混音也是 ×12（表上看到的就是听到的；量到 \(readerRatio)）")
        let now = 1_000.0
        check(result.engine.reading(for: .master, at: 1.5, now: now).clipped, "总表过了 0 dBFS → 红灯")
        check(!result.engine.reading(for: a, at: 1.5, now: now).clipped, "A 自己没过 0 dBFS → 不亮")
        check(!result.engine.reading(for: b, at: 1.5, now: now).clipped, "B 自己没过 0 dBFS → 不亮")
        result.engine.clearClips()
        check(!result.engine.isClipped(.master), "开播时熄掉上一遍的红灯")
    }

    // ---- 音量曲线：曲线乘在渲染块里，表上看到的就是乘过的 ----
    var curved = plain
    curved.audioTracks[0].clips[0].volumeCurve = KeyframeTrack(keys: [
        Keyframe(time: 0, value: -20), Keyframe(time: 4, value: -20),
    ])
    if let result = metered(curved, keys: [plainKey]) {
        let curveRatio = ratio(result.render.rawPeak(for: plainKey, from: 1.0, to: 1.5), slotReference)
        check(abs(curveRatio - 0.1) < 0.01, "−20 dB 的曲线在表上也是 ×0.1（量到 \(curveRatio)）")
    }

    // ---- 主轨的两段都归到主轨那一条表上 ----
    var main = TimelineState()
    main.frameRate = .fps30
    main.canvasRatio = .wide16x9
    main.mainClips = [
        EditClip(sourceURL: videoSource, sourceDuration: 2, timelineStart: 0, info: videoInfo),
        EditClip(sourceURL: videoSource, sourceStart: 2, sourceDuration: 2, timelineStart: 2, info: videoInfo),
    ]
    if let result = metered(main, keys: [.track(.main)]) {
        let first = ratio(result.render.rawPeak(for: .track(.main), from: 0.5, to: 1.0), slotReference)
        let second = ratio(result.render.rawPeak(for: .track(.main), from: 2.5, to: 3.0), slotReference)
        check(abs(first - 1) < 0.1 && abs(second - 1) < 0.1,
              "主轨两段都在主轨那一条表上（量到 \(first) / \(second)）")
    }
}

// MARK: - 8b. 一条轨上换了源音频格式：两段都出声、表上都看得见，渲染不许卡
//
// 2026-09-23 的事故是 AVFoundation 的 tap（docs/bugfixes/2026-09-23-meter-tap-dies-on-audio-format-change.md）：
// 同一条合成音轨上前后两段源格式不同，tap 被重新 prepare 之后再也不被调用。引擎一段一条流、各自转成 48 kHz，
// 换格式只是换一条流 —— 这里钉住它不会再有那种事：48kHz 立体声后面接 44.1kHz 单声道，两段都在，渲染不卡。

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
    let laneWatchdog = Watchdog(seconds: 60, "一条音频轨上换了源格式，引擎 60 秒没渲完：卡住了")
    let key = MeterKey.track(.lane(lane.audioTracks[0].id))
    if let result = metered(lane, keys: [key]) {
        let before = result.render.rawPeak(for: key, from: 1.0, to: 3.0)
        let after = result.render.rawPeak(for: key, from: 7.0, to: 9.0)
        check(before > 0.05, "换格式之前表上有声音（峰值 \(before)）")
        check(after > before * 0.5, "换格式之后表上照样有声音（前 \(before)、后 \(after)）")
        let heard = peak(result.render.samples, from: 7.0, to: 9.0)
        check(heard > 0.05, "换格式之后真实混音里也有这一段（峰值 \(heard)）")
    }
    laneWatchdog.disarm()

    // ---- 主轨：两段 48kHz 立体声，第三段换成 44.1kHz 单声道 ----
    var main = TimelineState()
    main.frameRate = .fps30
    main.canvasRatio = .wide16x9
    main.mainClips = [
        EditClip(sourceURL: videoSource, sourceDuration: 4, timelineStart: 0, info: videoInfo),
        EditClip(sourceURL: videoSource, sourceDuration: 4, timelineStart: 4, info: videoInfo),
        EditClip(sourceURL: otherVideo, sourceDuration: 4, timelineStart: 8, info: videoInfo),
    ]
    let mainWatchdog = Watchdog(seconds: 60, "主轨上换了源格式，引擎 60 秒没渲完：卡住了")
    if let result = metered(main, keys: [.track(.main)]) {
        let after = result.render.rawPeak(for: .track(.main), from: 9.0, to: 11.0)
        check(after > 0.05, "主轨换格式之后表上照样有声音（峰值 \(after)）")
        let heard = peak(result.render.samples, from: 9.0, to: 11.0)
        check(heard > 0.05, "主轨换格式之后真实混音里也有这一段（峰值 \(heard)）")
    }
    mainWatchdog.disarm()
}
