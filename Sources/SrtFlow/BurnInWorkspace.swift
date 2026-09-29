import Foundation
import SrtFlowCore

/// 为一次烧字幕（或一次预览）准备好临时工作目录。
///
/// 目录里放两样东西：`subtitle.ass` 和 `fonts/`（里面软链着选中的字体文件）。
/// ffmpeg 进程的工作目录会设成这里，滤镜里只写 `subtitles=filename=subtitle.ass`
/// 这种相对名 —— 绕开了 ffmpeg 滤镜图里那套要给 `:` `'` `\` `[` `]` `,` 层层
/// 转义的规则，路径里有空格或冒号也不会出问题。
enum BurnInWorkspace {

    struct Prepared {
        var directory: URL
        var paths: FFmpegCommand.BurnIn
    }

    static func create(
        cues: [SubtitleCue],
        style: BurnInStyle,
        fontFileURL: URL?,
        aspectRatio: Double,
        title: String,
        layout: SubtitleLayout? = nil
    ) throws -> Prepared {
        try create(
            blocks: [SubtitleRenderBlock(cues: cues, layout: layout)], style: style,
            fontFileURL: fontFileURL, aspectRatio: aspectRatio, title: title
        )
    }

    /// 几块字幕各用各的布局（视频编辑器里原文、译文分开摆时是两块，`TimelineState.subtitleScreenBlocks`）。
    static func create(
        blocks: [SubtitleRenderBlock],
        style: BurnInStyle,
        fontFileURL: URL?,
        aspectRatio: Double,
        title: String
    ) throws -> Prepared {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SrtFlow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let paths = FFmpegCommand.BurnIn()
        // 这台 Mac 上 libass 找不到回退字体的字（没下载苹方时的中文）点名一个每台 Mac 都有的，预览用同一个（SubtitleFallbackFont）。
        let ass = style.assDocument(
            blocks: blocks, aspectRatio: aspectRatio, title: title,
            fontOverrides: { SubtitleFontScale.burnOverrides($0, style: style) }
        )
        try Data(ass.utf8).write(to: directory.appendingPathComponent(paths.assFileName))

        let fontsDirectory = directory.appendingPathComponent(paths.fontsDirName, isDirectory: true)
        try FileManager.default.createDirectory(at: fontsDirectory, withIntermediateDirectories: true)
        if let fontFileURL {
            // 软链就够了：中文字体动辄十几兆，没必要每个任务真拷一份。
            try? FileManager.default.createSymbolicLink(
                at: fontsDirectory.appendingPathComponent(fontFileURL.lastPathComponent),
                withDestinationURL: fontFileURL
            )
        }

        return Prepared(directory: directory, paths: paths)
    }
}

/// 读字幕文件，编码探测跟文档窗口那边保持一致。
enum SubtitleLoader {
    static func load(_ url: URL) throws -> SubtitleDocumentModel {
        let data = try Data(contentsOf: url)
        // UTF-8 → UTF-16 → GBK，规则只在 SrtFlowCore 的 TextDecoding 一处（批量转换、AI 读文稿同一份）。
        guard let content = TextDecoding.decode(data) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        let format = SubtitleFormat.detect(from: url.lastPathComponent) ?? .text
        return SubtitleParser.parse(content, format: format, filename: url.lastPathComponent)
    }

    /// 按文件名给视频配字幕：`lesson01.mp4` ↔ `lesson01.srt`。
    ///
    /// 也接受字幕名多一段后缀的常见写法，比如 `lesson01.zh.srt`、
    /// `lesson01_中文.srt`。
    static func match(videos: [URL], subtitles: [URL]) -> [URL: URL] {
        var result: [URL: URL] = [:]
        var remaining = subtitles

        for video in videos {
            let base = video.deletingPathExtension().lastPathComponent.lowercased()

            // 先找完全同名的。
            if let index = remaining.firstIndex(where: {
                $0.deletingPathExtension().lastPathComponent.lowercased() == base
            }) {
                result[video] = remaining.remove(at: index)
                continue
            }

            // 再找以视频名开头的（多一段语言后缀那种）。
            if let index = remaining.firstIndex(where: {
                $0.deletingPathExtension().lastPathComponent.lowercased().hasPrefix(base)
            }) {
                result[video] = remaining.remove(at: index)
            }
        }

        // 一个视频配一个字幕的场景最常见，直接给它配上，省得用户再点一次。
        if result.isEmpty, videos.count == 1, remaining.count == 1 {
            result[videos[0]] = remaining[0]
        }

        return result
    }
}
