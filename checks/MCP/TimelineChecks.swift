import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// AI 改时间线的纯值规则：放素材、推 V1、删（ripple）、切、转场、改一段、短 id、轨道名、get_timeline。
// 规则的出处见 docs/architecture/ai-control-mcp.md 第四节。

func runTimelineChecks() {
    shortIDChecks()
    placeChecks()
    deleteSplitTransitionChecks()
    clipEditChecks()
    summaryChecks()
}

private func shortIDChecks() {
    let a = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001")!
    let b = UUID(uuidString: "AAAAAAAA-1111-4000-8000-000000000002")!
    let c = UUID(uuidString: "BBBBBBBB-2222-4000-8000-000000000003")!
    let ids = AIShortIDs([a, b, c])
    checkEqual(ids.short(c).count, 10, "prefixes grow until they are unique (8 chars collide here)")
    checkEqual(try? ids.resolve(ids.short(a)), a, "a shown id resolves back")
    checkEqual(try? ids.resolve(a.uuidString), a, "a full UUID resolves")
    checkEqual(try? ids.resolve("bbbbbbbb"), c, "any unique prefix resolves")
    checkThrows("an ambiguous prefix is refused") { _ = try ids.resolve("aaaaaaaa") }
    checkThrows("an unknown id is refused") { _ = try ids.resolve("cccccccc") }

    var state = TimelineState()
    state.overlayTracks = [EditLane(clips: [videoClip(0, 2)])]
    checkEqual(AITrackName.name(of: .main), "V1", "main is V1")
    checkEqual(AITrackName.name(of: .overlay(0)), "V2", "first overlay is V2")
    checkEqual(AITrackName.name(of: .audio(0)), "A1", "first audio track is A1")
    checkEqual(try? AITrackName.target("v2", in: state), .overlay(0), "V2 is the first overlay")
    checkEqual(try? AITrackName.target("V3", in: state), .newOverlayTop, "one past the last video track opens a new one")
    checkEqual(try? AITrackName.target("A1", in: state), .newAudioBottom, "A1 with no audio tracks opens one")
    checkThrows("V5 does not exist") { _ = try AITrackName.target("V5", in: state) }
    checkThrows("nonsense track names are refused") { _ = try AITrackName.target("Z9", in: state) }
}

private func plan(_ clip: EditClip, audio: Bool = false, target: TrackDropTarget? = nil, start: Double? = nil)
    -> AITimelineEdits.PlannedClip {
    AITimelineEdits.PlannedClip(clip: clip, isAudio: audio, target: target, start: start)
}

private func placeChecks() {
    // 没给起点：接在 V1 最后面，一段接一段。
    var state = TimelineState()
    AITimelineEdits.place([plan(videoClip(0, 4)), plan(videoClip(0, 5)), plan(videoClip(0, 6))],
                          insert: false, linkage: false, in: &state)
    checkEqual(mainStarts(state), [0, 4, 9], "appended clips follow each other on V1")

    // 声音没给轨：从 0 开始，第一条放得下的音频轨；0 上已经有了就新开一条。
    AITimelineEdits.place([plan(audioClip(0, 10), audio: true), plan(audioClip(0, 10), audio: true)],
                          insert: false, linkage: false, in: &state)
    checkEqual(state.audioTracks.count, 2, "a second song at 0 opens A2")
    checkEqual(state.audioTracks.first?.clips.first?.timelineStart, 0, "audio defaults to 0")

    // 撞上了往上抬一轨（和拖文件进来同一个落点算法）。
    var lifted = state
    AITimelineEdits.place([plan(videoClip(0, 2), target: .main, start: 1)], insert: false, linkage: false, in: &lifted)
    checkEqual(lifted.overlayTracks.count, 1, "a clip dropped on a taken V1 spot goes up to V2")
    checkEqual(lifted.mainClips.count, 3, "V1 is untouched")

    // insert：V1 上 4 秒处插 2 秒，后面的整体往后推。
    var inserted = state
    AITimelineEdits.place([plan(videoClip(0, 2), target: .main, start: 4)], insert: true, linkage: false, in: &inserted)
    checkEqual(mainStarts(inserted), [0, 4, 6, 11], "insert pushes the later V1 clips right")

    // 同一批里两段都要新开一条轨：放进同一条。
    var fresh = TimelineState()
    AITimelineEdits.place([plan(videoClip(0, 2), target: .newOverlayTop, start: 0),
                           plan(videoClip(0, 2), target: .newOverlayTop, start: 5)],
                          insert: false, linkage: false, in: &fresh)
    checkEqual(fresh.overlayTracks.count, 1, "two new_video clips in one call share the new track")
    checkEqual(fresh.overlayTracks.first?.clips.count, 2, "both clips are on it")

    // 前一段没点名轨道、只是因为还没有音频轨才开了 A1；后一段点名 new_audio：另开 A2，不许塞进 A1 后面
    //（2026-09-28 冒烟：两首配乐一次放，第二首说要新开一条，却接在了 A1 的 30 秒处）。
    var music = TimelineState()
    AITimelineEdits.place([plan(audioClip(0, 30), audio: true), plan(audioClip(0, 30), audio: true, target: .newAudioBottom)],
                          insert: false, linkage: false, in: &music)
    checkEqual(music.audioTracks.count, 2, "new_audio after a clip that merely opened A1: a new A2")
    checkEqual(music.audioTracks.last?.clips.first?.timelineStart, 0, "and it starts at 0 there")
}

