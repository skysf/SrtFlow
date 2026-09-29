import Foundation

// MARK: - 定格切口右边剩下的那一小截
//
// 管什么：在一段的最后一帧里定格（想让片子停在这一帧上），切口右边只剩不到一帧：那一截没有自己的一帧画面，留着只会在
// 静帧后面闪一下、带一声咔（2026-09-29 验收实剪：AI 在 39.1 秒定格，静帧后面剩 0.01 秒；
// docs/bugfixes/2026-09-29-freeze-leaves-sliver-after-still.md）。这里判断刚切出来的右半是不是这样一截；
// `TimelineState.insertFreeze` 拿掉它、后面的内容少挪这么长。够一帧的照旧留着（那是还在动的画面和声音），
// AI 的 freeze_frame 在结果里说一声（tail_id）。
// 不管什么：怎么切、怎么挪（insertFreeze）、准入条件（isFreezeEligible）。

enum FreezeSliver {
    /// `clips[index + 1]`（刚切出来的右半）短过它自己的一帧（源帧率换成时间线秒，算上变速）、后面也没接转场时，回它的长度；
    /// 否则 0（不拿掉）。帧率不知道的不动。
    static func length(of clips: [EditClip], after index: Int) -> Double {
        guard clips.indices.contains(index + 1) else { return 0 }
        let rest = clips[index + 1]
        guard rest.transitionAfter == .none, let fps = rest.info?.frameRate, fps > 0 else { return 0 }
        let frame = 1 / (fps * max(0.05, rest.speed))
        return rest.timelineDuration < frame ? rest.timelineDuration : 0
    }
}
