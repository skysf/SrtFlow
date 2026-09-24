import AVFoundation
import SwiftUI

// 左栏的音频页。产品口径见 docs/plans/2026-09-22-audio-library.md 第九节。
//
// **为什么是列表不是网格**：这一栏只有 196pt（宽度预算见 VideoEditLibraryColumn），
// 滤镜和转场用网格是因为卡片本身要看（小样就是内容），而一首曲子的封面看不出
// 任何有用信息 —— 用户要读的是曲名、时长和标签，那是文字，文字排成一列才好读。
//
// **音乐和音效不做内层分段**（plan 第九节）：它们本来就是两个 tag，靠筛选区分，
// 省下一层控件。196pt 里已经有分段切换 + 搜索框 + 筛选条了。

struct AudioLibraryPanel: View {
    @ObservedObject var project: VideoEditProject
    @ObservedObject private var store = AudioLibraryStore.music
    @ObservedObject private var cache = AudioLibraryCache.shared
    @ObservedObject private var audition = AudioLibraryAudition.shared
    // 这个视图用 L10n(...) 拼字符串，光靠环境 locale 变化不会重新求值 body，
    // 所以要显式观察语言选择（同滤镜库那条理由）。
    @ObservedObject private var languageStore = AppLanguageStore.shared

    @State private var query = ""
    /// 选中的筛选标签（英文 id 作为键，显示时按语言取）。多选之间是**与**，
    /// 和搜索框里多个词的口径一致。
    @State private var activeTags: Set<String> = []

    /// tag 是**数据**（双语对照在 manifest 里，不进 Localizable.strings），所以
    /// 得自己判当前该显示哪一种语言 —— `Text(LocalizedStringKey)` 那条路不适用。
    /// `.system` 要解析成系统实际选的那个，和 `L10n` 的查表口径一致。
    private var isChinese: Bool {
        switch languageStore.language {
        case .simplifiedChinese: return true
        case .english: return false
        case .system: return (Bundle.main.preferredLocalizations.first ?? "en").hasPrefix("zh")
        }
    }

