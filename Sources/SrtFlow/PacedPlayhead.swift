import Combine
import Foundation

// MARK: - 播放头的慢读法
//
// 管什么：从 `PlayerClock` 派生出来的「播放头停在哪儿」—— 只跟着播放头被**放**到哪儿走
// （点标尺、拖播放头、跳到某句字幕），不跟着播放一跳一跳走；播放一停，按停下的位置追上一次。
// 不管什么：真播放头本身（`PlayerClock.time`，播放时每 0.05 秒一跳）、悬停预览的影子播放头。
//
// 为什么要有它（docs/architecture/preview-perf-ratchet.md 第十二节）：订阅时钟的视图，播放时一秒
// 重算二十次。检查器（数值、关键帧 ◇）和素材库那一栏（接缝和画面的小样）只在播放头停着的时候
// 有意义，以前却跟着每一跳重算，连带底下几十个数值框和按钮提示 —— 是播放卡的大头之一
// （docs/bugfixes/2026-09-25-playback-wakes-whole-editor.md）。

/// 播放头被放到了哪儿（`PlayerClock.seek` / 换片 / 卸片时发出）。播放把它带着走的那些时间回调
/// （`observePlaybackTime`）**不算** —— 那正是慢读法要躲开的东西。
struct PlayheadPlacement: Equatable {
    let time: TimeInterval
    /// 精确定位（点一下、松手、跳到字幕）还是拖动中的扫帧（`seek(precise: false)`）。
    let precise: Bool
}

/// 播放头的慢读法，两种节奏：
///
/// - `.whilePaused`：没在播放时，播放头放到哪儿就跟到哪儿（拖播放头的每一下都跟）—— 检查器用：
///   拖着播放头找关键帧时，数值和 ◇ 要跟着变。
/// - `.atRest`：更慢，只认**精确**的放置（点一下、松手）；拖播放头的过程中不跟 —— 素材库那一栏用
///   （2026-09-25 用户拍板：拖动中小样来回换没有意义，停稳了刷一次）。
///
/// 播放中两种都一次不发；播放一停（暂停、播到片尾）追上一次。两种都只认真播放头：悬停预览不改
/// `PlayerClock.time`，也就叫不醒它们。
///
/// 实例由时钟懒建（`PlayerClock.whilePaused` / `.atRest`），同一种节奏全 App 只有一份。
final class PacedPlayhead: ObservableObject {
    enum Pace {
        case whilePaused
        case atRest
    }

    let pace: Pace
    /// 最近一次「停着的」播放头。
    @Published private(set) var time: TimeInterval
    private var subscriptions: Set<AnyCancellable> = []

    init(clock: PlayerClock, pace: Pace) {
        self.pace = pace
        time = clock.time
        clock.placed
            .sink { [weak self, weak clock] placement in
                guard let self, let clock,
                      Self.follows(placement, pace: pace, isPlaying: clock.isPlaying) else { return }
                self.settle(at: placement.time)
            }
            .store(in: &subscriptions)
        // `$isPlaying` 在赋值之前发（willSet）：参数是新值，此刻的 `clock.time` 就是停下来的位置。
        clock.$isPlaying
            .sink { [weak self, weak clock] playing in
                guard let self, let clock, !playing else { return }
                self.settle(at: clock.time)
            }
            .store(in: &subscriptions)
    }

    /// 这一次放置跟不跟。纯规则，自检（checks/PlayerClock）直接测。
    static func follows(_ placement: PlayheadPlacement, pace: Pace, isPlaying: Bool) -> Bool {
        guard !isPlaying else { return false }
        switch pace {
        case .whilePaused: return true
        case .atRest: return placement.precise
        }
    }

    /// 没变不写：`@Published` 写一次就发一次，值一样也发（preview-perf-ratchet.md 第十节）。
    private func settle(at newTime: TimeInterval) {
        if newTime != time { time = newTime }
    }
}
