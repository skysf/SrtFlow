import Foundation

// 剪辑粘贴时落到哪条轨（`ClipPasteLanding` + `insertPasted`）。编译方式见 scripts/check-timeline-clipboard.sh。
// 用户拍板第 1 题选 A：「和从 Finder 拖文件一样」—— 撞上了画面往上抬一轨、声音换一条放得下的，
// 都满了新开一条；不盖掉、不挤走。多出来的规矩：几组一起粘时保住上下关系、每组整组落在同一条轨上。

func checkClipLanding() {
    checkSingleClip()
    checkGroups()
    checkAudioAndLinks()
}

/// 这一段现在在哪条轨上（找不到是 nil）。
private func track(of id: UUID, in state: TimelineState) -> TrackSlot? {
    state.location(of: id)?.track
}

private func copy(_ ids: Set<UUID>, from state: TimelineState) -> TimelineClipboardPayload? {
    TimelineClipboardPayload(copying: state, clips: ids, shapes: [], texts: [], cues: [], filters: [])
}

private func checkSingleClip() {
    var state = TimelineState()
    let a = clip(0, 5)
    state.mainClips = [a, clip(5, 5)]
    let copied = copy([a.id], from: state)

    // 主轨 20 秒处空着：用播放头粘（没指着）→ 回原来那条轨，落在 20 秒。
    var pasted = paste(copied, into: &state, at: 20)
    let first = pasted.clips.first
    checkEqual(first.flatMap { track(of: $0, in: state) }, .main, "原来那条轨（主轨）20 秒处空着：就落在主轨")
    checkEqual(first.flatMap { state.clip(with: $0)?.timelineStart }, 20, "左边缘对齐落点")
    check(first != a.id, "粘出来的是新的一段（新身份）")
    checkEqual(state.mainClips.map(\.timelineStart), [0, 5, 20], "主轨仍按时间排（数组顺序 = 时间顺序）")

    // 主轨 2 秒处占着：往上抬一轨（没有上层轨 → 新开一条在最上面）。
    pasted = paste(copied, into: &state, at: 2)
    checkEqual(pasted.clips.first.flatMap { track(of: $0, in: state) }, .overlay(0), "主轨占着：往上抬，新开一条上层轨")
    checkEqual(state.mainClips.count, 3, "不盖掉、不挤走主轨上的任何一段")

    // 再粘到同一处：上层轨 0 也占着了 → 再往上新开一条。
    pasted = paste(copied, into: &state, at: 2)
    checkEqual(pasted.clips.first.flatMap { track(of: $0, in: state) }, .overlay(1), "上层轨也占着：接着往上")

    // 指着上层轨 1、那儿 30 秒处空着：落在指着的那条。
    pasted = paste(copied, into: &state, at: 30, pointing: .track(.overlay(1)))
    checkEqual(pasted.clips.first.flatMap { track(of: $0, in: state) }, .overlay(1), "指着的轨放得下：就落那儿")

    // 视频指着音频轨：纵向不认（放不了这种东西），回原来那条轨（主轨，40 秒处空着）。
    state.audioTracks = [EditLane(clips: [clip(0, 60, audio: true)])]
    pasted = paste(copied, into: &state, at: 40, pointing: .track(.audio(0)))
    checkEqual(pasted.clips.first.flatMap { track(of: $0, in: state) }, .main, "视频指着音频轨：回原来那条轨")

    // 藏起来的轨不上梯子：主轨藏着 → 从上层轨起找。
    var hidden = TimelineState()
    hidden.mainClips = [a]
    hidden.mainHidden = true
    pasted = paste(copied, into: &hidden, at: 50)
    checkEqual(pasted.clips.first.flatMap { track(of: $0, in: hidden) }, .overlay(0),
               "主轨藏着：不往看不见的轨上粘（同拖文件的梯子）")
}

