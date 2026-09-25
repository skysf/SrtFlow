import SwiftUI
import SrtFlowCore

// MARK: - 编辑器里跟着播放头走的那几小块
//
// 管什么：根视图（`VideoEditView`）不再订阅播放器时钟之后，从它身上拆出来的、真要跟着播放头
// 变的几小块 —— 播放条上的播放键和时间读数、预览的播放器画面（此刻的调色）、预览上的字幕，
// 以及「能不能点看播放头」的按钮用的 `.disabled(followingPlayhead:)`。每一块只订阅自己要的那一份。
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
        .instantHelp(isPlaying ? LocalizedStringKey("Pause") : LocalizedStringKey("Play"), shortcut: .plain("Space"))
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
    @ObservedObject var project: VideoEditProject
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

/// 预览上的字幕：播放头此刻的字幕文本、画面上点选 / 双击就地改字的那一层、轨道上选中 cue 时的
/// 工程级拖框。字幕跟着播放头换句，所以它订阅时钟；描边文字那一块按值比较，换了句才重排。
///
/// body 直接给出这几层、不包容器：它们和以前一样是预览 ZStack 的孩子（层序见
/// `VideoEditSubtitlePreviewEditor.swift` 的说明）。
struct PreviewSubtitleLayer: View {
    @ObservedObject var project: VideoEditProject
    @ObservedObject var clock: PlayerClock
    let boxSize: CGSize
    let style: BurnInStyle
    /// 当前字幕文本块的实测高度（字幕拖框定框用），由文字那一块回报。
    @Binding var blockHeight: Double
    /// 预览里正在就地编辑的那条字幕（双击画面上的字幕进入）。
    @Binding var editingCueID: UUID?

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        if let text = currentText {
            PreviewSubtitleText(
                text: text,
                style: style,
                scale: boxSize.height / Double(BurnInStyle.referenceHeight),
                boxSize: boxSize,
                layout: project.state.subtitleLayout,
                onBlockSize: { blockHeight = $0.height }
            )
            .equatable()
            // 画面上的字幕：单击选中这句、双击就地改字（输入框浮在字幕下方）。
            // 夹在叠层和拖框中间 —— 见该文件的层序说明。
            SubtitlePreviewEditLayer(
                project: project,
                clock: clock,
                boxSize: boxSize,
                style: style,
                blockHeight: blockHeight,
                editingCueID: $editingCueID
            )
            // 轨道上点选了 cue：叠出工程级字幕拖框（移动/换行宽度/等比字号）。
            // 放最上层 —— 有选中时字幕调整优先。
            if let cueID = project.selectedSubtitleCueID,
               project.state.subtitle?.cues.contains(where: { $0.id == cueID }) == true {
                SubtitleFrameCanvas(
                    project: project,
                    boxSize: boxSize,
                    style: style,
                    blockHeight: blockHeight,
                    // 框盖住了字幕，双击就地编辑这一路从框上补进来。
                    onDoubleClick: {
                        if clock.isPlaying { clock.togglePlayback() }
                        editingCueID = cueID
                    }
                )
            }
        }
    }

    /// 播放头此刻的字幕文本（字幕轨直接按时间线时间对齐）。
    /// 多条重叠 cue 全部显示，顺序走第 9 节合同（与烧录共用同一排序实现）；
    /// 显示什么由两条字幕轨的眼睛推导（visibleSubtitleChoice），没有模式选择器。
    private var currentText: String? {
        // 眼睛是唯一的判据：两只都关（或没有字幕轨）就是 nil，预览不画。
        // 不再需要「选中的轨道已经不存在」那种回退 —— 译文被删时
        // hasVisibleTranslation 自然为假，推导出的选择永远指向真实存在的轨。
        guard let doc = project.state.visibleSubtitleDocument() else { return nil }
        // displayTime：悬停预览时字幕要和画面显示的那一帧对上，而不是播放头。
        let active = SubtitleOverlap.active(at: clock.displayTime, in: doc.cues)
        guard !active.isEmpty else { return nil }
        // doc.cues 已按合同排序，active 保序。overlay 文本块底部对齐，
        // 而 libass 把最早的事件排在最底、后来的往上叠 —— 所以显示时要
        // 倒序拼行（合同序的第一条落在最后一行 = 画面最底），预览和
        // 烧录的堆叠方向才一致。
        let text = active.reversed().map { SubtitleSerializer.plainText($0.text) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
}

/// 画面字幕的文字那一块，按值比较：描边是同一段字画九遍，跟着时钟每一跳重排一遍不便宜。
/// 文字、样式、尺寸没变就不重算；回报块高的闭包不比（它写的是根视图的 @State，永远是最新的）。
private struct PreviewSubtitleText: View, Equatable {
    let text: String
    let style: BurnInStyle
    let scale: Double
    let boxSize: CGSize
    let layout: SubtitleLayout?
    let onBlockSize: (CGSize) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.style == rhs.style && lhs.scale == rhs.scale
            && lhs.boxSize == rhs.boxSize && lhs.layout == rhs.layout
    }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        BurnInSubtitleOverlay(
            text: text,
            style: style,
            scale: scale,
            boxSize: boxSize,
            layout: layout,
            onBlockSize: onBlockSize
        )
    }
}
