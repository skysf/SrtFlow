import SwiftUI
import UniformTypeIdentifiers
import SrtFlowCore

extension UTType {
    static let srt = UTType(exportedAs: "com.srtflow.srt", conformingTo: .plainText)
    /// WebVTT is a system-owned text type. It conforms to `public.text`, but not
    /// to `public.plain-text`; asking for the latter can resolve to our custom
    /// VTT type instead and make real `org.w3.webvtt` files unselectable.
    static let vtt = UTType("org.w3.webvtt")
        ?? UTType(importedAs: "org.w3.webvtt", conformingTo: .text)
    static let ass = UTType(exportedAs: "com.srtflow.ass", conformingTo: .plainText)
    static let ssa = UTType(exportedAs: "com.srtflow.ssa", conformingTo: .plainText)
}

extension SubtitleFormat {
    var utType: UTType {
        switch self {
        case .text: return .plainText
        case .srt: return .srt
        case .vtt: return .vtt
        case .ass: return .ass
        case .ssa: return .ssa
        }
    }
}

final class SubtitleDocument: ReferenceFileDocument, ObservableObject {
    typealias Snapshot = SubtitleDocumentModel

    /// 可读类型 = 纯文本 + 各字幕扩展名。
    static let readableContentTypes: [UTType] = [
        .plainText, .srt, .vtt, .ass, .ssa
    ]

    @Published var model: SubtitleDocumentModel

    init(model: SubtitleDocumentModel = SubtitleDocumentModel()) {
        self.model = model
    }

    required init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard let content = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16)
                ?? String(data: data, encoding: .init(rawValue: 0x80000421)) /* GBK */ else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        let filename = configuration.file.filename ?? ""
        let format = SubtitleFormat.detect(from: filename) ?? .text
        model = SubtitleParser.parse(content, format: format, filename: filename)
    }

    func snapshot(contentType: UTType) throws -> SubtitleDocumentModel {
        model
    }

    func fileWrapper(snapshot: SubtitleDocumentModel, configuration: WriteConfiguration) throws -> FileWrapper {
        let content = SubtitleSerializer.serialize(snapshot, format: snapshot.format)
        return .init(regularFileWithContents: Data(content.utf8))
    }
}
