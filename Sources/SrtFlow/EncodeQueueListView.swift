import SwiftUI
import SrtFlowCore

/// 队列列表，压缩窗口和烧字幕窗口共用。
struct EncodeQueueListView: View {
    @ObservedObject var queue: EncodeQueue
    var emptyPrompt: LocalizedStringKey
    var onAddFiles: () -> Void

    var body: some View {
        Group {
            if queue.items.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(queue.items) { item in
                        EncodeQueueRow(item: item, queue: queue)
                            .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack")
                .font(.system(size: 42))
                .foregroundStyle(.tertiary)
            Text(emptyPrompt)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Add Files…", action: onAddFiles)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}

private struct EncodeQueueRow: View {
    let item: EncodeItem
    @ObservedObject var queue: EncodeQueue
    // 这个视图在代码里拼字符串（L10n(...)），不是纯 LocalizedStringKey，
    // 光靠环境 locale 变化不会重新求值 body，所以要显式观察语言选择。
    @ObservedObject private var languageStore = AppLanguageStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                statusIcon
                Text(item.inputURL.lastPathComponent)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                trailingControls
            }

            Text(subtitleLine)
                .font(.caption)
                .foregroundStyle(.secondary)

            if item.status == .running {
                ProgressView(value: item.progress)
                    .progressViewStyle(.linear)
            }

            if let message = item.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private var statusIcon: some View {
        Group {
            switch item.status {
            case .waiting:
                Image(systemName: "clock").foregroundStyle(.secondary)
            case .probing:
                ProgressView().controlSize(.small)
            case .running:
                ProgressView().controlSize(.small)
            case .finished:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            case .cancelled:
                Image(systemName: "slash.circle").foregroundStyle(.secondary)
            }
        }
        .frame(width: 16)
    }

    /// 一行说明：源文件的规格 → 结果，跑的时候显示速度和剩余时间。
    private var subtitleLine: String {
        var parts: [String] = []

        if let info = item.info {
            parts.append(info.resolutionLabel)
            parts.append(MediaFormatting.duration(info.duration))
            parts.append(MediaFormatting.bytes(info.fileBytes))
        }

        switch item.status {
        case .running:
            var progress = MediaFormatting.percent(item.progress)
            if let speed = item.speed { progress += " · \(MediaFormatting.speed(speed))" }
            if let eta = item.etaSeconds { progress += " · \(MediaFormatting.eta(eta))" }
            parts.append(progress)
        case .finished:
            if let bytes = item.outputBytes {
                parts.append("→ \(MediaFormatting.bytes(bytes))")
            }
            if let saving = item.savingFraction {
                parts.append(MediaFormatting.saving(saving))
            }
        case .waiting:
            parts.append(L10n("Waiting"))
        case .cancelled:
            parts.append(L10n("Cancelled"))
        case .probing, .failed:
            break
        }

        return parts.joined(separator: " · ")
    }

    private var trailingControls: some View {
        HStack(spacing: 6) {
            if item.status == .finished {
                Button {
                    revealInFinder(item.outputURL)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
            }

            if item.isActive || item.status == .waiting {
                Button {
                    queue.cancel(id: item.id)
                } label: {
                    Image(systemName: "stop.circle")
                }
                .buttonStyle(.borderless)
                .help("Cancel")
            }

            if !item.isActive {
                Button {
                    queue.remove(id: item.id)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Remove from list")
            }
        }
    }
}

/// 输出位置选择，两个窗口共用。
struct OutputLocationPicker: View {
    @ObservedObject var queue: EncodeQueue
    // 这个视图在代码里拼字符串（L10n(...)），不是纯 LocalizedStringKey，
    // 光靠环境 locale 变化不会重新求值 body，所以要显式观察语言选择。
    @ObservedObject private var languageStore = AppLanguageStore.shared

    var body: some View {
        HStack(spacing: 8) {
            Text("Save to")
                .foregroundStyle(.secondary)
            Text(queue.outputDirectory?.lastPathComponent ?? L10n("Same folder as source"))
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Choose…") {
                if let directory = FilePicker.chooseDirectory() {
                    queue.outputDirectory = directory
                    queue.refreshOutputPaths()
                }
            }
            .controlSize(.small)
            if queue.outputDirectory != nil {
                Button("Reset") {
                    queue.outputDirectory = nil
                    queue.refreshOutputPaths()
                }
                .controlSize(.small)
            }
            Spacer()
        }
        .font(.callout)
    }
}