private func deleteSplitTransitionChecks() {
    // 整批 id 先全认一遍：认不出的一起列出来、说明一个都没删（2026-09-29 婚礼工程 ISSUE-21）。
    do {
        var state = TimelineState()
        let keep = videoClip(0, 4)
        state.mainClips = [keep, videoClip(4, 4)]
        let ids = AIShortIDs(state: state)
        do {
            _ = try AITimelineEdits.deletion(of: [ids.short(keep.id), "deadbeef", "feedface"], in: state)
            check(false, "unknown ids in a batch must be refused")
        } catch let error as AIToolError {
            check(error.message.contains("deadbeef") && error.message.contains("feedface"), "every unknown id is named: \(error.message)")
            check(error.message.contains("Nothing was deleted"), "the message says the batch was not applied: \(error.message)")
        } catch {
            check(false, "unexpected error \(error)")
        }
        let good = try? AITimelineEdits.deletion(of: [ids.short(keep.id)], in: state)
        checkEqual(good?.clips, [keep.id], "a batch of known ids resolves to the deletion")
    }

    // ripple：删掉中间那段，后面的补上它的长度；原来就有的空隙留着。
    var state = TimelineState()
    let a = videoClip(0, 4), b = videoClip(5, 4), c = videoClip(10, 5)
    state.mainClips = [a, b, c]
    var rippled = state
    AITimelineEdits.delete(.init(clips: [b.id]), ripple: true, linkage: false, in: &rippled)
    checkEqual(mainStarts(rippled), [0, 6], "ripple closes only the deleted clip's length")
    var plain = state
    AITimelineEdits.delete(.init(clips: [b.id]), ripple: false, linkage: false, in: &plain)
    checkEqual(mainStarts(plain), [0, 10], "without ripple nothing moves")

    // 切：左半留原身份，右半是新的一段，素材位置接得上。
    var cut = TimelineState()
    let long = videoClip(0, 10)
    cut.mainClips = [long]
    let created = (try? AITimelineEdits.split(at: 4, ids: [], linkage: false, in: &cut)) ?? []
    checkEqual(created.count, 1, "one cut makes one new clip")
    checkEqual(cut.clip(with: long.id)?.timelineEnd, 4, "the left half ends at the cut")
    checkEqual(created.first.flatMap { cut.clip(with: $0)?.sourceStart }, 4, "the right half starts 4 s into the file")
    checkThrows("cutting where no clip is fails") { var copy = cut; _ = try AITimelineEdits.split(at: 30, ids: [], linkage: false, in: &copy) }

    // 转场：相接才放得下；有空隙报错；all 只挑相接的缝。
    var seams = TimelineState()
    let x = videoClip(0, 5), y = videoClip(5, 5), z = videoClip(12, 5)
    seams.mainClips = [x, y, z]
    var one = seams
    _ = try? AITimelineEdits.setTransition(.crossFade, duration: 0.5, after: x.id, all: false, in: &one)
    checkEqual(one.clip(with: x.id)?.transitionAfter, .crossFade, "a transition on a touching cut")
    checkThrows("a gap is not a cut") { var copy = seams; _ = try AITimelineEdits.setTransition(.crossFade, duration: nil, after: y.id, all: false, in: &copy) }
    var every = seams
    let changed = (try? AITimelineEdits.setTransition(.blackFade, duration: nil, after: nil, all: true, in: &every)) ?? []
    checkEqual(changed, [x.id], "all=true only uses cuts that touch")
}

