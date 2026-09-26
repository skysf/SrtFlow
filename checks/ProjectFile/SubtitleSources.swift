import Foundation
import SrtFlowCore

// 第 35 组：字幕生成「只用选中的片段」（2026-09-26）。
//
// 选中的片段里听得见的那几段才算；链接开着时连带链接组（选中视频 = 连它分离出来的音频一起）；
// 转写和分段都只认这几段（`SubtitleAudibleClips.soundClips(in:only:)`）。
// 规则见 docs/architecture/subtitle-generation-style.md「只用选中的片段」。

func checkSubtitleSources(root: URL) throws {
    checkProbeOrderPrefersLongClips(root: root)
    let media = root.appendingPathComponent("selected-voice.mp4")
    makeFile(media)
    func clip(at start: Double, audioOnly: Bool = false) -> EditClip {
        var clip = EditClip(sourceURL: media, sourceDuration: 3, timelineStart: start)
        clip.info = MediaInfo(
            duration: 3, displaySize: CGSize(width: 1920, height: 1080), frameRate: 30,
            videoCodec: "h264", audioCodec: "aac", hasAudio: true,
            audioCanCopyToMP4: true, fileBytes: 2048
        )
        clip.isAudioOnly = audioOnly
        return clip
    }
    // 一段分离过声音的视频（自己静音了，声音在音频轨上、两段同一个链接组）、一段录屏、一段背景音乐。
    let group = UUID()
    var video = clip(at: 0)
    video.isMuted = true
    video.linkGroup = group
    var detached = clip(at: 0, audioOnly: true)
    detached.linkGroup = group
    let recording = clip(at: 10)
    let music = clip(at: 0, audioOnly: true)
    var state = TimelineState()
    state.mainClips = [video, recording]
    state.audioTracks = [EditLane(clips: [detached]), EditLane(clips: [music])]

    checkEqual(SubtitleAudibleClips.selectedSoundClipIDs(in: state, selected: [detached.id], includingLinked: false),
               [detached.id], "只用选中的：选中旁白那一段，就只有它")
    checkEqual(SubtitleAudibleClips.selectedSoundClipIDs(in: state, selected: [video.id], includingLinked: true),
               [detached.id], "只用选中的：链接开着时选中视频，连带它分离出来的音频（视频自己静音了、不算）")
    check(SubtitleAudibleClips.selectedSoundClipIDs(in: state, selected: [video.id], includingLinked: false).isEmpty,
          "只用选中的：链接关着时选中静音的视频，一段听得见的都没有（选项不出现）")

    checkEqual(Set(SubtitleAudibleClips.soundClips(in: state, only: [detached.id, recording.id]).map(\.clipID)),
               [detached.id, recording.id], "只用选中的：可听快照只留那几段")
    checkEqual(Set(SubtitleAudibleClips.soundClips(in: state, only: nil).map(\.clipID)),
               [detached.id, recording.id, music.id], "不勾：全部听得见的（静音的视频不算）")

    // 选中了藏起来的段也不算 —— 藏起来就听不见（隐藏合同只有一份）。
    var hidden = state
    hidden.setHidden(true, ids: [recording.id])
    check(SubtitleAudibleClips.selectedSoundClipIDs(in: hidden, selected: [recording.id], includingLinked: false).isEmpty,
          "只用选中的：选中的段藏起来了，不算")
}

// 自动检测挑探针：长的先（2026-09-26 案例 docs/bugfixes/2026-09-26-auto-detect-probes-sound-effects.md）。
//
// 探针原来按可听快照的顺序取第一段读得出来的 —— 主轨排在最前，南极工程的第一段是 6 秒的
// 船撞冰音效，没有一个词，每个候选语言都是 0 分，检测「失败」。旁白、对白往往是长段，
// 音效是短的，所以长的先；一样长的保持可听快照原序。
private func checkProbeOrderPrefersLongClips(root: URL) {
    let dir = root.appendingPathComponent("probe-order")
    func sound(_ name: String, seconds: Double) -> SubtitleAudibleClips.SoundClip {
        let url = dir.appendingPathComponent(name)
        makeFile(url)
        return SubtitleAudibleClips.SoundClip(
            clipID: UUID(), name: name, url: url, fingerprint: name, knownAssetDuration: seconds,
            sourceStart: 0, sourceDuration: seconds, timelineStart: 0, speed: 1, laneRank: 0
        )
    }
    let shipCrash = sound("ship-crash.mp4", seconds: 6)
    let voiceIntro = sound("voice-intro.mp3", seconds: 24.3)
    let musicBed = sound("music-bed.mp3", seconds: 11)
    let otherCrash = sound("ice-crack.mp4", seconds: 6)
    checkEqual(SubtitleAudibleClips.probeOrder(in: [shipCrash, voiceIntro, musicBed, otherCrash]).map(\.name),
               ["voice-intro.mp3", "music-bed.mp3", "ship-crash.mp4", "ice-crack.mp4"],
               "探针候选：长的先（旁白往往长、音效短），一样长的保持原序")
}
