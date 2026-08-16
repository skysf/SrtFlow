import AppKit
import SwiftUI
import SrtFlowCore

/// 没配到视频、单独打开的字幕文件。
///
/// 独立的字幕编辑窗口没有了，双击 .srt 打开的文件落到这里，在烧录页的字幕列里
/// 编辑。放全局是因为切到别的栏目再回来，改了一半的东西必须还在。
@MainActor
final class StandaloneSubtitleStore: ObservableObject {
    static let shared = StandaloneSubtitleStore()

    @Published var url: URL?
    @Published var document: SubtitleDocumentModel?
    @Published var hasUnsavedEdits = false
    /// 一句需要用户看见的说明：打开失败、或者被未保存的改动挡住了。
    @Published var notice: String?

    private init() {}

    func open(_ fileURL: URL) {
        // 手里这份还没保存就别悄悄换掉，那等于把用户的编辑扔了。
        if hasUnsavedEdits, url != fileURL {
            notice = String(
                format: L10n("Save or close %@ before opening another subtitle file."),
                url?.lastPathComponent ?? "?"
            )
            return
        }
        do {
            document = try SubtitleLoader.load(fileURL)
            url = fileURL
            hasUnsavedEdits = false
            notice = nil
        } catch {
            notice = error.localizedDescription
        }
    }

    func clear() {
        url = nil
        document = nil
        hasUnsavedEdits = false
        notice = nil
    }
}

/// 烧录页预览旁边的字幕列：整份字幕可见、可编辑，播放到哪句就滚到哪句。
///
/// 编辑目标二选一：预览条目自己的字幕（改动立即用于叠层预览和烧录），或者
/// 单独打开的字幕文件（`StandaloneSubtitleStore`）。两条路都能存回原文件。
struct SubtitleEditPanel: View {
    @ObservedObject var queue: EncodeQueue
    @ObservedObject var standalone: StandaloneSubtitleStore
    /// 预览条目（配好字幕的那个）。有它就编辑它的字幕，没有才轮到独立文件。
    let itemID: EncodeItem.ID?
    @ObservedObject var clock: PlayerClock
    @ObservedObject var renderer: BurnInPreviewRenderer
    let previewMode: BurnInPreviewMode
    /// 面板空着时「打开字幕」按钮的动作，由烧录页决定怎么接（配给视频还是独立打开）。
    var onOpenSubtitle: () -> Void = {}