private func clipEditChecks() {
    var state = TimelineState()
    let a = videoClip(0, 10, asset: 20), b = videoClip(10, 10, asset: 20)
    state.mainClips = [a, b]
    let still = 60.0

    // 改入出点：起点不动，长度跟着变。
    var trim = AIClipChange()
    trim.sourceIn = 2
    trim.sourceOut = 6
    let trimmed = try? AIClipEdit.apply(trim, to: a.id, linkage: false, stillDuration: still, in: state)
    checkEqual(trimmed?.clip(with: a.id)?.timelineStart, 0, "trimming keeps the start")
    checkEqual(trimmed?.clip(with: a.id)?.sourceStart, 2, "source_in lands")
    checkEqual(trimmed?.clip(with: a.id)?.timelineEnd, 4, "source_out lands")

    // 出点超出素材一丁点夹回来，超多了报错（用 B：它后面没有别的段，拉长了不会撞）。
    var nearEnd = AIClipChange()
    nearEnd.sourceOut = 20.03
    checkEqual((try? AIClipEdit.apply(nearEnd, to: b.id, linkage: false, stillDuration: still, in: state))?
        .clip(with: b.id)?.sourceDuration, 20, "a hair past the end is clamped")
    var pastEnd = AIClipChange()
    pastEnd.sourceOut = 25
    checkThrows("far past the end of the file fails") {
        _ = try AIClipEdit.apply(pastEnd, to: a.id, linkage: false, stillDuration: still, in: state)
    }

    // 挪到别人身上：报冲突、点名是谁。
    var move = AIClipChange()
    move.start = 5
    do {
        _ = try AIClipEdit.apply(move, to: a.id, linkage: false, stillDuration: still, in: state)
        check(false, "moving onto another clip must fail")
    } catch let conflict as AIClipEdit.Conflict {
        checkEqual(conflict.other.id, b.id, "the conflict names the clip in the way")
    } catch {
        check(false, "expected a Conflict, got \(error)")
    }

    // ripple：A 的尾巴往前缩 4 秒，B 跟着往前 4 秒。
    var shorter = AIClipChange()
    shorter.sourceOut = 6
    shorter.ripple = true
    let rippled = try? AIClipEdit.apply(shorter, to: a.id, linkage: false, stillDuration: still, in: state)
    checkEqual(rippled?.clip(with: b.id)?.timelineStart, 6, "ripple pulls the next V1 clip in")

    // 换轨、类型不对报错、音量按 dB。
    var up = AIClipChange()
    up.target = .newOverlayTop
    let lifted = try? AIClipEdit.apply(up, to: b.id, linkage: false, stillDuration: still, in: state)
    checkEqual(lifted?.overlayTracks.first?.clips.first?.id, b.id, "a clip moves up to a new video track")
    var wrongTrack = AIClipChange()
    wrongTrack.target = .newAudioBottom
    checkThrows("a video clip cannot go on an audio track") {
        _ = try AIClipEdit.apply(wrongTrack, to: a.id, linkage: false, stillDuration: still, in: state)
    }
    var quieter = AIClipChange()
    quieter.volumeDB = -6
    let volume = (try? AIClipEdit.apply(quieter, to: a.id, linkage: false, stillDuration: still, in: state))?.clip(with: a.id)?.volume ?? 0
    check(abs(volume - 0.501) < 0.01, "-6 dB is about half the amplitude (got \(volume))")

    // 链接开着：分离出来的声音跟着挪。
    var linked = TimelineState()
    let group = UUID()
    var picture = videoClip(0, 4)
    picture.linkGroup = group
    var sound = audioClip(0, 4)
    sound.linkGroup = group
    linked.mainClips = [picture]
    linked.audioTracks = [EditLane(clips: [sound])]
    var later = AIClipChange()
    later.start = 3
    let moved = try? AIClipEdit.apply(later, to: picture.id, linkage: true, stillDuration: still, in: linked)
    checkEqual(moved?.clip(with: sound.id)?.timelineStart, 3, "the linked audio follows the move")
}

private func summaryChecks() {
    var state = TimelineState()
    var first = videoClip(0, 4)
    first.transitionAfter = .crossFade
    state.mainClips = [first, videoClip(4, 4)]
    state.textOverlays = [TextOverlay(text: "Hello", timelineStart: 1)]
    state.filters = [FilterClip(preset: .warmSun, timelineStart: 0, duration: 3, layer: 0)]
    let ids = AIShortIDs(state: state)
    let context = AITimelineSummary.Context(
        ids: ids, workspace: URL(fileURLWithPath: "/tmp/srtflow-mcp-check"), playhead: 2,
        selection: [first.id], renderSize: CGSize(width: 1920, height: 1080)
    )
    let summary = AITimelineSummary.make(state, context)
    let v1 = summary["tracks"]?.arrayValue?.first
    checkEqual(v1?["track"]?.stringValue, "V1", "the first track is V1")
    checkEqual(v1?["clips"]?.arrayValue?.first?["id"]?.stringValue, ids.short(first.id), "clips carry short ids")
    checkEqual(v1?["clips"]?.arrayValue?.first?["file"]?.stringValue, "source.mp4", "paths inside the folder are relative")
    checkEqual(v1?["clips"]?.arrayValue?.first?["transition_after"]?["type"]?.stringValue, "crossFade", "transitions are listed")
    check(v1?["clips"]?.arrayValue?.first?["speed"] == nil, "default values are left out")
    checkEqual(summary["texts"]?.arrayValue?.first?["text"]?.stringValue, "Hello", "texts are listed")
    checkEqual(summary["filters"]?.arrayValue?.first?["preset"]?.stringValue, "warmSun", "filters are listed")
    checkEqual(summary["selected"]?.arrayValue?.first?.stringValue, ids.short(first.id), "the selection is listed")
    checkEqual(summary["canvas"]?["width"]?.intValue, 1920, "canvas width")
    checkEqual(summary["project"]?.stringValue, "unsaved", "an unsaved project says so")
    var named = context
    named.project = "婚礼_B版.srtflowproj"
    checkEqual(AITimelineSummary.make(state, named)["project"]?.stringValue, "婚礼_B版.srtflowproj",
               "get_timeline names the open project file (several AI sessions on one App)")
}
