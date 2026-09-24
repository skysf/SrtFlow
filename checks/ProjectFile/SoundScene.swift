import Foundation

// 第 29 组：声音场景的模型（2026-09-24）。声音本身（预览与成片的真实处理）在
// scripts/check-audio-fade.sh 第 9 组；这里只管纯值的规矩和存盘。合同见
// docs/architecture/sound-scenes.md。

func checkSoundScenes(root: URL) throws {
    let dir = root.appendingPathComponent("soundscenes")
    let media = dir.appendingPathComponent("voice.m4a")
    makeFile(media)

    // ---- 模型：默认值、换种类留强度、夹紧 ----
    let hall = SoundScene(kind: .hall)
    checkEqual(hall.amount, SoundSceneKind.hall.defaults.amount, "新选的场景用它自己的默认强度")
    check(hall.isDefault, "刚选上的场景就是默认值（「重置」置灰）")
    var tuned = hall
    tuned.amount = 0.4
    tuned.first = 0.9
    let switched = tuned.switching(to: .telephone)
    checkEqual(switched.kind, .telephone, "换成电话")
    checkEqual(switched.amount, 0.4, "换场景时强度留着（用户调的是「要多少」）")
    checkEqual(switched.first, SoundSceneKind.telephone.defaults.first,
               "两个旋钮回到新场景的默认值（大厅的空间大小搬到电话上没有意义）")
    checkEqual(tuned.switching(to: .hall), tuned, "换成同一种什么都不动")
    let hostile = SoundScene(kind: .room, amount: .nan, first: 3, second: -1).sanitized
    checkEqual(hostile.amount, SoundSceneKind.room.defaults.amount, "NaN 回默认值")
    checkEqual(hostile.first, 1, "越界夹回 1")
    checkEqual(hostile.second, 0, "越界夹回 0")
    checkEqual(SoundSceneGroup.speaker.kinds, [.telephone, .megaphone, .radio], "喇叭一组三个")
    checkEqual(SoundSceneKind.allCases.count, 9, "九个场景（海边不做）")
    checkEqual(SoundSceneKind.room.controls.first, .size, "空间类的第一个旋钮是空间大小")
    checkEqual(SoundSceneKind.radio.controls.second, .quality, "喇叭类的第二个旋钮是音质")

    // ---- 编辑：只动有声音的段；强度留着；值夹紧；重置；去掉 ----
    let voice = EditClip(sourceURL: media, isAudioOnly: true, sourceDuration: 4, audioAssetDuration: 4)
    let silentInfo = MediaInfo(
        duration: 4, displaySize: CGSize(width: 320, height: 180), frameRate: 30,
        videoCodec: "h264", audioCodec: nil, hasAudio: false, audioCanCopyToMP4: false, fileBytes: 1
    )
    let silent = EditClip(sourceURL: media, sourceDuration: 4, info: silentInfo)
    var state = TimelineState()
    state.mainClips = [silent]
    state.audioTracks = [EditLane(clips: [voice])]
    check(!state.hasSoundScenes && !state.requiresFormatVersion20, "没挂场景的工程不是 v20 数据")

    state.setSoundSceneKind(.bathroom, for: [voice.id, silent.id])
    checkEqual(state.clip(with: voice.id)?.soundScene?.kind, .bathroom, "有声音的段挂上了")
    check(state.clip(with: silent.id)?.soundScene == nil, "没有声音的段不挂场景（检查器里它也没有这一块）")
    state.setSoundSceneValue(\.amount, to: 7, for: [voice.id])
    checkEqual(state.clip(with: voice.id)?.soundScene?.amount, 1, "写入也夹紧")
    state.setSoundSceneValue(\.first, to: 0.2, for: [voice.id])
    state.setSoundSceneKind(.hall, for: [voice.id])
    checkEqual(state.clip(with: voice.id)?.soundScene?.amount, 1, "换种类不动强度")
    checkEqual(state.clip(with: voice.id)?.soundScene?.first, SoundSceneKind.hall.defaults.first,
               "换种类旋钮回默认")
    state.setSoundSceneValue(\.second, to: 0.9, for: [voice.id])
    state.resetSoundScene(for: [voice.id])
    check(state.clip(with: voice.id)?.soundScene?.isDefault == true, "重置回到默认值")
    check(state.hasSoundScenes && state.requiresFormatVersion20, "挂了场景就是 v20 数据")

    // ---- 快路径判据：种类和旋钮只进 audioMix；有没有场景是合成结构 ----
    var tweaked = state
    tweaked.setSoundSceneValue(\.first, to: 0.1, for: [voice.id])
    check(tweaked.differsOnlyInAudioMix(from: state), "拖旋钮只换 audioMix（画面不闪）")
    var rekinded = state
    rekinded.setSoundSceneKind(.valley, for: [voice.id])
    check(rekinded.differsOnlyInAudioMix(from: state), "换种类只换 audioMix")
    var removed = state
    removed.setSoundSceneKind(nil, for: [voice.id])
    check(!removed.differsOnlyInAudioMix(from: state),
          "去掉场景要重建：挂了场景的合成音轨最后一段后面垫着让余音散完的素材")

    // ---- 分割两半都带着；分离音频带着走 ----
    var split = state
    split.split(clipID: voice.id, at: 2)
    let halves = split.audioTracks[0].clips
    checkEqual(halves.count, 2, "分成两段")
    check(halves.allSatisfy { $0.soundScene == state.clip(with: voice.id)?.soundScene },
          "分割后两半是同一个场景（余音越过段尾，切开前后听起来不变）")
    var video = EditClip(sourceURL: media, sourceDuration: 4, info: MediaInfo(
        duration: 4, displaySize: CGSize(width: 320, height: 180), frameRate: 30,
        videoCodec: "h264", audioCodec: "aac", hasAudio: true, audioCanCopyToMP4: true, fileBytes: 1
    ))
    video.soundScene = SoundScene(kind: .megaphone)
    checkEqual(video.detachedAudio(linkGroup: UUID()).soundScene, video.soundScene,
               "分离音频时场景跟着声音走（视频那段被静音，留在它身上就再也听不见了）")

    // ---- 存盘：按需写键、v20、往返保真 ----
    let file = dir.appendingPathComponent("scenes.srtflowproj")
    try VideoEditProjectIO.save(state, to: file)
    let text = try String(contentsOf: file, encoding: .utf8)
    checkEqual(text.components(separatedBy: "\"soundScene\"").count - 1, 1, "只有挂了场景的那一段写这个键")
    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
    checkEqual(raw?["formatVersion"] as? Int, 20, "带场景的工程写 latest（v20）")
    let loaded = try VideoEditProjectIO.load(from: file).timeline
    checkEqual(loaded.clip(with: voice.id)?.soundScene, state.clip(with: voice.id)?.soundScene, "场景往返保真")

    // ---- 读盘宽容：老工程缺键 = 没有；认不出的场景整个不认，别的照常 ----
    let unknown = dir.appendingPathComponent("unknown-scene.srtflowproj")
    try Data("""
    {
      "formatVersion": 20,
      "timeline": {
        "mainClips": [],
        "audioTracks": [{ "clips": [
          { "sourceURL": "\(media.absoluteString)", "isAudioOnly": true, "sourceDuration": 4, "volume": 0.5,
            "soundScene": { "kind": "underwater", "amount": 1, "first": 0.5, "second": 0.5 } },
          { "sourceURL": "\(media.absoluteString)", "isAudioOnly": true, "sourceDuration": 4, "timelineStart": 5,
            "soundScene": { "kind": "forest", "amount": 9, "first": -2 } }
        ] }]
      },
      "media": []
    }
    """.utf8).write(to: unknown)
    let tolerant = try VideoEditProjectIO.load(from: unknown).timeline
    let clips = tolerant.audioTracks.first?.clips ?? []
    checkEqual(clips.count, 2, "认不出的场景不拖累整段 / 整个工程")
    check(clips.first?.soundScene == nil, "认不出的场景当作没有")
    checkEqual(clips.first?.volume, 0.5, "那一段别的设置照常读回来")
    checkEqual(clips.last?.soundScene?.amount, 1, "越界的强度夹回来")
    checkEqual(clips.last?.soundScene?.first, 0, "越界的旋钮夹回来")
    checkEqual(clips.last?.soundScene?.second, SoundSceneKind.forest.defaults.second, "缺的旋钮用默认值")
}
