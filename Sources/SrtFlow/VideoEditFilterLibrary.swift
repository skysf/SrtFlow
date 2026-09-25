import CoreImage
import SwiftUI

// 编辑器左边那一栏里的滤镜库。和转场库共用同一栏（顶上一个分段切换），
// 产品口径见 docs/architecture/filters.md。
//
// 卡片小样用**播放头底下的真实画面**，和转场卡片用真实接缝帧是同一个口径 ——
// 「这款滤镜用在我这条片子上是什么样」才是用户要看的，内置样片答不了这个问题。
// 取不到画面（还没导素材、播放头停在空白处、素材失链）就退回内置渐变。

/// 卡片小样那一帧，以及它被十款滤镜各自调色之后的样子。
///
/// 一次取帧、十次调色，全部缓存住 —— 播放头停到别处才失效。调色是 GPU 的，
/// 160px 的图十张加起来也不到一毫秒，但**不能每次 body 求值都重算**：
/// 这一栏常驻，工程一变它就重算（2026-09-25 之前还订阅着时钟，播放中每秒重画二十次）。
@MainActor
final class FilterThumbnailStore: ObservableObject {
    /// 原始帧。
    @Published private(set) var source: CGImage?
    /// 各款滤镜调色后的帧。
    @Published private(set) var graded: [FilterPreset: CGImage] = [:]
    /// 这一份小样对应的是哪一帧（播放头换到别的段/别的时刻就重取）。
    private var loadedKey: String?

    private let context = CIContext(options: [
        .workingColorSpace: FilterLUT.workingColorSpace,
        .outputColorSpace: FilterLUT.workingColorSpace,
    ])

    /// 取帧的身份：段 + 取到第几个十分之一秒。同一秒内来回拖播放头不重取。
    static func key(for clip: EditClip?, time: Double) -> String {
        guard let clip else { return "-" }
        return "\(clip.id.uuidString)|\(Int(clip.sourceTime(atTimeline: time) * 10))"
    }

    func reload(clip: EditClip?, time: Double) async {
        let key = Self.key(for: clip, time: time)
        guard key != loadedKey else { return }
        // 先占住这个 key，免得同一帧被并发要两次。
        loadedKey = key
        guard let clip else {
            source = nil
            graded = [:]
            return
        }
        let frame = await Self.frame(for: clip, at: time)
        // 扫帧的过程中播放头又走了：这一份已经作废，**把 key 让出来**，
        // 否则之后再要这一帧会被上面那道 guard 挡掉，小样永远停在旧画面上。
        if Task.isCancelled {
            loadedKey = nil
            return
        }
        source = frame
        guard let frame else {
            graded = [:]
            return
        }
        var next: [FilterPreset: CGImage] = [:]
        for preset in FilterPreset.allCases {
            next[preset] = grade(frame, preset: preset)
        }
        graded = next
    }

    private func grade(_ image: CGImage, preset: FilterPreset) -> CGImage? {
        guard let filter = FilterLUT.previewFilter(for: preset, strength: 1, name: "card")
        else { return nil }
        filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
        guard let output = filter.outputImage else { return nil }
        return context.createCGImage(output, from: output.extent)
    }

    /// 播放头底下那一段的画面。图片段直读，视频段扫一帧。
    private static func frame(for clip: EditClip, at time: Double) async -> CGImage? {
        if let stillURL = clip.stillImageURL {
            return await ClipThumbnailCache.shared.stillThumbnail(url: stillURL)
        }
        guard !clip.isAudioOnly else { return nil }
        let source = max(clip.sourceStart, min(clip.sourceTime(atTimeline: time),
                                               clip.sourceStart + clip.sourceDuration - 0.05))
        return await ClipThumbnailCache.shared
            .thumbnails(url: clip.sourceURL, start: source, duration: 0.1, count: 1)
            .first
    }
}

