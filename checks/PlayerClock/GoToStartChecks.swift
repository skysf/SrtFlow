import Combine
import Foundation

// 「回到开头」（Return / Home）的自检，main.swift 调它。合同见 PlayerClock.goToStart / wentToStart：
// 播放头回到 0、终结悬停预览，并且**只有它**发 `wentToStart`（时间线听这个滚回最左）。普通的 seek
// —— 包括重建预览之后调用方把播放头放回原位那一下 —— 不许发：发了的话每改一刀时间线都会被拽回去。

func checkGoToStart() {
    let clock = PlayerClock()
    var starts = 0
    var placements: [PlayheadPlacement] = []
    let watch = [
        clock.wentToStart.sink { starts += 1 },
        clock.placed.sink { placements.append($0) }
    ]
    defer { watch.forEach { $0.cancel() } }

    clock.seek(to: 8)
    check(starts == 0, "普通 seek 不许发 wentToStart（重建后放回原位也是 seek，发了时间线会被拽走）")

    clock.peek(at: 12)
    placements.removeAll()
    clock.goToStart()
    check(clock.time == 0, "回到开头：播放头在 0")
    check(clock.peekTime == nil, "回到开头终结悬停预览")
    check(starts == 1, "回到开头发一次 wentToStart（时间线滚回最左），实测 \(starts) 次")
    check(placements.count == 1 && placements.first?.time == 0 && placements.first?.precise == true,
          "回到开头是一次精确放置（检查器、素材库照常跟着刷新）")

    clock.seek(to: 3)
    check(starts == 1, "之后的普通 seek 仍然不发 wentToStart")
}
