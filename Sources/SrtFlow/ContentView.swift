import SwiftUI
import SrtFlowCore

struct ContentView: View {
    @ObservedObject var document: SubtitleDocument

    @StateObject private var clock = PlayerClock()
    @State private var selection = Set<UUID>()
    @State private var showVideo = false
    @State private var exportError: String?

    private var cues: [SubtitleCue] { document.model.cues }

    private var currentCueID: UUID? {
        guard showVideo else { return nil }
        return document.model.cue(at: clock.time)?.id
    }

    var body: some View {
        HSplitView {
            cueTable
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            if showVideo {
                VideoPreviewView(clock: clock, currentCue: document.model.cue(at: clock.time))
                    .frame(minWidth: 320, idealWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar { toolbarContent }
        .onDeleteCommand(perform: removeSelected)
        .alert("Export Failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    // MARK: - Table

    private var cueTable: some View {
        ScrollViewReader { proxy in
            Table(cues, selection: $selection) {
                TableColumn(Text("#")) { cue in
                    Text("\(cue.index)")
                        .frame(width: 36, alignment: .trailing)
                        .modifier(CurrentCueHighlight(isCurrent: cue.id == currentCueID))
                }
                .width(36)
                TableColumn(Text("Start")) { cue in
                    TimecodeField(value: binding(for: cue.id, \.start, default: 0))
                }
                .width(110)
                TableColumn(Text("End")) { cue in
                    TimecodeField(value: binding(for: cue.id, \.end, default: 0))
                }
                .width(110)
                TableColumn(Text("Style")) { cue in
                    TextField("", text: binding(for: cue.id, \.styleName, default: ""))
                }
                .width(min: 60, ideal: 90, max: 140)
                TableColumn(Text("Text")) { cue in
                    TextField("", text: binding(for: cue.id, \.text, default: ""), axis: .vertical)
                        .lineLimit(1...3)
                        .modifier(CurrentCueHighlight(isCurrent: cue.id == currentCueID))
                }
            }
            .onChange(of: currentCueID) { _, newID in
                if let newID {
                    withAnimation { proxy.scrollTo(newID, anchor: .center) }
                }
            }
        }
    }

    /// 删除行后的过渡帧里，SwiftUI 仍可能对已消失的 cue 求值绑定，
    /// 此时返回 defaultValue 即可，绝不能 fatalError。
    private func binding<T>(for id: UUID, _ keyPath: WritableKeyPath<SubtitleCue, T>, default defaultValue: T) -> Binding<T> {
        Binding(
            get: {
                guard let index = document.model.cues.firstIndex(where: { $0.id == id }) else {
                    return defaultValue
                }
                return document.model.cues[index][keyPath: keyPath]
            },
            set: { newValue in
                guard let index = document.model.cues.firstIndex(where: { $0.id == id }) else { return }
                document.model.cues[index][keyPath: keyPath] = newValue
            }
        )
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button(action: addCue) {
                Label("Add Cue", systemImage: "plus")
            }
            .help("Add Cue")

            Button(action: removeSelected) {
                Label("Delete", systemImage: "minus")
            }
            .disabled(selection.isEmpty)
            .help("Delete")
        }
        ToolbarItemGroup {
            Menu("Export As") {
                ForEach(SubtitleFormat.allCases, id: \.self) { format in
                    Button(format.displayName) { export(as: format) }
                }
            }

            Menu("Link Video") {
                Button("Choose File…") { chooseVideo() }
                let recents = Self.recentVideoURLs
                if !recents.isEmpty {
                    Divider()
                    ForEach(recents, id: \.self) { url in
                        Button(url.deletingPathExtension().lastPathComponent) { linkVideo(url) }
                    }
                }
                if clock.hasVideo {
                    Divider()
                    Button("Remove Video") { unlinkVideo() }
                }
            }
        }
    }

    // MARK: - Actions

    private func addCue() {
        let afterIndex = selection.compactMap { id in cues.firstIndex(where: { $0.id == id }) }.max()
        document.model.addCue(after: afterIndex)
        if let inserted = afterIndex.flatMap({ $0 + 1 < cues.count ? cues[$0 + 1].id : nil }) ?? cues.last?.id {
            selection = [inserted]
        }
    }

    private func removeSelected() {
        guard !selection.isEmpty else { return }
        document.model.removeCues(ids: selection)
        selection.removeAll()
    }

    private func export(as format: SubtitleFormat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.utType]
        panel.nameFieldStringValue = "\(document.model.title).\(format.fileExtension)"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let content = SubtitleSerializer.serialize(document.model, format: format)
            do {
                try Data(content.utf8).write(to: url)
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    // MARK: - Video linking

    private static let recentVideosKey = "recentVideoPaths"

    static var recentVideoURLs: [URL] {
        (UserDefaults.standard.stringArray(forKey: recentVideosKey) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func chooseVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video]
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            linkVideo(url)
        }
    }

    private func linkVideo(_ url: URL) {
        clock.attach(url: url)
        showVideo = true
        var paths = UserDefaults.standard.stringArray(forKey: Self.recentVideosKey) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(5)), forKey: Self.recentVideosKey)
    }

    private func unlinkVideo() {
        clock.detach()
        showVideo = false
    }
}

/// Highlights the cue currently under the playhead.
private struct CurrentCueHighlight: ViewModifier {
    let isCurrent: Bool
    func body(content: Content) -> some View {
        content
            .fontWeight(isCurrent ? .semibold : .regular)
            .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
    }
}

/// Editable timecode cell: commits on Return, reverts on invalid input.
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
        if let parsed = Timecode.parse(text) {
            value = parsed
            text = Timecode.formatMillis(parsed, separator: ",")
        } else {
            text = Timecode.formatMillis(value, separator: ",")
        }
    }
}
