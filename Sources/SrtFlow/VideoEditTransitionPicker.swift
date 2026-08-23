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
            TransitionPickerGrid(
                selection: $selection,
                outgoingClip: outgoingClip,
                incomingClip: incomingClip
            )
        }
    }
}

/// 弹窗里的卡片网格。
struct TransitionPickerGrid: View {
    @Binding var selection: ClipTransition
    var outgoingClip: EditClip
    var incomingClip: EditClip

    /// 接缝两侧的演示帧：出场段的尾帧、进场段的首帧。取不到（音频段、
    /// 素材失链）就用内置的双色渐变占位。
    @State private var tailFrame: CGImage?
    @State private var headFrame: CGImage?

    private let columns = [GridItem(.adaptive(minimum: 92, maximum: 120), spacing: 8)]

    var body: some View {
        ScrollView {
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
                                    tail: tailFrame,
                                    head: headFrame
                                ) {
                                    selection = kind
                                }
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
        .frame(width: 340, height: 420)
        .task {
            tailFrame = await Self.seamFrame(for: outgoingClip, atTail: true)
            headFrame = await Self.seamFrame(for: incomingClip, atTail: false)
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
        case .basic: return [.none, .crossFade, .blackFade, .whiteFade]
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
        .onHover { hovering = $0 }
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
