import Foundation
import SrtFlowMCPKit

// MARK: - 工具：读文稿
//
// 管什么：read_document —— 用户给的讲稿、课程大纲、卖点清单（Word、PDF、RTF、txt、md）读成文字交给 AI
// （方案第 22 条）。长文稿分段读（`from_char` / `max_chars`），免得一次塞满对话。
// 不管什么：怎么读（AIDocumentReader）、能不能读这个文件（AIWorkspace，点名文件夹以外的先问）。

@MainActor
enum AIFileTools {
    static let defaultMaxCharacters = 20_000

    static func readDocument(_ args: AIToolArguments, _ project: VideoEditProject) async throws -> AIToolResult {
        let path = try args.requiredString("file")
        let url = AIWorkspace.shared.resolve(path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw AIToolError("\(path) does not exist.") }
        if !AIWorkspace.shared.allowsReading(url, project: project) {
            let action = "read:" + url.standardizedFileURL.path
            if !AIConfirmations.shared.consume(try args.string("confirm_token"), action: action) {
                return AIConfirmations.shared.ask(
                    "SrtFlow needs to read \(url.lastPathComponent), which is outside the folder you opened. Allow it?",
                    action: action
                )
            }
        }
        let from = max(0, try args.int("from_char") ?? 0)
        let limit = min(max(try args.int("max_chars") ?? defaultMaxCharacters, 500), 100_000)
        // 读大 PDF 要一两秒、会卡住线程：放到 AI 自己的后台队列上，不占主线程也不进 Swift 并发的线程池。
        let outcome = await MediaReadQueue.run(on: MediaReadQueue.analysis) {
            Result { try AIDocumentReader.read(url) }
        }
        let document: AIDocumentReader.Document
        do {
            document = try outcome.get()
        } catch let unsupported as AIDocumentReader.Unsupported {
            throw AIToolError(unsupported.message)
        } catch {
            throw AIToolError("SrtFlow could not read \(url.lastPathComponent): \(error.localizedDescription)")
        }
        let piece = AIDocumentReader.excerpt(document.text, from: from, maxCharacters: limit)
        var result: [String: JSONValue] = [
            "file": .string(AIWorkspace.shared.display(url)),
            "kind": .string(document.kind.rawValue),
            "characters": .number(Double(document.text.count)),
            "from_char": .number(Double(min(from, document.text.count))),
            "text": .string(piece.text)
        ]
        if let pages = document.pages { result["pages"] = .number(Double(pages)) }
        if let next = piece.next {
            result["next_from_char"] = .number(Double(next))
            result["note"] = "There is more: call read_document again with from_char = next_from_char."
        }
        if document.text.isEmpty {
            result["note"] = "No text found. A scanned PDF has pictures of text only; SrtFlow does not read those."
        }
        return .ok(.object(result))
    }
}
