import AVKit
import SwiftUI
import SrtFlowCore

/// 预览的两种看法。
///
/// 一张静态图看不出字幕跟说话对不对得上，所以默认是能播的；但播放时字幕是这边
/// 自己画的近似效果，要看**确切**的样子还得靠 ffmpeg 渲的那一帧。分工是清楚的：
/// 播放核对时间轴，精确帧核对外观。
enum BurnInPreviewMode: String, CaseIterable, Identifiable {
    case playback
    case exactFrame

    var id: String { rawValue }

    var title: String {
        switch self {
        case .playback: return "Play"
        case .exactFrame: return "Exact frame"
        }
    }
}

/// 拖边距滑块时在画面上闪出参考线，停手 3 秒后自己消失。
///
/// 「Side margins 到底在哪儿」光看数字是想象不出来的，尤其它还决定长句在哪换行。
@MainActor
final class MarginGuideFlash: ObservableObject {
    @Published private(set) var isVisible = false

    private var hideTask: Task<Void, Never>?
    private var isDragging = false

    /// 数值变了：显示参考线，并把消失倒计时重新计。
    func flash() {
        isVisible = true
        scheduleHide()
    }

    /// 滑块开始/结束拖动。拖动期间不倒计时，免得按住不动 3 秒后参考线自己没了。
    func setDragging(_ dragging: Bool) {
        isDragging = dragging
        if dragging {
            hideTask?.cancel()
            isVisible = true
        } else {
            scheduleHide()
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard !isDragging else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.isVisible = false
        }
    }
}

/// 烧字幕那一屏中间的预览区：可播放的画面、叠在上面的字幕、精确帧、边距参考线。
struct BurnInPreviewArea: View {
    let item: EncodeItem?
    let style: BurnInStyle
    @Binding var mode: BurnInPreviewMode
    @ObservedObject var renderer: BurnInPreviewRenderer
    @ObservedObject var guides: MarginGuideFlash
    /// 播放器由 BurnInView 持有，不是这个视图自己的 @StateObject —— 放大预览时
    /// 这个视图会被重新创建，播放器要是跟着走，一放大就从头开始播了。
    @ObservedObject var clock: PlayerClock
    /// 正在铺满整个窗口。
    var isExpanded = false
    var onToggleExpand: () -> Void = {}

    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0

    private var cues: [SubtitleCue] { item?.burnIn?.cues ?? [] }
    private var duration: Double { item?.info?.duration ?? 0 }
    private var aspect: Double {
        let value = item?.info?.aspectRatio ?? 16.0 / 9.0
        return value.isFinite && value > 0.1 ? value : 16.0 / 9.0
    }

    var body: some View {
        VStack(spacing: 8) {
            header
            videoBox
            if mode == .playback, item != nil {
                transport
            }
            footnote
        }
        .padding(12)
        .onAppear { attachIfNeeded() }
        .onChange(of: item?.inputURL) { _, _ in attachIfNeeded(force: true) }
        .onChange(of: renderer.cueIndex) { _, index in
            // 步进到某一句时把播放头也带过去 —— 核对某句字幕最快的方式就是跳到它。
            if mode == .playback { seekToCue(index) }
        }
        .onDisappear { clock.pause() }
    }

    // MARK: - 顶部：看法切换 + 按字幕跳转

