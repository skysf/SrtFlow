import SwiftUI
import SrtFlowCore

// MARK: - 编辑器里跟着播放头走的那几小块
//
// 管什么：根视图（`VideoEditView`）不再订阅播放器时钟之后，从它身上拆出来的、真要跟着播放头
// 变的几小块 —— 播放条上的播放键和时间读数、预览的播放器画面（此刻的调色），
// 以及「能不能点看播放头」的按钮用的 `.disabled(followingPlayhead:)`。每一块只订阅自己要的那一份。
// 预览上的字幕（`PreviewSubtitleLayer`）同一个道理，住在 VideoEditPreviewSubtitleLayer.swift。
// 不管什么：预览上的形状 / 文字 / 变换框（各自的文件，本来就自己订阅时钟）、时间线上的播放头
// （`VideoEditTimelinePlayhead.swift`）。
//
// 为什么（docs/architecture/preview-perf-ratchet.md 第十二节）：根视图订阅着时钟，播放时一秒二十跳，
// 每一跳整个编辑器（工具栏、检查器、素材库、时间线、一百多个按钮提示）都重算一遍 —— 播放卡的
// 大头（docs/bugfixes/2026-09-25-playback-wakes-whole-editor.md）。

// MARK: - 按钮能不能点看播放头

/// 能不能点取决于播放头在哪的按钮（分割、定格、打标记、删左删右，检查器里的「分割」）。
///
/// 只有这个修饰器订阅时钟：播放每一跳重算的是它自己（算一个布尔），按钮、工具栏、检查器都不被
/// 叫醒。判据闭包每次现读工程和 `clock.time`，和以前写在 body 里的是同一个表达式。
struct PlayheadDisabledModifier: ViewModifier {
    @ObservedObject var clock: PlayerClock
    let isDisabled: () -> Bool

    func body(content: Content) -> some View {
        let _ = PerfCounters.body(Self.self)
        content.disabled(isDisabled())
    }
}

extension View {
    /// `.disabled(...)`，但判据跟着播放头走（见 `PlayheadDisabledModifier`）。
    func disabled(followingPlayhead clock: PlayerClock, _ isDisabled: @escaping () -> Bool) -> some View {
        modifier(PlayheadDisabledModifier(clock: clock, isDisabled: isDisabled))
    }
}

// MARK: - 播放条

/// 播放 / 暂停键。只在播放状态变了时重画（`onReceive` 自己那一份）：它连着一个即时提示
/// 修饰器，跟着时钟每一跳重算的话一跳多算两个 body。
struct TransportPlayButton: View {
    let clock: PlayerClock
    let isDisabled: Bool
    @State private var isPlaying: Bool

    init(clock: PlayerClock, isDisabled: Bool) {
        self.clock = clock
        self.isDisabled = isDisabled
        _isPlaying = State(initialValue: clock.isPlaying)
    }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        Button {
            clock.togglePlayback()
        } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .frame(width: 14)
        }
        .buttonStyle(.borderless)
        .disabled(isDisabled)
        // 回到开头没有自己的按钮，键写在这句提示里才找得到（Return / Home 在 VideoEditView.handleEvent 里接）。
        .instantHelp(
            isPlaying ? LocalizedStringKey("Pause (Return goes back to the start)")
                : LocalizedStringKey("Play (Return goes back to the start)"),
            shortcut: .plain("Space")
        )
        .onReceive(clock.$isPlaying.removeDuplicates()) { isPlaying = $0 }
    }
}

/// 「当前 / 总长」的时间读数。只在显示的那一格（十分之一秒）变了时重画：播放时一秒十次，
/// 不是时钟的二十次，更不连带整个编辑器。
struct TransportTimeLabel: View {
    let clock: PlayerClock
    let duration: Double
    @State private var shown: String

    init(clock: PlayerClock, duration: Double) {
        self.clock = clock
        self.duration = duration
        _shown = State(initialValue: Self.label(clock.time))
    }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        Text("\(shown) / \(Self.label(duration))")
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            // `$time` 在赋值之前发（willSet），参数就是新值。
            .onReceive(clock.$time) { time in
                let next = Self.label(time)
                if next != shown { shown = next }
            }
    }

    static func label(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00.0" }
        let tenth = Int((seconds * 10).rounded())
        return String(format: "%d:%02d.%d", tenth / 600, (tenth / 10) % 60, tenth % 10)
    }
}

// MARK: - 预览

/// 预览的播放器画面 + 此刻的调色（时间轴上的滤镜段）。滤镜跟着播放头换段，所以它订阅时钟；
/// 播放器视图本身只在调色真变了时才更新（`FilterStack` 按值比较，SwiftUI 比得出「没变」）。
///
/// 滤镜挂在播放器视图自己身上，所以预览 ZStack 里它**上面**的叠层（形状 / 文字 / 字幕 / 变换框）
/// 天然不吃调色 —— 与导出滤镜链里「滤镜插在画面合成之后、形状之前」一字不差。
struct PreviewPlayerSurface: View {
    let project: VideoEditProject
    @ObservedObject var clock: PlayerClock

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        PlayerViewRepresentable(
            player: clock.player,
            controlsStyle: .none,
            filterStack: FilterStack(in: project.state, at: clock.displayTime)
        )
    }
}