private func checkGroups() {
    // 主轨一段 + 上层轨一段叠在一起拿走：粘到空处，各回各的轨，上下关系不变，相对时间不变。
    var state = TimelineState()
    let low = clip(0, 4)
    let high = clip(1, 2)
    state.mainClips = [low]
    state.overlayTracks = [EditLane(clips: [high])]
    let copied = copy([low.id, high.id], from: state)
    var pasted = paste(copied, into: &state, at: 10)
    let pastedLow = state.mainClips.first { pasted.clips.contains($0.id) }
    let pastedHigh = state.overlayTracks.first?.clips.first { pasted.clips.contains($0.id) }
    checkEqual(pastedLow?.timelineStart, 10, "主轨那段落在落点（整批最早的开头）")
    checkEqual(pastedHigh?.timelineStart, 11, "上层那段还在它后面 1 秒（相对时间不变）")

    // 主轨那一组撞上了 → 整组往上抬到上层轨 0；上层那一组必须还在它上面 → 上层轨 1（新开）。
    pasted = paste(copied, into: &state, at: 0)
    let lifted = pasted.clips.compactMap { id in track(of: id, in: state).map { (id, $0) } }
    let lowTrack = lifted.first { state.clip(with: $0.0)?.sourceDuration == 4 }?.1
    let highTrack = lifted.first { state.clip(with: $0.0)?.sourceDuration == 2 }?.1
    checkEqual(lowTrack, .overlay(1), "主轨那组撞上了主轨和上层轨 0（那儿 1–3 秒有东西）→ 抬到新开的上层轨")
    checkEqual(highTrack, .overlay(2), "上层那组永远落在下面那组之上（保住叠放关系）")

    // 下面那组抬到上层轨 0 之后，上面那组即使时间上塞得进上层轨 0，也得在它**上面**（不许并到同一条、更不许
    // 落到下面）—— 原来谁压谁，粘出来还是谁压谁。
    var stack = TimelineState()
    let under = clip(0, 1)
    let over = clip(2, 1)
    stack.mainClips = [under, clip(20, 10)]
    stack.overlayTracks = [EditLane(clips: [over])]
    pasted = paste(copy([under.id, over.id], from: stack), into: &stack, at: 20)
    let underTrack = pasted.clips.first { stack.clip(with: $0)?.timelineStart == 20 }.flatMap { track(of: $0, in: stack) }
    let overTrack = pasted.clips.first { stack.clip(with: $0)?.timelineStart == 22 }.flatMap { track(of: $0, in: stack) }
    checkEqual(underTrack, .overlay(0), "主轨 20 秒处占着：下面那组抬到上层轨 0")
    checkEqual(overTrack, .overlay(1), "上面那组（22–23 秒塞得进上层轨 0）仍然新开一条落在它上面")

    // 几组一起粘时，鼠标指着的轨不认（各回各的轨），只拿落点定时间。
    var free = TimelineState()
    free.mainClips = [clip(0, 1)]
    free.overlayTracks = [EditLane(), EditLane(clips: [clip(0, 1)])]
    pasted = paste(copied, into: &free, at: 20, pointing: .track(.overlay(1)))
    checkEqual(pasted.clips.compactMap { track(of: $0, in: free) }.sorted { "\($0)" < "\($1)" },
               [.main, .overlay(0)].sorted { "\($0)" < "\($1)" },
               "两组一起粘：不跟着鼠标换轨，各回各的轨（跨工程时上层轨身份对不上，从主轨起按梯子找）")

    // 转场：一对首尾相接、带转场的主轨段粘回主轨 → 转场还在；抬到上层轨 → 转场去掉。
    var seam = TimelineState()
    var left = clip(0, 5)
    left.transitionAfter = .crossFade
    let right = clip(5, 5)
    seam.mainClips = [left, right]
    let pair = copy([left.id, right.id], from: seam)
    pasted = paste(pair, into: &seam, at: 20)
    checkEqual(seam.mainClips.first { pasted.clips.contains($0.id) && $0.timelineStart == 20 }?.transitionAfter,
               .crossFade, "一对都被拿走、粘回主轨：转场跟着")
    pasted = paste(pair, into: &seam, at: 0)
    checkEqual(seam.overlayTracks.first?.clips.first { pasted.clips.contains($0.id) && $0.timelineStart == 0 }?.transitionAfter,
               ClipTransition.none, "抬到上层轨：转场去掉（转场只有主轨有语义）")
}

