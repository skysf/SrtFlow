import AppKit
import Foundation
import PDFKit
import SrtFlowCore

// MARK: - 读文稿：Word、PDF、RTF、txt、md 里的文字（给 AI 用）
//
// 管什么：一个文稿文件 → 里面的文字（方案第 22 条：「文稿用系统能力读出文字给 AI；Pages 读不了」）。PDF 用 PDFKit，
// Word / RTF / ODT 用系统的富文本导入（NSAttributedString），纯文本按 UTF-8 → UTF-16 → GBK 读（SrtFlowCore 的
// TextDecoding，字幕读文件也是它）。以及按段取（`excerpt`，长文稿分几次读）。
// 不管什么：能不能读这个文件（AIWorkspace，点名文件夹以外的先问）、结果怎么写给 AI（AIFileTools）。

enum AIDocumentReader {
    enum Kind: String {
        case pdf, word, rtf, text
    }

    struct Document {
        var kind: Kind
        var text: String
        /// PDF 的页数（别的没有页的概念）。
        var pages: Int?
    }

    struct Unsupported: Error {
        let message: String
    }

    static func kind(of url: URL) -> Kind? {
        switch url.pathExtension.lowercased() {
        case "pdf": return .pdf
        case "doc", "docx", "odt": return .word
        case "rtf", "rtfd": return .rtf
        case "txt", "md", "markdown", "text", "csv": return .text
        default: return nil
        }
    }

    /// 读出文字。阻塞读文件（大 PDF 要一两秒）：调用方放到后台去跑。
    static func read(_ url: URL) throws -> Document {
        if url.pathExtension.lowercased() == "pages" {
            throw Unsupported(message: "SrtFlow cannot read Pages files. Ask the user to export it as PDF or Word (File > Export To in Pages).")
        }
        guard let kind = kind(of: url) else {
            throw Unsupported(message: "SrtFlow cannot read \(url.lastPathComponent) as a document. It reads PDF, Word (.doc, .docx), RTF, ODT, .txt and .md.")
        }
        switch kind {
        case .pdf:
            guard let pdf = PDFDocument(url: url) else {
                throw Unsupported(message: "\(url.lastPathComponent) could not be opened as a PDF (damaged or password-protected?).")
            }
            let text = pdf.string ?? ""
            return Document(kind: .pdf, text: normalized(text), pages: pdf.pageCount)
        case .word, .rtf:
            let attributed = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
            return Document(kind: kind, text: normalized(attributed.string), pages: nil)
        case .text:
            let data = try Data(contentsOf: url)
            guard let text = TextDecoding.decode(data) else {
                throw Unsupported(message: "\(url.lastPathComponent) is not UTF-8, UTF-16 or GBK text.")
            }
            return Document(kind: .text, text: normalized(text), pages: nil)
        }
    }

    /// 统一换行、去掉每行行尾的空白、把三个以上连续空行压成一个（PDF 抽出来的字常带这些），省 token。
    static func normalized(_ text: String) -> String {
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines = unified.components(separatedBy: "\n").map { line -> String in
            var trimmed = line
            while let last = trimmed.last, last == " " || last == "\t" { trimmed.removeLast() }
            return trimmed
        }
        var result: [String] = []
        var blanks = 0
        for line in lines {
            if line.isEmpty {
                blanks += 1
                if blanks <= 1 { result.append(line) }
            } else {
                blanks = 0
                result.append(line)
            }
        }
        lines = result
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 从第 `from` 个字（Character）起最多取 `maxCharacters` 个；`next` 是下一段的起点（读完了是 nil）。
    static func excerpt(_ text: String, from: Int, maxCharacters: Int) -> (text: String, next: Int?) {
        let total = text.count
        let start = min(max(0, from), total)
        let end = min(total, start + max(1, maxCharacters))
        let lower = text.index(text.startIndex, offsetBy: start)
        let upper = text.index(lower, offsetBy: end - start)
        return (String(text[lower..<upper]), end < total ? end : nil)
    }
}