/// 左栏里常驻的滤镜库。
struct FilterLibraryPanel: View {
    @ObservedObject var project: VideoEditProject
    /// 卡片小样取的是**停稳了的**播放头底下那一帧（`clock.atRest`，不是时钟本身）：播放中、拖播放头
    /// 的过程中都不换，鼠标在时间线上扫（影子播放头）也不算，停稳了刷新一次（2026-09-25 用户拍板）。
    @ObservedObject var playhead: PacedPlayhead
    // 这个视图用 L10n(...) 拼字符串，不是纯 LocalizedStringKey，光靠环境
    // locale 变化不会重新求值 body，所以要显式观察语言选择。
    @ObservedObject private var languageStore = AppLanguageStore.shared

    @StateObject private var thumbnails = FilterThumbnailStore()

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        VStack(alignment: .leading, spacing: 0) {
            if let note = emptyNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            FilterPickerGrid(
                selection: project.selectedFilter?.preset,
                thumbnails: thumbnails,
                onPick: { project.applyFilterFromLibrary($0) },
                onAdd: { project.addFilter($0) }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // 播放头停稳了才换小样。`task(id:)` 的 id 是「哪一段的哪一帧」（按 0.1s 量化），
        // 而 `playhead` 只在停稳时变 —— 播放中、拖播放头的过程中 id 不动，也就不用再防抖
        //（以前读的是时钟本身，播放中 id 每 0.1s 一换，靠等 0.3 秒挡掉每秒十次取帧、一百次调色）。
        .task(id: FilterThumbnailStore.key(for: clipUnderPlayhead, time: playhead.time)) {
            await thumbnails.reload(clip: clipUnderPlayhead, time: playhead.time)
        }
    }

    /// 小样取帧用的那一段：播放头底下的主轨片段，播放头落在空隙或片尾之后就取
    /// **最近的**一段。
    ///
    /// **不能用 `EditClip.contains(time:)`**：那个判据两端各让了 1ms，是给分割用的
    ///（不许在正好的端点上切），于是「播放头停在片段起点」这个最常见的状态会被
    /// 判成「不在片段里」—— 实测一打开编辑器，十张卡片全是占位渐变。
    ///
    /// 取最近的而不是退回占位：卡片的全部意义就是「这款滤镜用在**我的**画面上是
    /// 什么样」，播放头恰好停在空隙里也该回答这个问题。
    private var clipUnderPlayhead: EditClip? {
        let time = playhead.time
        let clips = project.state.mainClips
        if let covering = clips.first(where: { time >= $0.timelineStart && time < $0.timelineEnd }) {
            return covering
        }
        return clips.min {
            abs($0.timelineStart - time) < abs($1.timelineStart - time)
        }
    }

    private var emptyNote: LocalizedStringKey? {
        guard clipUnderPlayhead == nil else { return nil }
        return "Add a clip to the main track to see each filter on your own footage."
    }
}

/// 卡片网格。
struct FilterPickerGrid: View {
    /// 当前选中的滤镜段用的是哪一款（高亮它）。
    var selection: FilterPreset?
    @ObservedObject var thumbnails: FilterThumbnailStore
    /// 点卡片：选中了某段就换它的种类，否则在播放头新建一段。
    var onPick: (FilterPreset) -> Void
    /// 悬停时右下角那个 `+`：**总是新建一段**。它的语义就是「添加到轨道」，
    /// 选中着别的段时也不该变成「替换」—— 两个入口各说各的会很难解释。
    var onAdd: (FilterPreset) -> Void
    /// 自带滚动条。左栏这个宿主要（十张卡装不下）。
    var scrolls = true

    // 与转场网格同一档：侧边栏默认 214pt 宽，76 起步刚好两列，拖宽到 340 回到三列。
    private let columns = [GridItem(.adaptive(minimum: 76, maximum: 120), spacing: 8)]

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        Group {
            if scrolls {
                ScrollView { cards }
            } else {
                cards
            }
        }
    }

