import Foundation

/// High-level helpers shared by single-document export and batch conversion.
public enum SubtitleConverter {

    /// Converts subtitle file contents from one format to another.
    public static func convert(_ content: String, from source: SubtitleFormat, to target: SubtitleFormat) -> String {
        let doc = SubtitleParser.parse(content, format: source)
        return SubtitleSerializer.serialize(doc, format: target)
    }

    /// Reads a subtitle file (format from its extension, text via `TextDecoding`) and returns it converted to
    /// `target`, without writing anything. Batch conversion and the AI's convert_subtitles both go through here.
    public static func convertedContents(of url: URL, to target: SubtitleFormat) throws -> String {
        guard let source = SubtitleFormat.detect(from: url.lastPathComponent) else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let data = try Data(contentsOf: url)
        guard let content = TextDecoding.decode(data) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return convert(content, from: source, to: target)
    }

    /// Converts a file on disk, writing `<name>.<targetExt>` into `outputDirectory`
    /// (defaults to the source file's directory). Returns the output URL.
    @discardableResult
    public static func convertFile(at url: URL, to target: SubtitleFormat, outputDirectory: URL? = nil) throws -> URL {
        let converted = try convertedContents(of: url, to: target)
        let directory = outputDirectory ?? url.deletingLastPathComponent()
        let outputURL = directory.appendingPathComponent(url.deletingPathExtension().lastPathComponent)
            .appendingPathExtension(target.fileExtension)
        try Data(converted.utf8).write(to: outputURL)
        return outputURL
    }
}
