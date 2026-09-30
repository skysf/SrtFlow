import SwiftUI

// 音频库面板里的一行：试听按钮、标题（音效有中文标题时按界面语言显示）、时长、艺人（音效没有）、标签、悬停出现的 +，
// 能拖到时间线上。从 AudioLibraryPanel 拆出来（2026-09-30 加音效库时面板顶到 400 行）。
// 不管什么：列表、筛选、下载（AudioLibraryPanel / AudioLibraryCache）。

// MARK: - 一行

struct AudioLibraryRow: View {
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
        let _ = PerfCounters.body(Self.self)
        HStack(alignment: .top, spacing: 8) {
            auditionButton
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title(chinese: isChinese))
                    .font(.caption)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(MediaFormatting.duration(item.duration))
                        .monospacedDigit()
                    if cache.cachedIDs.contains(item.id) {
                        Image(systemName: "arrow.down.circle.fill")
                    }
                    if !item.artist.isEmpty { Text(item.artist).lineLimit(1) }
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
