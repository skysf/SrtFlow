import Foundation

/// Reads the text of a file whose encoding is unknown. One rule for every place that opens user text files —
/// subtitle files (video editor, subtitle editor, burn-in queue), batch subtitle conversion, and documents the AI
/// reads (read_document).
///
/// Order: a byte-order mark decides; then strict UTF-8; then UTF-16 **only when the bytes look like UTF-16**
/// (ASCII characters — timestamps, digits, spaces — leave a zero in every other byte); then GBK / GB 18030
/// (Chinese subtitle files and notes from Windows).
///
/// Trying plain `.utf16` before GBK was a bug (2026-09-27, docs/bugfixes/2026-09-27-gbk-subtitles-read-as-utf16.md):
/// Foundation decodes almost any even-length data as UTF-16, so every GBK file with an even byte count — about
/// half of them — came out as garbage and GBK was never tried.
public enum TextDecoding {
    /// GBK / GB 18030 on macOS (CoreFoundation's kCFStringEncodingGB_18030_2000 as an NSStringEncoding).
    static let gbk = String.Encoding(rawValue: 0x8000_0421)

    public static func decode(_ data: Data) -> String? {
        let head = [UInt8](data.prefix(3))
        if head.starts(with: [0xEF, 0xBB, 0xBF]) { return String(data: data.dropFirst(3), encoding: .utf8) }
        if head.starts(with: [0xFF, 0xFE]) { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        if head.starts(with: [0xFE, 0xFF]) { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let endian = utf16WithoutMark(data), let utf16 = String(data: data, encoding: endian) { return utf16 }
        return String(data: data, encoding: gbk)
    }

    /// UTF-16 without a byte-order mark: at least a fifth of the byte pairs have a zero on one side and (almost)
    /// none on the other. GBK and UTF-8 text never contain zero bytes.
    static func utf16WithoutMark(_ data: Data) -> String.Encoding? {
        let sample = [UInt8](data.prefix(8192))
        guard sample.count >= 2, data.count % 2 == 0 else { return nil }
        var evenZeros = 0
        var oddZeros = 0
        for (index, byte) in sample.enumerated() where byte == 0 {
            if index % 2 == 0 { evenZeros += 1 } else { oddZeros += 1 }
        }
        let pairs = sample.count / 2
        if oddZeros * 5 >= pairs, evenZeros * 4 <= oddZeros { return .utf16LittleEndian }
        if evenZeros * 5 >= pairs, oddZeros * 4 <= evenZeros { return .utf16BigEndian }
        return nil
    }
}
