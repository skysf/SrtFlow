import SwiftUI

/// 转场选择器（检查器里的入口按钮 + 弹出网格）。
///
/// 网格按族分组（基础 / 推移 / 擦除），每张卡片用接缝两侧的真实缩略帧
/// 演示效果：鼠标悬停就循环播放该转场的小样，点卡片立即应用（弹窗不关，
/// 方便连着试几种）。卡片小样只是示意动画，真正的合成模型见
/// docs/architecture/preview-free-transform.md。
struct TransitionPickerButton: View {
    @Binding var selection: ClipTransition
    /// 接缝两侧的段：出场（选中段）和进场（下一段），缩略帧从这里取。
    var outgoingClip: EditClip
    var incomingClip: EditClip
    /// 透传给网格：哪几种在这条缝上做得出来。
    var isEnabled: (ClipTransition) -> Bool = { _ in true }

    @State private var showsPicker = false

    var body: some View {
        Button {
            showsPicker.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "square.filled.and.line.vertical.and.square")
                Text(LocalizedStringKey(selection.title))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .instantHelp("Pick a transition — hover a card to preview it")
        .popover(isPresented: $showsPicker, arrowEdge: .bottom) {
            // 尺寸钉在这里而不是网格里：同一个网格还要长在侧边栏的转场库上，
            // 那边宽度由分栏器给（见 VideoEditTransitionLibrary.swift）。
            TransitionPickerGrid(
                selection: selection,
                outgoingClip: outgoingClip,
                incomingClip: incomingClip,
                onPick: { selection = $0 },
                isEnabled: isEnabled
            )
            .frame(width: 340, height: 420)
        }
    }
}

/// 卡片网格。两个宿主：检查器的弹窗，和侧边栏常驻的转场库。
///
/// 宿主定宽高，网格本身自适应 —— 侧边栏只有 196…340pt，钉死 340 的话
/// 卡片会被裁掉右边一列。
struct TransitionPickerGrid: View {
    /// 当前高亮的那一种。库面板里是目标接缝上已有的转场；没有接缝就是 nil。
    var selection: ClipTransition?
    /// 接缝两侧的段，演示帧从这里取。**库面板里可能一个接缝都没有**
    /// （主轨不足两段），那时两边都是 nil，小样退回内置的双色渐变占位。
    var outgoingClip: EditClip?
    var incomingClip: EditClip?
    /// 点了一张卡片。
    var onPick: (ClipTransition) -> Void
    /// 这一种在当前这条缝上做不做得出来。**逐张判，不是整块灰** —— 压黑不需要
    /// 两段同时在画面上，所以零余料的缝上它能用、叠化不能用
    ///（TimelineState.rendersAsDipInPlace）。
    var isEnabled: (ClipTransition) -> Bool = { _ in true }
    /// 自带滚动条。弹窗要（高度钉死 420，装不下 12 张卡）；侧边栏那个宿主
    /// **不要** —— 它长在 List 的一节里，外面那层 List 已经在滚了，再套一层
    /// 就是嵌套滚动区，滚轮会卡在里层。
    var scrolls = true

    /// 接缝两侧的演示帧：出场段的尾帧、进场段的首帧。取不到（音频段、
    /// 素材失链）就用内置的双色渐变占位。
    @State private var tailFrame: CGImage?
    @State private var headFrame: CGImage?

    // 92 → 76：侧边栏默认 214pt 宽，扣掉 padding 只剩 190，按 92 起步只排得下
    // 一列。76 起步刚好两列，拖宽到 340 回到三列；弹窗那边 316 的可用宽在两个
    // 值下都是三列，所以检查器的观感不变。
    private let columns = [GridItem(.adaptive(minimum: 76, maximum: 120), spacing: 8)]

    var body: some View {
        Group {
            if scrolls {
                ScrollView { cards }
            } else {
                cards
            }
        }
        // 按接缝取帧，接缝换了就重取。弹窗是用完就关的，`.task` 取一次够用；
        // 库面板常驻，选中和播放头一动接缝就变 —— 不带 id 的话小样会一直停在
        // 第一次打开时的那个接缝上。
        .task(id: seamKey) { await loadSeamFrames() }
    }

    private var cards: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(TransitionGroup.allCases) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.title)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(group.members) { kind in
                            TransitionCard(
                                kind: kind,
                                isSelected: kind == selection,
                                isEnabled: isEnabled(kind),
                                tail: tailFrame,
                                head: headFrame
                            ) {
                                onPick(kind)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        // 必须撑满：这个网格会长在侧边栏 List 的一行里，而 List row 给的是
        // **理想宽度**而不是可用宽度 —— 不撑满的话 LazyVGrid 拿到一个不受限的
        // 提案，会按 `maximum` 排成孤零零的一列（实测 214pt 宽的侧边栏里只剩
        // 一列 120pt 的大卡片）。
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 接缝的身份。两侧的段都可能没有（主轨不足两段）。
    private var seamKey: String {
        "\(outgoingClip?.id.uuidString ?? "-")|\(incomingClip?.id.uuidString ?? "-")"
    }

    private func loadSeamFrames() async {
        if let outgoingClip {
            tailFrame = await Self.seamFrame(for: outgoingClip, atTail: true)
        } else {
            tailFrame = nil
        }
        if let incomingClip {
            headFrame = await Self.seamFrame(for: incomingClip, atTail: false)
        } else {
            headFrame = nil
        }
    }

    /// 接缝旁边的一帧（尾侧取结尾前一点，首侧取开头后一点）。
    private static func seamFrame(for clip: EditClip, atTail: Bool) async -> CGImage? {
        if let stillURL = clip.stillImageURL {
            return await ClipThumbnailCache.shared.stillThumbnail(url: stillURL)
        }
        guard !clip.isAudioOnly else { return nil }
        let window = min(0.6, clip.sourceDuration)
        guard window > 0 else { return nil }
        let start = atTail ? clip.sourceStart + clip.sourceDuration - window : clip.sourceStart
        return await ClipThumbnailCache.shared
            .thumbnails(url: clip.sourceURL, start: start, duration: window, count: 1)
            .first
    }
}

/// 网格的分组：基础（无 + 淡变族）、推移、擦除。
private enum TransitionGroup: CaseIterable, Identifiable {
    case basic, push, wipe

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .basic: return "Basic"
        case .push: return "Push"
        case .wipe: return "Wipe"
        }
    }

    var members: [ClipTransition] {
        switch self {
        // 「无」**不在这里**：它不是一种转场，混在网格里既拖不了、点了又是删除，
        // 语义是脏的（2026-09-20 用户拍板删掉）。取消一条缝的转场走三条路：
        // 点中遮罩按 ⌫、检查器里的「移除转场」、遮罩右键。
        case .basic: return [.crossFade, .blackFade, .whiteFade]
        case .push: return [.pushLeft, .pushRight, .pushUp, .pushDown]
        case .wipe: return [.wipeLeft, .wipeRight, .wipeUp, .wipeDown]
        }
    }
}

