import AppKit
import CoreText
import Foundation
import SrtFlowCore

// read_document（读文稿，AIDocumentReader）：现造 GBK 的 txt、RTF、Word（docx）、带字的 PDF 各一份读回来对文字；
// Pages 和不认识的后缀要说清楚读不了；分段读的边界；换行和空行的整理。编法见 scripts/check-mcp.sh。

func runDocumentChecks() {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("srtflow-doc-check-\(getpid())")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    checkPlainText(in: folder)
    checkRichText(in: folder)
    checkPDF(in: folder)
    checkUnsupported(in: folder)
    checkExcerptAndNormalize()
}

private func readText(_ url: URL) -> String? {
    (try? AIDocumentReader.read(url))?.text
}

private func checkPlainText(in folder: URL) {
    // Windows 上写的中文讲稿常是 GBK：和读字幕同一条规则（UTF-8 → UTF-16 → GBK）。
    let gbk = folder.appendingPathComponent("讲稿.txt")
    let encoding = String.Encoding(rawValue: 0x8000_0421)
    try? "课程卖点：三天学会剪辑".data(using: encoding)?.write(to: gbk)
    checkEqual(readText(gbk), "课程卖点：三天学会剪辑", "a GBK .txt reads back as Chinese")
    let utf16 = folder.appendingPathComponent("notes.md")
    try? "# Title\r\n\r\n\r\n\r\nLine one   \r\nLine two".data(using: .utf16)?.write(to: utf16)
    checkEqual(readText(utf16), "# Title\n\nLine one\nLine two", "UTF-16 markdown: CRLF, trailing spaces and blank runs tidied")
    checkEqual(TextDecoding.decode(Data("plain".utf8)), "plain", "UTF-8 first")
}

private func checkRichText(in folder: URL) {
    let text = NSAttributedString(string: "Antarctica voyage\nDay one: the ice")
    let rtf = folder.appendingPathComponent("brief.rtf")
    if let data = try? text.data(from: NSRange(location: 0, length: text.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
        try? data.write(to: rtf)
    }
    checkEqual(readText(rtf), "Antarctica voyage\nDay one: the ice", "RTF text is read")
    checkEqual((try? AIDocumentReader.read(rtf))?.kind, .rtf, "RTF is reported as rtf")
    let docx = folder.appendingPathComponent("brief.docx")
    if let data = try? text.data(from: NSRange(location: 0, length: text.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]) {
        try? data.write(to: docx)
    }
    checkEqual(readText(docx), "Antarctica voyage\nDay one: the ice", "Word (.docx) text is read")
    checkEqual((try? AIDocumentReader.read(docx))?.kind, .word, "docx is reported as word")
}

/// 用 Core Text 往 PDF 里真写一行字，PDFKit 要读得出来。
private func checkPDF(in folder: URL) {
    let url = folder.appendingPathComponent("outline.pdf")
    var box = CGRect(x: 0, y: 0, width: 400, height: 200)
    guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
        check(false, "could not make a test PDF")
        return
    }
    context.beginPDFPage(nil)
    let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
    let line = CTLineCreateWithAttributedString(NSAttributedString(
        string: "SOUTH POLE EXPEDITION", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
    ))
    context.textPosition = CGPoint(x: 20, y: 100)
    CTLineDraw(line, context)
    context.endPDFPage()
    context.closePDF()
    let document = try? AIDocumentReader.read(url)
    check(document?.text.contains("SOUTH POLE EXPEDITION") == true, "PDF text is read (got \(String(describing: document?.text)))")
    checkEqual(document?.pages, 1, "PDF page count")
}

private func checkUnsupported(in folder: URL) {
    let pages = folder.appendingPathComponent("plan.pages")
    try? Data("x".utf8).write(to: pages)
    do {
        _ = try AIDocumentReader.read(pages)
        check(false, "a Pages file must be refused")
    } catch let error as AIDocumentReader.Unsupported {
        check(error.message.contains("export it as PDF or Word"), "Pages: tells the AI to ask for a PDF or Word export")
    } catch {
        check(false, "a Pages file gives the wrong error: \(error)")
    }
    checkThrows("an unknown extension is refused") {
        _ = try AIDocumentReader.read(folder.appendingPathComponent("clip.mov"))
    }
}

private func checkExcerptAndNormalize() {
    let text = "一二三四五六七八九十"
    let first = AIDocumentReader.excerpt(text, from: 0, maxCharacters: 4)
    checkEqual(first.text, "一二三四", "the first piece, counted in characters")
    checkEqual(first.next, 4, "where the next piece starts")
    let last = AIDocumentReader.excerpt(text, from: 8, maxCharacters: 4)
    checkEqual(last.text, "九十", "the last piece")
    check(last.next == nil, "nothing after the last piece")
    checkEqual(AIDocumentReader.excerpt(text, from: 50, maxCharacters: 4).text, "", "past the end is empty")
    checkEqual(AIDocumentReader.normalized("a\r\n\r\n\r\n\r\nb  \n"), "a\n\nb", "blank runs collapse to one blank line")
}