private func checkAudioAndLinks() {
    // 声音：原来那条放不下 → 从头找第一条放得下的；都放不下 → 最下面新开一条。
    var state = TimelineState()
    let music = clip(0, 10, audio: true)
    state.audioTracks = [EditLane(clips: [music]), EditLane(clips: [clip(20, 5, audio: true)])]
    let copied = copy([music.id], from: state)
    var pasted = paste(copied, into: &state, at: 3)
    checkEqual(pasted.clips.first.flatMap { track(of: $0, in: state) }, .audio(1),
               "音频轨 0（原来那条）3–13 秒占着 → 音频轨 1 放得下")
    pasted = paste(copied, into: &state, at: 3)
    checkEqual(pasted.clips.first.flatMap { track(of: $0, in: state) }, .audio(2), "都放不下：最下面新开一条")
    pasted = paste(copied, into: &state, at: 40, pointing: .track(.audio(2)))
    checkEqual(pasted.clips.first.flatMap { track(of: $0, in: state) }, .audio(2), "指着的音频轨放得下：就落那儿")

    // 两条音频轨上各一段（时间不重叠）一起粘：还是分在两条轨上，不挤到一条。
    var two = TimelineState()
    let x = clip(0, 2, audio: true)
    let y = clip(5, 2, audio: true)
    two.audioTracks = [EditLane(clips: [x]), EditLane(clips: [y])]
    pasted = paste(copy([x.id, y.id], from: two), into: &two, at: 50)
    checkEqual(Set(pasted.clips.compactMap { track(of: $0, in: two) }).count, 2, "原来分在两条轨上的，粘出来也分开")

    // 链接组：一对视频 + 分离出的音频一起拿 → 粘出来的一对彼此链接，和原来那对不链在一起。
    var linked = TimelineState()
    let group = UUID()
    var video = clip(0, 5)
    video.linkGroup = group
    var voice = clip(0, 5, audio: true)
    voice.linkGroup = group
    linked.mainClips = [video]
    linked.audioTracks = [EditLane(clips: [voice])]
    pasted = paste(copy([video.id, voice.id], from: linked), into: &linked, at: 10)
    let groups = Set(pasted.clips.compactMap { linked.clip(with: $0)?.linkGroup })
    checkEqual(groups.count, 1, "粘出来的一对共用一个链接组")
    check(!groups.contains(group), "新的链接组，不和原来那对链在一起")
    pasted = paste(copy([video.id], from: linked), into: &linked, at: 30)
    checkEqual(pasted.clips.first.flatMap { linked.clip(with: $0)?.linkGroup }, nil as UUID?,
               "只拿到组里一段：不留组号（一个人的链接组没有意义）")

    // 静帧还没转完的图片段：粘完照原图再转一次。
    var still = TimelineState()
    var image = clip(0, 5)
    image.stillImageURL = URL(fileURLWithPath: "/tmp/srtflow-clipboard-check/photo.png")
    image.needsStillConversion = true
    still.mainClips = [image]
    pasted = paste(copy([image.id], from: still), into: &still, at: 10)
    checkEqual(pasted.stillConversions.map(\.image), [image.stillImageURL!], "静帧没转完的：记下来粘完再转")
    checkEqual(pasted.clips.first.flatMap { still.clip(with: $0)?.stillImageURL }, image.stillImageURL,
               "图片段的身份（原图）跟着走（docs/architecture/video-edit-project-file.md「复制路径」）")
}
