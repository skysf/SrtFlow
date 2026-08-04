import AppKit
import SwiftUI

/// 工具栏左边那个工程名下拉。
///
/// 它就是这个编辑器的「文件菜单」：新建、打开、最近、存一版、在访达里显示。
/// 名字旁边的小圆点表示还没落盘 —— 自动保存开着，它一般只闪一下就没了。
struct VideoEditProjectMenu: View {
    @ObservedObject var project: VideoEditProject
    @ObservedObject private var languageStore = AppLanguageStore.shared

    /// 每次打开菜单现查一次最近列表：别的地方存过工程，这里要能看见。
    @State private var recents: [URL] = []

    var body: some View {
        Menu {
            Button("New Project") { project.newProject() }
            Button("Open Project…") { project.promptOpenProject() }

            Menu("Open Recent") {
                if recents.isEmpty {
                    Text("No Recent Projects").foregroundStyle(.secondary)
                } else {
                    ForEach(recents, id: \.self) { url in
                        Button(url.deletingPathExtension().lastPathComponent) {
                            Task { await project.openProject(at: url) }
                        }
                    }
                }
            }

            Divider()

            Button("Save") { project.saveDocument() }
            Button("Save As…") { project.saveDocumentAs() }

            Divider()

            Button("Show in Finder") { project.revealInFinder() }
                .disabled(project.isUntitled)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "film.stack")
                Text(project.projectName).lineLimit(1)
                if project.hasUnsavedChanges {
                    // 没落盘的小圆点。存过之后自动保存两秒内就会把它熄掉。
                    Circle()
                        .fill(.secondary)
                        .frame(width: 5, height: 5)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .onAppear { recents = RecentProjects.existing() }
        // 打开/保存都会动最近列表，跟着刷新。
        .onChange(of: project.documentURL) { _, _ in recents = RecentProjects.existing() }
        .help(project.documentURL?.path ?? L10n("This project hasn’t been saved yet"))
    }
}

// MARK: - 起始页

/// 空工程时预览区显示的东西：拖放提示 + 最近工程。
///
/// 这里刻意**不做** App 内的文件夹管理 —— 工程就是普通文件，分文件夹、改名、
/// 搜索都交给访达。这一屏只负责「快速回到最近那几条」。
struct VideoEditStartScreen: View {
    @ObservedObject var project: VideoEditProject
    @ObservedObject private var languageStore = AppLanguageStore.shared

    @State private var recents: [URL] = []

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header

                if !recents.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Recent Projects")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                        }
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(recents, id: \.self) { url in
                                RecentProjectCard(url: url) {
                                    Task { await project.openProject(at: url) }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: 720)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .onAppear { recents = RecentProjects.existing() }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "film.stack")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("Drop video, audio, images, or subtitles here to start editing.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button("Add Media…") { promptAddMedia() }
                    .buttonStyle(.borderedProminent)
                Button("Open Project…") { project.promptOpenProject() }
            }
        }
        .padding(.top, 12)
    }

    private func promptAddMedia() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = L10n("Add")
        guard panel.runModal() == .OK else { return }
        project.addMedia(urls: panel.urls)
    }
}

/// 最近工程的一张卡片。名字 + 上次改动时间 + 它在哪个文件夹里。
private struct RecentProjectCard: View {
    let url: URL
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: "film.stack")
                    .font(.title3)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.deletingPathExtension().lastPathComponent)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(url.path)
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    private var subtitle: String {
        let folder = url.deletingLastPathComponent().lastPathComponent
        guard let date = RecentProjects.modifiedAt(url) else { return folder }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return "\(formatter.string(from: date)) · \(folder)"
    }
}

// MARK: - 丢失的素材

/// 打开工程时没找回来的素材：原路径没了、书签解不开、相对位置和同名搜索也没中。
/// 到这一步只能让用户指认，指完同目录的其他丢失素材会自动配上。
struct MissingMediaBar: View {
    @ObservedObject var project: VideoEditProject
    @ObservedObject private var languageStore = AppLanguageStore.shared

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(summary)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Menu("Relink…") {
                ForEach(project.missingMedia, id: \.self) { url in
                    Button(url.lastPathComponent) { project.promptRelink(url) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.12))
    }

    private var summary: String {
        if project.missingMedia.count == 1, let first = project.missingMedia.first {
            return String(format: L10n("“%@” could not be found."), first.lastPathComponent)
        }
        return String(
            format: L10n("%d media files could not be found."),
            project.missingMedia.count
        )
    }
}