/// 单张卡片：16:9 小样 + 名字。悬停时循环演示，不悬停停在中点定格
/// （推移/擦除是对半分屏、压黑/闪白是纯色 —— 静止画面本身就在说明效果）。
private struct TransitionCard: View {
    let kind: ClipTransition
    let isSelected: Bool
    /// 这条缝上做不出来的种类压暗并拦掉点击。小样照画 —— 卡片的第一用途是
    /// 「看看这个转场长什么样」，那件事不需要这条缝做得出来。
    let isEnabled: Bool
    let tail: CGImage?
    let head: CGImage?
    let action: () -> Void

    @State private var hovering = false

    /// 悬停循环：两端各停一小段，中间匀速走完（1.8s 一圈）。
    private static func cycleProgress(at date: Date) -> Double {
        let cycle = 1.8
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle) / cycle
        return min(max((phase - 0.2) / 0.6, 0), 1)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !hovering)) { context in
                    TransitionMiniPreview(
                        kind: kind,
                        progress: hovering
                            ? Self.cycleProgress(at: context.date)
                            : (kind == .none ? 0.25 : 0.5),
                        tail: tail,
                        head: head
                    )
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color.primary.opacity(0.15),
                            lineWidth: isSelected ? 2 : 1
                        )
                )
                Text(LocalizedStringKey(kind.title))
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Color.accentColor : .primary)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { hovering = $0 }
        // 拖到主轨的接缝上 = 在那条缝上套这个转场。库面板和检查器弹窗共用这个
        // 网格，所以两处都能拖，代价为零。
        //
        // **压暗的卡照样可以拖**：`isEnabled` 说的是「当前对着的那条缝」做不做得
        // 出来，而拖是冲着另一条缝去的 —— 不让拖只会让用户觉得这张卡坏了。
        // 能不能落由落点自己按**拖的这一种**重新判（见 transitionDropTarget）。
        .onDrag { TransitionDrag.itemProvider(for: kind) }
    }
}

/// 转场小样：给定进度 0…1，把两帧按该转场的几何画出来。
private struct TransitionMiniPreview: View {
    let kind: ClipTransition
    let progress: Double
    let tail: CGImage?
    let head: CGImage?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                switch kind.family {
                case .fade:
                    fadeStack(size)
                case .push:
                    if let motion = kind.motion {
                        frameView(tail, placeholder: .outgoing, size: size)
                            .offset(
                                x: motion.dx * size.width * progress,
                                y: motion.dy * size.height * progress
                            )
                        frameView(head, placeholder: .incoming, size: size)
                            .offset(
                                x: -motion.dx * size.width * (1 - progress),
                                y: -motion.dy * size.height * (1 - progress)
                            )
                    }
                case .wipe:
                    frameView(head, placeholder: .incoming, size: size)
                    frameView(tail, placeholder: .outgoing, size: size)
                        .mask(Path(kind.wipeRemainingRect(progress: progress, canvas: size)))
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .background(backgroundColor)
        .clipped()
    }

    @ViewBuilder
    private func fadeStack(_ size: CGSize) -> some View {
        switch kind {
        case .crossFade:
            frameView(tail, placeholder: .outgoing, size: size)
            frameView(head, placeholder: .incoming, size: size).opacity(progress)
        case .blackFade, .whiteFade:
            // 半程模型：前半段出场淡走、后半段进场亮起，中点是纯色。
            frameView(tail, placeholder: .outgoing, size: size).opacity(max(0, 1 - progress * 2))
            frameView(head, placeholder: .incoming, size: size).opacity(max(0, progress * 2 - 1))
        default:
            // 无转场 = 硬切。
            if progress < 0.5 {
                frameView(tail, placeholder: .outgoing, size: size)
            } else {
                frameView(head, placeholder: .incoming, size: size)
            }
        }
    }

    private var backgroundColor: Color {
        kind == .whiteFade ? .white : .black
    }

    private enum Placeholder {
        case outgoing, incoming
    }

    @ViewBuilder
    private func frameView(_ image: CGImage?, placeholder: Placeholder, size: CGSize) -> some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                // 没帧可取（音频段/失链素材）：两侧用可区分的渐变占位。
                switch placeholder {
                case .outgoing:
                    LinearGradient(
                        colors: [Color(white: 0.45), Color(white: 0.2)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                case .incoming:
                    LinearGradient(
                        colors: [Color.blue.opacity(0.65), Color.purple.opacity(0.5)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}
