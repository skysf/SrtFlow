import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SrtFlowCore

enum MediaFormatting {

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB, .useKB]
        return formatter
    }()

    static func bytes(_ value: Int64) -> String {
        guard value > 0 else { return "—" }
        return byteFormatter.string(fromByteCount: value)
    }

    /// `95` → `1:35`，`3725` → `1:02:05`
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let total = Int(seconds.rounded())
        let s = total % 60
        let m = (total / 60) % 60
        let h = total / 3600
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// 剩余时间：短的说秒，长的说分。
    static func eta(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        if seconds < 60 {
            return String(format: L10n("%d s left"), Int(seconds.rounded()))
        }
        return String(format: L10n("%d min left"), Int((seconds / 60).rounded()))
    }

    static func speed(_ value: Double) -> String {
        String(format: "%.1f×", value)
    }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", fraction * 100)
    }

    /// 体积变化：正数是省下来的，负数说明反而变大了。
    static func saving(_ fraction: Double) -> String {
        if fraction >= 0 {
            return String(format: L10n("%.0f%% smaller"), fraction * 100)
        }
        return String(format: L10n("%.0f%% larger"), -fraction * 100)
    }
}

enum MediaFileTypes {
    /// 能拖进来当视频用的类型。
    static let video: [UTType] = [.movie, .video, .mpeg4Movie, .quickTimeMovie]

    static func isVideo(_ url: URL) -> Bool {
        // 先问系统的类型，认不出来（.mkv 之类）就退回看扩展名，
        // ffmpeg 吃得下的容器比 UTType 认得的多。
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            if video.contains(where: { type.conforms(to: $0) }) { return true }
        }
        return extraVideoExtensions.contains(url.pathExtension.lowercased())
    }

    private static let extraVideoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "webm", "avi", "wmv", "flv", "ts", "mts", "m2ts", "mpg", "mpeg", "3gp", "ogv"
    ]

    static func isSubtitle(_ url: URL) -> Bool {
        SubtitleFormat.detect(from: url.lastPathComponent) != nil
    }

    /// 能放上时间线的静态图片（编辑器里会先转成静帧视频段）。
    static func isImage(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "heic", "heif", "webp", "bmp", "tif", "tiff", "gif"]
            .contains(url.pathExtension.lowercased())
    }
}

extension SubtitleColor {
    var swiftUIColor: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }

    init(_ color: Color) {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(
            red: Double(resolved.redComponent),
            green: Double(resolved.greenComponent),
            blue: Double(resolved.blueComponent),
            opacity: Double(resolved.alphaComponent)
        )
    }
}

extension View {
    /// 整块区域接受文件拖放，按类型分流。
    func onDropOfFiles(perform action: @escaping ([URL]) -> Void) -> some View {
        onDrop(of: [.fileURL], isTargeted: nil) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    guard let url = await provider.loadFileURL() else { continue }
                    urls.append(url)
                }
                if !urls.isEmpty { action(urls) }
            }
            return true
        }
    }
}

extension NSItemProvider {
    /// 把 NSItemProvider 的回调式接口包成 async。
    ///
    /// 先走 `loadObject(URL.self)`；个别拖放源（某些图片、浏览器下载条目）
    /// 只注册了 file-url 的原始数据表示，那就退回去手工解。
    func loadFileURL() async -> URL? {
        if canLoadObject(ofClass: URL.self) {
            let url: URL? = await withCheckedContinuation { continuation in
                _ = loadObject(ofClass: URL.self) { url, _ in
                    continuation.resume(returning: url)
                }
            }
            if let url { return url }
        }
        guard hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return nil }
        return await withCheckedContinuation { continuation in
            loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let path = item as? String {
                    continuation.resume(returning: URL(fileURLWithPath: path))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

/// 在 Finder 里选中某个文件。
func revealInFinder(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
}

/// 选文件的面板，包一层省得到处写。
enum FilePicker {
    static func chooseFiles(types: [UTType], allowsMultiple: Bool = true) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = allowsMultiple
        panel.canChooseDirectories = false
        // 系统认不出的容器（.mkv 等）也得能选。
        panel.allowsOtherFileTypes = true
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func chooseDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
