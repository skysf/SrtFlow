import Combine
import Foundation

// 播放头慢读法（PacedPlayhead）的自检，main.swift 调它。合同见 Sources/SrtFlow/PacedPlayhead.swift
// 与 docs/architecture/preview-perf-ratchet.md 第十二节：只跟「放置」；播放中不跟、停下追上一次；
// 悬停预览和播放把它带着走的时间回调都叫不醒它。

func checkPacedPlayhead() {
    // 规则本身（纯函数）。
    let precise = PlayheadPlacement(time: 1, precise: true)
    let scrub = PlayheadPlacement(time: 1, precise: false)
    check(PacedPlayhead.follows(precise, pace: .whilePaused, isPlaying: false), "停着时点一下：检查器跟")
    check(PacedPlayhead.follows(scrub, pace: .whilePaused, isPlaying: false), "停着时拖播放头：检查器每一下都跟")
    check(PacedPlayhead.follows(precise, pace: .atRest, isPlaying: false), "停着时点一下 / 松手：素材库跟")
    check(!PacedPlayhead.follows(scrub, pace: .atRest, isPlaying: false), "拖播放头的过程中素材库不跟")
    check(!PacedPlayhead.follows(precise, pace: .whilePaused, isPlaying: true), "播放中点标尺：检查器不跟")
    check(!PacedPlayhead.follows(precise, pace: .atRest, isPlaying: true), "播放中点标尺：素材库不跟")

    // 接在真时钟上：谁叫得醒它、谁叫不醒。
    let clock = PlayerClock()
    let paused = clock.whilePaused
    let rest = clock.atRest
    var pausedSends = 0
    var restSends = 0
    let watch = [
        paused.$time.dropFirst().sink { _ in pausedSends += 1 },
        rest.$time.dropFirst().sink { _ in restSends += 1 },
    ]
    defer { withExtendedLifetime(watch) {} }

    clock.seek(to: 4)
    check(paused.time == 4 && rest.time == 4, "精确定位：两种都跟到 4")
    clock.seek(to: 5, precise: false)
    check(paused.time == 5, "拖播放头：检查器跟到 5")
    check(rest.time == 4, "拖播放头的过程中素材库停在 4")
    clock.seek(to: 6, precise: true)
    check(rest.time == 6, "松手：素材库追上 6")
    clock.peek(at: 9)
    check(paused.time == 6 && rest.time == 6, "悬停预览叫不醒慢读法")
    clock.endPeek()
    let before = (pausedSends, restSends)
    clock.observePlaybackTime(7)
    check(paused.time == 6 && rest.time == 6, "播放把它带着走的时间回调不算放置")
    check((pausedSends, restSends) == before, "时间回调一次都不发")
    clock.seek(to: 6)
    check((pausedSends, restSends) == before, "放回同一刻：没变不发")

    // 播放中：放置不跟；停下来按停下的位置追上一次。
    clock.togglePlayback()
    check(clock.isPlaying, "（前提）togglePlayback 之后在播放")
    clock.seek(to: 8)
    clock.observePlaybackTime(8.5)
    check(paused.time == 6 && rest.time == 6, "播放中点标尺、时钟往前走：两种都不跟")
    clock.pause()
    check(!clock.isPlaying, "（前提）pause 之后停了")
    check(paused.time == 8.5 && rest.time == 8.5, "停下：两种都追上停下的位置 8.5")
}
