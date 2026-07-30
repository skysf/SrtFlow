import SwiftUI
import SrtFlowCore

/// 批量转换的状态。
///
/// 和两个编码队列同理：主窗口靠侧边栏切栏目，切走这一栏视图就没了。排好的
/// 文件列表和转换结果放在这里，切回来还在。
@MainActor
final class BatchConvertModel: ObservableObject {
    static let shared = BatchConvertModel()

    @Published var files: [URL] = []
    @Published var target: SubtitleFormat = .srt
    @Published var outputDirectory: URL?
    @Published var statuses: [URL: String] = [:]

    private init() {}

    func add(_ url: URL) {
        guard !files.contains(url) else { return }
        files.append(url)
        statuses[url] = nil
    }

    func remove(atOffsets offsets: IndexSet) {
        for url in offsets.map({ files[$0] }) { statuses[url] = nil }
        files.remove(atOffsets: offsets)
    }

    func clear() {
        files.removeAll()
        statuses.removeAll()
    }

    func convert() {
        for url in files {
            do {
                let out = try SubtitleConverter.convertFile(at: url, to: target, outputDirectory: outputDirectory)
                statuses[url] = "✓ \(out.lastPathComponent)"
            } catch {
                statuses[url] = "✗ \(error.localizedDescription)"
            }
        }
    }
}

struct BatchConvertView: View {
    @ObservedObject private var model = BatchConvertModel.shared

    var body: some View {
        VStack(spacing: 12) {
            fileList

            HStack {
                Button("Add Files…", action: addFiles)
                Button("Clear") { model.clear() }
                    .disabled(model.files.isEmpty)
                Spacer()
            }

            HStack {
                Picker("Target Format", selection: $model.target) {
                    ForEach(SubtitleFormat.allCases, id: \.self) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .fixedSize()

                Button("Output Folder…", action: chooseOutputFolder)
                Text(model.outputDirectory?.lastPathComponent ?? String(localized: "Same as source"))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }

            HStack {
                Spacer()
                Button("Convert") { model.convert() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.files.isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 360)
    }

    private var fileList: some View {
        List {
            if model.files.isEmpty {
                Text("Drop subtitle files here, or click Add Files…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 40)
            } else {
                ForEach(model.files, id: \.self) { url in
                    HStack {
                        Image(systemName: "doc.text")
                        Text(url.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if let status = model.statuses[url] {
                            Text(status)
                                .foregroundStyle(status.hasPrefix("✓") ? .green : .red)
                                .font(.callout)
                        } else if let format = SubtitleFormat.detect(from: url.lastPathComponent) {
                            Text(format.displayName)
                                .foregroundStyle(.secondary)
                                .font(.callout)
                        }
                    }
                }
                .onDelete { model.remove(atOffsets: $0) }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, SubtitleFormat.detect(from: url.lastPathComponent) != nil else { return }
                    DispatchQueue.main.async { model.add(url) }
                }
            }
            return true
        }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SubtitleDocument.readableContentTypes
        panel.allowsMultipleSelection = true
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls { model.add(url) }
        }
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            model.outputDirectory = url
        }
    }
}