    @State private var selection = Set<UUID>()
    @State private var followsPlayback = true
    @State private var saveError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if document == nil {
                emptyState
            } else {
                cueTable
            }
        }
        .alert("Could Not Save", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    // MARK: - 编辑目标

    private var boundItem: EncodeItem? {
        guard let itemID else { return nil }
        return queue.items.first { $0.id == itemID }
    }

    private var document: SubtitleDocumentModel? {
        boundItem?.burnIn?.document ?? standalone.document
    }

    private var subtitleURL: URL? {
        boundItem != nil ? boundItem?.burnIn?.subtitleURL : standalone.url
    }

    private var hasUnsavedEdits: Bool {
        boundItem != nil
            ? (boundItem?.burnIn?.hasUnsavedEdits ?? false)
            : standalone.hasUnsavedEdits
    }

    /// 正在编辑的是没配视频的独立字幕文件。
    private var isStandalone: Bool {
        boundItem == nil && standalone.document != nil
    }

    private var cues: [SubtitleCue] { document?.cues ?? [] }

    private func mutate(_ change: @escaping (inout SubtitleDocumentModel) -> Void) {
        if let id = boundItem?.id {
            queue.editBurnInDocument(for: id, change)
        } else if var doc = standalone.document {
            change(&doc)
            standalone.document = doc
            standalone.hasUnsavedEdits = true
        }
    }

    // MARK: - 顶部

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "captions.bubble")
                    .foregroundStyle(.secondary)
                Text(subtitleURL?.lastPathComponent ?? L10n("Subtitles"))
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if hasUnsavedEdits {
                    Circle()
                        .fill(.orange)
                        .frame(width: 7, height: 7)
                        .instantHelp("Unsaved changes")
                }
                Spacer(minLength: 6)
                if !cues.isEmpty {
                    Text(String(format: L10n("%d lines"), cues.count))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if isStandalone {
                    Button {
                        if standalone.hasUnsavedEdits {
                            standalone.notice = L10n("Save the changes first, or export a copy.")
                        } else {
                            standalone.clear()
                        }
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .instantHelp("Close this subtitle file")
                }
            }

            if document != nil {
                HStack(spacing: 8) {
                    Button { addCue() } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .instantHelp("Add a line below the selection")
                    Button { removeSelected() } label: { Image(systemName: "minus") }
                        .buttonStyle(.borderless)
                        .disabled(selection.isEmpty)
                        .instantHelp("Delete the selected lines")

                    Toggle(isOn: $followsPlayback) {
                        Image(systemName: "text.line.last.and.arrowtriangle.forward")
                    }
                    .toggleStyle(.button)
                    .buttonStyle(.borderless)
                    .instantHelp("Scroll to the line being spoken during playback")

                    Spacer()

                    Menu("Export As") {
                        ForEach(SubtitleFormat.allCases, id: \.self) { format in
                            Button(format.displayName) { exportAs(format) }
                        }
                    }
                    .fixedSize()
                    .controlSize(.small)

                    Button("Save") { save() }
                        .controlSize(.small)
                        .disabled(!hasUnsavedEdits)
                        .instantHelp("Write the changes back to the subtitle file", shortcut: .command("S"))
                }
            }

            if isStandalone {
                Text("Editing the subtitle file on its own. Add a video to see it on the picture.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notice = standalone.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "captions.bubble")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("The subtitle lines show up here, in step with playback.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Subtitle File…", action: onOpenSubtitle)
                .instantHelp("Open an .srt or .vtt file to edit")
                .controlSize(.small)
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
    }

    // MARK: - 字幕表

    /// 播放头此刻落在哪句上。重叠时取后一句，跟画面叠层的取法一致。
    private var currentCueID: UUID? {
        guard boundItem != nil, previewMode == .playback else { return nil }
        let time = clock.time
        return cues.last { $0.start <= time && time < $0.end }?.id
    }

    private var cueTable: some View {
        ScrollViewReader { proxy in
            Table(cues, selection: $selection) {
                TableColumn(Text("#")) { cue in
                    Text("\(cue.index)")
                        .frame(width: 30, alignment: .trailing)
                        .modifier(CurrentCueHighlight(isCurrent: cue.id == currentCueID))
                }
                .width(30)
                TableColumn(Text("Start")) { cue in
                    TimecodeField(value: binding(for: cue.id, \.start, default: 0))
                }
                .width(96)
                TableColumn(Text("End")) { cue in
                    TimecodeField(value: binding(for: cue.id, \.end, default: 0))
                }
                .width(96)
                TableColumn(Text("Text")) { cue in
                    TextField("", text: binding(for: cue.id, \.text, default: ""), axis: .vertical)
                        .lineLimit(1...3)
                        .modifier(CurrentCueHighlight(isCurrent: cue.id == currentCueID))
                }
            }
            .onChange(of: currentCueID) { _, newID in
                guard followsPlayback, clock.isPlaying, let newID else { return }
                withAnimation { proxy.scrollTo(newID, anchor: .center) }
            }
            .onChange(of: selection) { _, newSelection in
                // 点某一行，画面就跳到那句：核对一句字幕最快的方式就是看它。
                guard newSelection.count == 1,
                      let id = newSelection.first,
                      let index = cues.firstIndex(where: { $0.id == id }) else { return }
                if renderer.cueIndex != index {
                    renderer.cueIndex = index
                }
            }
            .onDeleteCommand(perform: removeSelected)
        }
    }

    /// 删除行后的过渡帧里，SwiftUI 仍可能对已消失的 cue 求值绑定，
    /// 此时返回 defaultValue 即可，绝不能崩。
    private func binding<T>(
        for id: UUID,
        _ keyPath: WritableKeyPath<SubtitleCue, T>,
        default defaultValue: T
    ) -> Binding<T> {
        Binding(
            get: {
                guard let cues = document?.cues,
                      let index = cues.firstIndex(where: { $0.id == id }) else { return defaultValue }
                return cues[index][keyPath: keyPath]
            },
            set: { newValue in
                mutate { doc in
                    guard let index = doc.cues.firstIndex(where: { $0.id == id }) else { return }
                    doc.cues[index][keyPath: keyPath] = newValue
                }
            }
        )
    }

    // MARK: - 动作

    private func addCue() {
        let afterIndex = selection
            .compactMap { id in cues.firstIndex(where: { $0.id == id }) }
            .max()
        mutate { $0.addCue(after: afterIndex) }
        // 选中刚插进来的那行，直接就能打字。
        let updated = document?.cues ?? []
        guard !updated.isEmpty else { return }
        let insertedIndex = afterIndex.map { min($0 + 1, updated.count - 1) } ?? (updated.count - 1)
        selection = [updated[insertedIndex].id]
    }

    private func removeSelected() {
        guard !selection.isEmpty else { return }
        let ids = selection
        mutate { $0.removeCues(ids: ids) }
        selection.removeAll()
    }

    private func save() {
        guard let document else { return }
        guard let url = subtitleURL else {
            exportAs(document.format)
            return
        }
        do {
            try write(document, format: document.format, to: url)
            markSaved()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func exportAs(_ format: SubtitleFormat) {
        guard let document else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.utType]
        let base = subtitleURL?.deletingPathExtension().lastPathComponent ?? document.title
        panel.nameFieldStringValue = "\(base).\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try write(document, format: format, to: url)
            // 导出成同一个文件（等于就是保存），未保存标记也该消掉。
            if url == subtitleURL, format == document.format { markSaved() }
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func write(_ document: SubtitleDocumentModel, format: SubtitleFormat, to url: URL) throws {
        var copy = document
        copy.reindex()
        let content = SubtitleSerializer.serialize(copy, format: format)
        try Data(content.utf8).write(to: url)
    }

    private func markSaved() {
        if let id = boundItem?.id {
            queue.markBurnInSaved(for: id)
        } else {
            standalone.hasUnsavedEdits = false
        }
    }
}

/// 播放头正落在的那句加个重音。
struct CurrentCueHighlight: ViewModifier {
    let isCurrent: Bool
    func body(content: Content) -> some View {
        content
            .fontWeight(isCurrent ? .semibold : .regular)
            .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
    }
}

/// 可编辑的时间码格子：回车或失焦时提交，输入不合法就回退。
struct TimecodeField: View {
    @Binding var value: TimeInterval
    @State private var text: String
    @FocusState private var focused: Bool

    init(value: Binding<TimeInterval>) {
        _value = value
        _text = State(initialValue: Timecode.formatMillis(value.wrappedValue, separator: ","))
    }

    var body: some View {
        TextField("", text: $text)
            .focused($focused)
            .onSubmit { commit() }
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .onChange(of: value) { _, newValue in
                guard !focused else { return }
                text = Timecode.formatMillis(newValue, separator: ",")
            }
            .monospacedDigit()
    }

    private func commit() {
        guard let parsed = Timecode.parse(text) else {
            text = Timecode.formatMillis(value, separator: ",")
            return
        }
        value = parsed
        // **回读，别显示 parsed。** 绑定有权拒绝（字幕表那边就拒绝 start >= end），
        // 显示 parsed 会让格子里挂着一个根本没生效的时间：界面说 4 秒、
        // 存盘和导出还是 1 秒，用户毫不知情（2026-08-12 复审 P2）。
        text = Timecode.formatMillis(value, separator: ",")
    }
}