    private var header: some View {
        HStack(spacing: 10) {
            Picker("", selection: $mode) {
                ForEach(BurnInPreviewMode.allCases) { option in
                    Text(LocalizedStringKey(option.title)).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if renderer.isRendering {
                ProgressView().controlSize(.small)
            }

            Button(action: onToggleExpand) {
                Image(systemName: isExpanded
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderless)
            .instantHelp(isExpanded
                  ? LocalizedStringKey("Shrink the preview (Esc)")
                  : LocalizedStringKey("Fill the window with the preview"))

            Spacer()

            if !cues.isEmpty {
                Text("Preview line")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Stepper(value: $renderer.cueIndex, in: 0...(cues.count - 1)) {
                    Text("\(min(renderer.cueIndex, cues.count - 1) + 1) / \(cues.count)")
                        .font(.callout)
                        .monospacedDigit()
                }
                Text(cueText(at: renderer.cueIndex).replacingOccurrences(of: "\n", with: " "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 220, alignment: .leading)
            }
        }
    }

    // MARK: - 画面

    /// 画面框严格按视频比例来，所以框内坐标和视频坐标是一回事 ——
    /// 字幕叠层和边距参考线才能画在对的位置上。
    private var videoBox: some View {
        GeometryReader { proxy in
            let size = fitted(in: proxy.size)
            ZStack {
                Color.black
                media
                if mode == .playback, let cue = activeCue {
                    BurnInSubtitleOverlay(
                        text: SubtitleSerializer.plainText(cue.text),
                        style: style,
                        scale: size.height / Double(BurnInStyle.referenceHeight),
                        boxSize: size
                    )
                }
                if guides.isVisible {
                    MarginGuideOverlay(
                        style: style,
                        scale: size.height / Double(BurnInStyle.referenceHeight),
                        boxSize: size
                    )
                    .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(minHeight: 240)
        .animation(.easeInOut(duration: 0.2), value: guides.isVisible)
    }

    @ViewBuilder
    private var media: some View {
        if item == nil {
            Text("Add a video with subtitles to see a preview.")
                .foregroundStyle(.secondary)
        } else {
            switch mode {
            case .playback:
                PlayerViewRepresentable(player: clock.player, controlsStyle: .none)
            case .exactFrame:
                exactFrame
            }
        }
    }

    @ViewBuilder
    private var exactFrame: some View {
        if let image = renderer.image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else if let message = renderer.errorMessage {
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        } else {
            Text("Rendering preview…").foregroundStyle(.secondary)
        }
    }

    private func fitted(in available: CGSize) -> CGSize {
        guard available.width > 1, available.height > 1 else { return CGSize(width: 1, height: 1) }
        var width = available.width
        var height = width / aspect
        if height > available.height {
            height = available.height
            width = height * aspect
        }
        return CGSize(width: width, height: height)
    }

    // MARK: - 播放条

    private var transport: some View {
        HStack(spacing: 10) {
            Button {
                clock.togglePlayback()
            } label: {
                Image(systemName: clock.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 12)
            }
            .buttonStyle(.borderless)
            .instantHelp(clock.isPlaying ? LocalizedStringKey("Pause") : LocalizedStringKey("Play"), shortcut: .plain("Space"))

            Text(clockLabel(displayTime))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Slider(
                value: scrubBinding,
                in: 0...max(duration, 0.1),
                onEditingChanged: { editing in
                    if editing {
                        scrubTime = clock.time
                        isScrubbing = true
                    } else {
                        isScrubbing = false
                        // 松手时做一次精确定位：核对时间轴时差半秒就没意义了。
                        clock.seek(to: scrubTime, precise: true)
                    }
                }
            )

            Text(clockLabel(duration))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var displayTime: Double { isScrubbing ? scrubTime : clock.time }

    /// `m:ss`。`MediaFormatting.duration` 在 0 上显示「—」，播放头停在开头时不合适。
    private func clockLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var scrubBinding: Binding<Double> {
        Binding(
            get: { displayTime },
            set: { newValue in
                scrubTime = newValue
                // 拖动过程中走链式精确 seek：逐帧刷新且不淹解码器。
                clock.seek(to: newValue, precise: false)
            }
        )
    }

    private var footnote: some View {
        HStack {
            // 两条说明必须各自是字面量：Text(某个拼出来的 String) 不会去查字符串表，
            // 三元表达式拼出来的就是普通 String，中文界面下会漏成英文。
            if mode == .playback {
                Text("Playback draws the subtitles itself: the timing is exact, the look is close but not final. Switch to Exact frame to judge the look.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("The exact frame is rendered by ffmpeg with the export settings, so it matches the result exactly.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if isExpanded {
                Text("Esc to shrink · ⌃⌘F for full screen")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - 字幕与播放头

    /// 当前时刻该显示哪句。重叠的取后一句，跟 libass 的叠放顺序大致一致。
    private var activeCue: SubtitleCue? {
        let time = clock.time
        return cues.last { $0.start <= time && time < $0.end }
    }

    private func cueText(at index: Int) -> String {
        guard !cues.isEmpty else { return "" }
        return SubtitleSerializer.plainText(cues[min(max(0, index), cues.count - 1)].text)
    }

    private func seekToCue(_ index: Int) {
        guard !cues.isEmpty else { return }
        let cue = cues[min(max(0, index), cues.count - 1)]
        // 落在这句的开头稍后一点：正好卡在 start 上有时会取到上一帧。
        clock.seek(to: cue.start + 0.05)
    }

    private func attachIfNeeded(force: Bool = false) {
        guard let url = item?.inputURL else {
            if clock.hasVideo { clock.detach() }
            return
        }
        let current = (clock.player.currentItem?.asset as? AVURLAsset)?.url
        guard force || current != url else { return }
        // 不自动播放：切到这一栏就突然出声很吓人。
        clock.attach(url: url, autoplay: false)
        if !cues.isEmpty { seekToCue(renderer.cueIndex) }
    }
}

// MARK: - 叠在画面上的字幕

/// 按当前样式把一句字幕画在画面上。
///
/// 这是**近似**效果，不是 libass 的输出。SwiftUI 的 Text 画不了描边，所以用八个
/// 方向的副本垫在下面充当描边 —— 在实际会用到的描边宽度（1080p 基准 1～6 px）下
/// 看起来足够接近。字号、边距都按 1080 基准换算到画面框的实际尺寸。
/// 视频编辑器的预览也用它画字幕轨，所以不是 private。
struct BurnInSubtitleOverlay: View {
    let text: String
    let style: BurnInStyle
    let scale: Double
    let boxSize: CGSize
    /// 工程级布局覆盖（视频编辑器的拖框产物，SrtFlowCore/SubtitleLayout）。
    /// 有它时锚定固定为底部中心、边距/字号倍率全听它的 —— 与 ASS 侧
    /// `assStyle(layout:)` 是同一份合同。烧录工具的预览不传（nil）。
    var layout: SubtitleLayout? = nil
    /// 文本块实测尺寸的回报（字幕拖框要用块高定框）。
    var onBlockSize: ((CGSize) -> Void)? = nil

    /// 八个方向，对角线用 0.707 让描边圆一点。
    private static let outlineOffsets: [CGPoint] = [
        CGPoint(x: 1, y: 0), CGPoint(x: -1, y: 0),
        CGPoint(x: 0, y: 1), CGPoint(x: 0, y: -1),
        CGPoint(x: 0.707, y: 0.707), CGPoint(x: -0.707, y: 0.707),
        CGPoint(x: 0.707, y: -0.707), CGPoint(x: -0.707, y: -0.707)
    ]

    var body: some View {
        ZStack(alignment: alignment) {
            Color.clear
            block
                .padding(.leading, leadingPad)
                .padding(.trailing, trailingPad)
                .padding(.bottom, bottomPad)
                .padding(.top, topPad)
        }
        .frame(width: boxSize.width, height: boxSize.height)
        .allowsHitTesting(false)
        .onPreferenceChange(SubtitleBlockSizeKey.self) { size in
            onBlockSize?(size)
        }
    }

    private var block: some View {
        strokedText
            .padding(boxPadding)
            .background { boxBackground }
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: SubtitleBlockSizeKey.self, value: proxy.size)
                }
            }
            .frame(maxWidth: usableWidth, alignment: frameAlignment)
    }

    private var leadingPad: Double {
        if let layout { return Double(layout.marginLeft) * scale }
        return style.position.column == 0 ? horizontalMargin : 0
    }

    private var trailingPad: Double {
        if let layout { return Double(layout.marginRight) * scale }
        return style.position.column == 2 ? horizontalMargin : 0
    }

    private var bottomPad: Double {
        if let layout { return Double(layout.marginBottom) * scale }
        return style.position.row == 0 ? verticalMargin : 0
    }

    private var topPad: Double {
        guard layout == nil else { return 0 }
        return style.position.row == 2 ? verticalMargin : 0
    }

    private var strokedText: some View {
        ZStack {
            if outlineRadius > 0.3 {
                ForEach(Self.outlineOffsets.indices, id: \.self) { index in
                    let offset = Self.outlineOffsets[index]
                    baseText
                        .foregroundStyle(style.outlineColor.swiftUIColor)
                        .offset(x: offset.x * outlineRadius, y: offset.y * outlineRadius)
                }
            }
            baseText.foregroundStyle(style.fillColor.swiftUIColor)
        }
        .shadow(
            color: shadowOffset > 0 ? style.shadowColor.swiftUIColor : .clear,
            radius: 0,
            x: shadowOffset,
            y: shadowOffset
        )
    }

    private var baseText: some View {
        Text(text)
            .font(font)
            .tracking(style.letterSpacing * scale)
            .multilineTextAlignment(textAlignment)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var font: Font {
        var result = Font.custom(
            style.fontName, size: style.fontSize * (layout?.fontScale ?? 1) * scale
        )
        if style.bold { result = result.weight(.bold) }
        if style.italic { result = result.italic() }
        return result
    }

    /// 描边模式才有描边；底框模式下 libass 不画描边。
    private var outlineRadius: Double {
        style.borderStyle == .outline ? style.outlineWidth * scale : 0
    }

    private var shadowOffset: Double {
        style.borderStyle == .outline ? style.shadowOffset * scale : 0
    }

    /// 底框模式下 outlineWidth 是内边距、outlineColor 是底框颜色。
    private var boxPadding: Double {
        style.borderStyle == .box ? max(0, style.outlineWidth * scale) : 0
    }

    @ViewBuilder
    private var boxBackground: some View {
        if style.borderStyle == .box {
            style.outlineColor.swiftUIColor
        }
    }

    private var horizontalMargin: Double { Double(style.marginHorizontal) * scale }
    private var verticalMargin: Double { Double(style.marginVertical) * scale }

    /// 两侧边距同时决定长句在哪里换行（布局覆盖时左右可以不对称）。
    private var usableWidth: Double {
        if layout != nil {
            return max(20, boxSize.width - leadingPad - trailingPad)
        }
        return max(20, boxSize.width - 2 * horizontalMargin)
    }

    private var alignment: Alignment {
        if layout != nil { return .bottom }
        switch (style.position.column, style.position.row) {
        case (0, 0): return .bottomLeading
        case (1, 0): return .bottom
        case (2, 0): return .bottomTrailing
        case (0, 1): return .leading
        case (1, 1): return .center
        case (2, 1): return .trailing
        case (0, 2): return .topLeading
        case (1, 2): return .top
        default: return .topTrailing
        }
    }

    private var frameAlignment: Alignment {
        guard layout == nil else { return .center }
        switch style.position.column {
        case 0: return .leading
        case 2: return .trailing
        default: return .center
        }
    }

    private var textAlignment: TextAlignment {
        guard layout == nil else { return .center }
        switch style.position.column {
        case 0: return .leading
        case 2: return .trailing
        default: return .center
        }
    }
}

/// BurnInSubtitleOverlay 文本块实测尺寸（字幕拖框定高用）。
private struct SubtitleBlockSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

// MARK: - 边距参考线

/// 边距参考线：两条竖线是左右边距（也就是长句换行的位置），一条横线是到边缘的距离。
private struct MarginGuideOverlay: View {
    let style: BurnInStyle
    let scale: Double
    let boxSize: CGSize

    private var sideInset: Double { Double(style.marginHorizontal) * scale }
    private var edgeInset: Double { Double(style.marginVertical) * scale }

    var body: some View {
        ZStack(alignment: .topLeading) {
            verticalGuide(at: sideInset, label: "\(style.marginHorizontal)", labelOnRight: true)
            verticalGuide(at: boxSize.width - sideInset, label: "\(style.marginHorizontal)", labelOnRight: false)
            if !style.position.isVerticallyCentered {
                horizontalGuide(
                    at: style.position.row == 0 ? boxSize.height - edgeInset : edgeInset,
                    label: "\(style.marginVertical)"
                )
            }
        }
        .frame(width: boxSize.width, height: boxSize.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func verticalGuide(at x: Double, label: String, labelOnRight: Bool) -> some View {
        let clamped = min(max(0, x), boxSize.width)
        return ZStack(alignment: labelOnRight ? .topLeading : .topTrailing) {
            Rectangle()
                .fill(Color.accentColor.opacity(0.9))
                .frame(width: 1, height: boxSize.height)
            GuideLabel(text: label)
                .padding(.horizontal, 4)
                .padding(.top, 4)
        }
        .frame(width: 60, alignment: labelOnRight ? .leading : .trailing)
        .offset(x: labelOnRight ? clamped : clamped - 60)
    }

    private func horizontalGuide(at y: Double, label: String) -> some View {
        let clamped = min(max(0, y), boxSize.height)
        return ZStack(alignment: .bottomLeading) {
            Rectangle()
                .fill(Color.accentColor.opacity(0.9))
                .frame(width: boxSize.width, height: 1)
            GuideLabel(text: label)
                .padding(.leading, 6)
                .padding(.bottom, 3)
        }
        .frame(width: boxSize.width, height: 20, alignment: .bottomLeading)
        .offset(y: clamped - 20)
    }
}

private struct GuideLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.accentColor.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
    }
}