    @State private var showsCredits = false
    @State private var showsClearConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
            if !allTags.isEmpty { tagFilter }
            Divider()
            content
            if !store.state.items.isEmpty { creditsBar }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showsCredits) {
            AudioLibraryCreditsView(items: store.state.items, usedIDs: usedRemoteKeys).appLanguage()
        }
        .onAppear { store.loadIfNeeded() }
        .onDisappear {
            // 切走这一页就停试听 —— 声音还在响而界面已经不见了，用户找不到从哪停。
            audition.stop(timelinePlayer: project.clock.player)
        }
    }

    // MARK: - 搜索与筛选

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(L10n("Search music"), text: $query)
                .textFieldStyle(.plain)
                .font(.caption)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    /// 出现在当前结果里的标签，按组排。只列真的有素材的，避免点了一个空筛选。
    private var allTags: [AudioLibraryTag] {
        var seen: [String: AudioLibraryTag] = [:]
        for item in store.state.items {
            for tag in item.tags where seen[tag.en] == nil { seen[tag.en] = tag }
        }
        let order = ["mood": 0, "scene": 1, "texture": 2]
        return seen.values.sorted {
            (order[$0.group] ?? 9, $0.en) < (order[$1.group] ?? 9, $1.en)
        }
    }

    private var tagFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(allTags, id: \.en) { tag in
                    let on = activeTags.contains(tag.en)
                    Button {
                        if on { activeTags.remove(tag.en) } else { activeTags.insert(tag.en) }
                    } label: {
                        Text(tag.label(chinese: isChinese))
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                                        in: Capsule())
                            .foregroundStyle(on ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
        }
    }

    private var visibleItems: [AudioLibraryItem] {
        var items = AudioLibraryManifest.filter(store.state.items, query: query)
        if !activeTags.isEmpty {
            items = items.filter { item in
                let names = Set(item.tags.map(\.en))
                return activeTags.isSubset(of: names)
            }
        }
        return items
    }

    // MARK: - 列表

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .idle, .loading:
            centered { ProgressView().controlSize(.small) }
        case .failed(let message):
            centered {
                VStack(spacing: 8) {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L10n("Try again")) { store.reload() }
                        .controlSize(.small)
                }
                .padding(.horizontal, 12)
            }
        case .loaded:
            if visibleItems.isEmpty {
                centered {
                    Text(L10n("No music matches."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                list
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if store.isStale {
                    Label(L10n("Offline — showing the last known list."), systemImage: "wifi.slash")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                ForEach(visibleItems) { item in
                    AudioLibraryRow(
                        item: item,
                        isChinese: isChinese,
                        onAudition: {
                            audition.toggle(item, timelinePlayer: project.clock.player)
                        },
                        onAdd: { add(item) }
                    )
                    Divider().padding(.leading, 44)
                }
            }
        }
    }

    private func centered<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        VStack { Spacer(); content(); Spacer() }
            .frame(maxWidth: .infinity)
    }

    // MARK: - 署名

    /// 当前工程里用到的音频库素材。**所有轨都要扫** —— 用户完全可以把一段音乐
    /// 拖到上层视频轨上当纯音频用，只扫 `audioTracks` 会漏掉它，而漏掉一条
    /// 就是漏掉一次署名。
    private var usedRemoteKeys: Set<String> {
        Set(project.state.allClips.compactMap(\.remoteKey))
    }

    /// 库底下常驻的一行：署名入口 + 已下载素材的清理入口。
    ///
    /// 署名那半**不是可有可无的装饰** —— CC-BY 要求署名，这是用户履行义务的
    /// 唯一入口，所以只要库里有东西它就在。
    ///
    /// 清理那半是缓存落在 `Application Support` 的代价：系统不会替我们清，
    /// 就得自己给个入口（见 `AudioLibraryCache` 的文件头）。
    private var creditsBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 4) {
                Button {
                    showsCredits = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "info.circle")
                        Text("Credits")
                        if !usedRemoteKeys.isEmpty {
                            Text(verbatim: "\(usedRemoteKeys.count)")
                                .monospacedDigit()
                                .padding(.horizontal, 5)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .instantHelp("Where this music comes from, and how to credit it")

                Spacer(minLength: 0)

                if !cache.cachedIDs.isEmpty {
                    Button {
                        showsClearConfirm = true
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.down.circle")
                            Text(verbatim: MediaFormatting.bytes(cache.totalSize))
                                .monospacedDigit()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .instantHelp("Downloaded tracks — click to free the space")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .confirmationDialog(
            L10n("Remove downloaded music?"),
            isPresented: $showsClearConfirm, titleVisibility: .visible
        ) {
            Button(L10n("Remove"), role: .destructive) {
                do {
                    try cache.clearAll()
                } catch {
                    project.notice = error.localizedDescription
                }
            }
            Button(L10n("Cancel"), role: .cancel) {}
        } message: {
            // 说清楚「不会丢」：用户最怕的是把工程里正在用的音乐删掉。
            Text("Projects that use these tracks will download them again when you open them.")
        }
    }

    // MARK: - 落到时间线

    /// 点 `+`：下载（已有就直接用），然后落在播放头上。
    ///
    /// **原样落下，不按工程总长裁短**（plan 第二节）——  一首三分钟的曲子拖进来
    /// 就是三分钟，要剪由用户自己剪。替他裁掉的话，他想用后半段就得先想明白
    /// 「为什么变短了」。
    private func add(_ item: AudioLibraryItem) {
        Task {
            do {
                let url = try await AudioLibraryCache.shared.download(item)
                project.addLibraryAudio(url: url, remoteKey: item.id, duration: item.duration)
            } catch {
                project.notice = error.localizedDescription
            }
        }
    }
}

// MARK: - 一行

private struct AudioLibraryRow: View {
    let item: AudioLibraryItem
    let isChinese: Bool
    let onAudition: () -> Void
    let onAdd: () -> Void

    @ObservedObject private var cache = AudioLibraryCache.shared
    @ObservedObject private var audition = AudioLibraryAudition.shared
    @State private var hovering = false

    private var isPlaying: Bool { audition.playingID == item.id }
    private var isDownloading: Bool { cache.isDownloading(item.id) }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            auditionButton
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.caption)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(MediaFormatting.duration(item.duration))
                        .monospacedDigit()
                    if cache.cachedIDs.contains(item.id) {
                        Image(systemName: "arrow.down.circle.fill")
                    }
                    Text(item.artist).lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                tagLine
            }
            Spacer(minLength: 0)
            if hovering || isDownloading { addButton }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(isPlaying ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.clear))
        .onHover { hovering = $0 }
        // **verbatim，不是 LocalizedStringKey**：署名句是 manifest 里的数据，
        // 不是界面文案 —— 拿它当 key 去查表永远查不到（只是碰巧原样显示），
        // 而且会让本地化守卫跑去解析所有叫 `text` 的属性（实测会误报到
        // EncodeSettingsView / FFmpegProcess 上）。
        .instantHelp(verbatim: item.license.text)
        .onDrag { AudioLibraryDrag.itemProvider(for: item) }
    }

    private var auditionButton: some View {
        Button(action: onAudition) {
            ZStack {
                Circle().fill(.quaternary).frame(width: 28, height: 28)
                if isPlaying && audition.isBuffering {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                        .font(.caption2)
                }
                if isPlaying && !audition.isBuffering {
                    Circle()
                        .trim(from: 0, to: audition.progress)
                        .stroke(.tint, lineWidth: 2)
                        .rotationEffect(.degrees(-90))
                        .frame(width: 28, height: 28)
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var tagLine: some View {
        let names = item.tags.prefix(3).map { $0.label(chinese: isChinese) }
        if !names.isEmpty {
            Text(names.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var addButton: some View {
        if isDownloading {
            ProgressView().controlSize(.mini)
        } else {
            Button(action: onAdd) {
                Image(systemName: "plus.circle.fill")
                    .font(.body)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
        }
    }
}