    private var cards: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(FilterPreset.allCases) { preset in
                FilterCard(
                    preset: preset,
                    isSelected: preset == selection,
                    source: thumbnails.source,
                    graded: thumbnails.graded[preset],
                    onPick: { onPick(preset) },
                    onAdd: { onAdd(preset) }
                )
            }
        }
        .padding(12)
        // 必须撑满：这个网格长在侧边栏里，而 List row / VStack 给的是**理想宽度**
        // 而不是可用宽度 —— 不撑满的话 LazyVGrid 会按 `maximum` 排成孤零零一列
        //（转场网格踩过同一个坑）。
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 单张卡片：16:9 小样 + 名字。
///
/// 默认整张显示**调色后**的样子（用户要挑的就是效果）；悬停才左右分割对比
/// （左原图、右滤镜，中线固定不可拖），右下角同时浮出 `+`。
private struct FilterCard: View {
    let preset: FilterPreset
    let isSelected: Bool
    let source: CGImage?
    let graded: CGImage?
    let onPick: () -> Void
    let onAdd: () -> Void

    @State private var hovering = false

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        VStack(spacing: 3) {
            ZStack(alignment: .bottomTrailing) {
                preview
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(
                                isSelected ? Color.accentColor : Color.primary.opacity(0.15),
                                lineWidth: isSelected ? 2 : 1
                            )
                    )
                if hovering {
                    addButton
                        .padding(4)
                        .transition(.opacity)
                }
            }
            Text(LocalizedStringKey(preset.title))
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.accentColor : .primary)
        }
        // 整张卡片可点：点 = 应用（选中着某段就换种类）。`+` 在它上面，
        // 自己把点击吃掉，所以两个动作不会互相触发。
        .contentShape(Rectangle())
        .onTapGesture(perform: onPick)
        .onHover { hovering = $0 }
        // 拖卡片到时间线上落一段。`onDrag` 的载荷仍然照规矩带上，外部工具看得懂；
        // 落点判定走起手时记下的那一笔（同转场，理由见 VideoEditFilterDrag.swift）。
        .onDrag { FilterDrag.itemProvider(for: preset) }
    }

    private var addButton: some View {
        Button(action: onAdd) {
            Image(systemName: "plus")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor))
        }
        .buttonStyle(.plain)
        .instantHelp("Add this filter at the playhead")
    }

    @ViewBuilder
    private var preview: some View {
        GeometryReader { geo in
            ZStack {
                gradedLayer
                if hovering, source != nil {
                    // 悬停：左半边露出原图，中线是固定的。
                    sourceLayer
                        .mask(
                            HStack(spacing: 0) {
                                Rectangle()
                                Color.clear
                            }
                        )
                    Rectangle()
                        .fill(.white.opacity(0.85))
                        .frame(width: 1)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color.black)
        .clipped()
    }

    @ViewBuilder
    private var gradedLayer: some View {
        if let graded {
            Image(decorative: graded, scale: 1).resizable().scaledToFill()
        } else if let source {
            // 调色失败（CI 没给出图）时退回原图，别留一块黑 —— 卡片还得认得出名字。
            Image(decorative: source, scale: 1).resizable().scaledToFill()
        } else {
            placeholder
        }
    }

    @ViewBuilder
    private var sourceLayer: some View {
        if let source {
            Image(decorative: source, scale: 1).resizable().scaledToFill()
        }
    }

    /// 没帧可取时的占位。每款给一个不同的色相，至少卡片之间还分得开。
    private var placeholder: some View {
        let hue = Double(FilterPreset.allCases.firstIndex(of: preset) ?? 0)
            / Double(max(1, FilterPreset.allCases.count))
        return LinearGradient(
            colors: [
                Color(hue: hue, saturation: 0.35, brightness: 0.55),
                Color(hue: hue, saturation: 0.25, brightness: 0.25),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
}
