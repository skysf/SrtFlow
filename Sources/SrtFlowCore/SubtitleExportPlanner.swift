import Foundation

// 字幕导出规划（docs/plans/2026-08-06-native-subtitle-generation.md 第 13 节）：
// 命名、同名冲突、双语合成、「临时名 → 回读校验 → 原子替换」。
// 任何失败不删不动用户已有文件（transform-review / export-prerender 教训）。

/// 预览与导出共用的轨道选择。
public enum SubtitleTrackChoice: String, CaseIterable, Sendable {
    case original
    case translation
    case bilingual
}

public enum SubtitleExportPlanner {

    public struct WriteError: LocalizedError {
        public var message: String
        public var errorDescription: String? { message }
    }

    // MARK: 文档合成

    /// 按轨道选择取要输出的文档。译文轨缺条时双语行只有原文（不编造）。
    public static func document(
        for choice: SubtitleTrackChoice,
        original: SubtitleDocumentModel,
        translation: SubtitleDocumentModel?
    ) -> SubtitleDocumentModel? {
        switch choice {
        case .original:
            return original
        case .translation:
            return translation
        case .bilingual:
            return bilingualDocument(original: original, translation: translation)
        }
    }

    /// 双语 V1 样式合同（计划 13）：原文在上、译文在下，两行同一个样式；
    /// 只在导出时临时合成，不回写存储模型。
    public static func bilingualDocument(
        original: SubtitleDocumentModel, translation: SubtitleDocumentModel?
    ) -> SubtitleDocumentModel {
        let translated: [UUID: String] = Dictionary(
            uniqueKeysWithValues: (translation?.cues ?? []).map { ($0.id, $0.text) }
        )
        var document = original
        for i in document.cues.indices {
            let id = document.cues[i].id
            if let line = translated[id], !line.isEmpty {
                document.cues[i].text += "\n" + line
            }
        }
        document.reindex()
        return document
    }

    // MARK: 命名（计划 13）

    /// `<视频名>.<lang>.srt`；双语 `<视频名>.<src>-<dst>.srt`；缺语言标签就省略。
    public static func fileName(
        base: String,
        choice: SubtitleTrackChoice,
        sourceLanguage: String?,
        targetLanguage: String?,
        format: SubtitleFormat
    ) -> String {
        let tag: String?
        switch choice {
        case .original: tag = sourceLanguage
        case .translation: tag = targetLanguage
        case .bilingual:
            if let s = sourceLanguage, let t = targetLanguage { tag = "\(s)-\(t)" }
            else { tag = sourceLanguage ?? targetLanguage }
        }
        let stem = tag.map { "\(base).\($0)" } ?? base
        return "\(stem).\(format.rawValue)"
    }

    /// 同目录冲突追加 -2/-3……（不覆盖任何已有文件）。
    public static func availableURL(directory: URL, fileName: String) -> URL {
        let manager = FileManager.default
        let first = directory.appendingPathComponent(fileName)
        guard manager.fileExists(atPath: first.path) else { return first }
        let ext = (fileName as NSString).pathExtension
        let stem = (fileName as NSString).deletingPathExtension
        for n in 2...999 {
            let candidate = directory.appendingPathComponent("\(stem)-\(n).\(ext)")
            if !manager.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("\(stem)-\(UUID().uuidString).\(ext)")
    }

    // MARK: 写盘（临时名 → 回读校验 → 原子替换）

    /// 序列化 → 写同目录临时名 → 回读能解析且 cue 数一致 → 原子挪到目标。
    /// 任何一步失败都只清理临时文件，绝不碰目标位置的已有文件。
    @discardableResult
    public static func writeValidated(
        _ document: SubtitleDocumentModel, format: SubtitleFormat, to url: URL
    ) throws -> URL {
        let manager = FileManager.default
        var output = document
        output.format = format
        output.reindex()
        let content = SubtitleSerializer.serialize(output, format: format)

        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).partial-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: temp) }

        try Data(content.utf8).write(to: temp, options: .atomic)
        let readBack = try String(contentsOf: temp, encoding: .utf8)
        let parsed = SubtitleParser.parse(readBack, format: format, filename: url.lastPathComponent)
        let expected = output.cues.filter { !$0.text.isEmpty }.count
        guard parsed.cues.count == expected else {
            throw WriteError(
                message: "Subtitle file verification failed for “\(url.lastPathComponent)”."
            )
        }

        if manager.fileExists(atPath: url.path) {
            _ = try manager.replaceItemAt(url, withItemAt: temp)
        } else {
            try manager.moveItem(at: temp, to: url)
        }
        return url
    }
}
