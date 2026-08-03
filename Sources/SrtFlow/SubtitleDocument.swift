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

/// 字幕文件的可读类型 = 纯文本 + 各字幕扩展名。
///
/// 以前这里是个 `ReferenceFileDocument`，配着独立的编辑窗口。字幕编辑并进
/// 烧录页之后，文档场景没有了，留下的只有「哪些文件算字幕」这一件事。
enum SubtitleFileTypes {
    static let readable: [UTType] = [
        .plainText, .srt, .vtt, .ass, .ssa
    ]
}
