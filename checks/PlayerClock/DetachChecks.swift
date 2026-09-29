import AVFoundation
import Foundation

// 卸片（detach）之后晚到的时间回调不许把播放头写回去（2026-09-29，
// docs/bugfixes/2026-09-29-new-project-keeps-old-playhead.md）：播放器换掉条目之后，时间回调还会晚到一拍、
// 报旧条目的时间。新建 / 打开工程都先卸片、播放头归零，那一拍把它写回上一个工程的位置 ——
// 新工程里的配音就放到了 36.3 秒，打开的工程从上一个的位置（或者它的片尾）开始。
// 这里用真的播放器、真的素材（scripts/check-player-clock.sh 用 ffmpeg 现做一段 60 秒的），main.swift 调它。

private func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

private func pump(atMost seconds: Double, until done: () -> Bool) {
    let deadline = Date().addingTimeInterval(seconds)
    while !done(), Date() < deadline { pump(0.02) }
}

func checkDetachDropsLateTicks(clip: URL) {
    for playing in [false, true] {
        let clock = PlayerClock()
        clock.player.isMuted = true          // 在开发机上跑别出声
        clock.attachItem(AVPlayerItem(url: clip))
        pump(atMost: 5) { clock.player.currentItem?.status == .readyToPlay }
        clock.seek(to: 36.3)
        pump(atMost: 5) { abs(clock.player.currentTime().seconds - 36.3) < 0.01 }
        check(abs(clock.player.currentTime().seconds - 36.3) < 0.01,
              "前提：播放器真的到了 36.3（素材读得出来），实测 \(clock.player.currentTime().seconds)")
        if playing {
            clock.player.play()
            pump(0.5)
        }
        // 关工程那两步（VideoEditProject.closeCurrentDocument）。
        clock.pause()
        clock.detach()
        pump(1.0)
        check(clock.time == 0, "卸片之后播放头停在 0（\(playing ? "卸片前在播" : "卸片前停着")），晚到的时间回调不许把它写回旧位置，实测 \(clock.time)")
    }
}
