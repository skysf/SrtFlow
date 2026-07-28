import SwiftUI
import SrtFlowCore

struct BatchConvertView: View {
    @State private var files: [URL] = []
    @State private var target: SubtitleFormat = .srt
    @State private var outputDirectory: URL?
    @State private var statuses: [URL: String] = [:]

    var body: some View {
        VStack(spacing: 12) {
            fileList

            HStack {
                Button("Add Files…", action: addFiles)
                Button("Clear") {
                    files.removeAll()
                    statuses.removeAll()
                }
                .disabled(files.isEmpty)
                Spacer()
            }

            HStack {
                Picker("Target Format", selection: $target) {
                    ForEach(SubtitleFormat.allCases, id: \.self) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .fixedSize()

                Button("Output Folder…", action: chooseOutputFolder)
                Text(outputDirectory?.lastPathComponent ?? String(localized: "Same as source"))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }

            HStack {
                Spacer()
                Button("Convert", action: convert)
                    .keyboardShortcut(.defaultAction)
                    .disabled(files.isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 360)
    }

    private var fileList: some View {
        List {
            if files.isEmpty {
                Text("Drop subtitle files here, or click Add Files…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 40)
            } else {
                ForEach(files, id: \.self) { url in
                    HStack {
                        Image(systemName: "doc.text")
                        Text(url.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if let status = statuses[url] {
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
                .onDelete { offsets in
                    for url in offsets.map({ files[$0] }) { statuses[url] = nil }
                    files.remove(atOffsets: offsets)
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, SubtitleFormat.detect(from: url.lastPathComponent) != nil else { return }
                    DispatchQueue.main.async { addFile(url) }
                }
            }
            return true
        }
    }

    private func addFile(_ url: URL) {
        guard !files.contains(url) else { return }
        files.append(url)
        statuses[url] = nil
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SubtitleDocument.readableContentTypes
        panel.allowsMultipleSelection = true
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls { addFile(url) }
        }
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            outputDirectory = url
        }
    }

    private func convert() {
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
