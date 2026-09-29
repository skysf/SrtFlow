import Foundation

// MARK: - open_folder：文件夹里有什么
//
// 管什么：把用户点名的文件夹（每一层子文件夹都算）里能用的文件列出来，分成视频 / 图片 /
// 音频 / 字幕 / 工程 / 文稿，按相对路径排好。只看文件名和大小，不读内容 —— 时长和尺寸由
// 调用方再去探（`AIProjectTools.openFolder`，探测结果有缓存）。
// 不管什么：哪些文件能读不用问（AIWorkspace）。
//
// 跳过的：隐藏文件、App 包之类的「包」内部、以及文件夹根上的 `SrtFlow/` —— 那是 SrtFlow
// 自己放导出和工程的地方，列进来 AI 会把上一次导出的成片当素材再剪一遍。

@MainActor
enum AIMediaScan {
    enum Kind: String, CaseIterable {
        case video, image, audio, subtitle, project, document
    }

    struct Entry {
        var url: URL
        var kind: Kind
        var bytes: Int
    }

    struct Result {
        var entries: [Entry]
        /// 超过上限没列完。
        var truncated: Bool
        /// 根上有 SrtFlow 自己的输出文件夹（没列进来）。
        var hasOutputFolder: Bool
    }

    static let documentExtensions: Set<String> = ["pdf", "doc", "docx", "odt", "txt", "md", "markdown", "rtf", "pages"]

    static func kind(of url: URL) -> Kind? {
        let ext = url.pathExtension.lowercased()
        if ext == VideoEditProjectFile.fileExtension { return .project }
        // .txt 字幕能认，但文件夹里的 .txt 多半是讲稿、笔记：列成文稿（read_document 读），当字幕用照样 add_clips。
        if ext == "txt" { return .document }
        if MediaFileTypes.isSubtitle(url) { return .subtitle }
        if MediaFileTypes.isVideo(url) { return .video }
        if MediaFileTypes.isImage(url) { return .image }
        if VideoEditProject.looksLikeAudio(url) { return .audio }
        if documentExtensions.contains(ext) { return .document }
        return nil
    }

    static func scan(_ folder: URL, maxFiles: Int) -> Result {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return Result(entries: [], truncated: false, hasOutputFolder: false) }
        let outputRoot = folder.appendingPathComponent("SrtFlow").standardizedFileURL.path
        var entries: [Entry] = []
        var truncated = false
        var hasOutput = false
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if url.standardizedFileURL.path == outputRoot {
                    hasOutput = true
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true, let kind = kind(of: url) else { continue }
            guard entries.count < maxFiles else {
                truncated = true
                break
            }
            entries.append(Entry(url: url.standardizedFileURL, kind: kind, bytes: values?.fileSize ?? 0))
        }
        let root = folder.standardizedFileURL.path + "/"
        entries.sort {
            $0.url.path.replacingOccurrences(of: root, with: "")
                .localizedStandardCompare($1.url.path.replacingOccurrences(of: root, with: "")) == .orderedAscending
        }
        return Result(entries: entries, truncated: truncated, hasOutputFolder: hasOutput)
    }
}
