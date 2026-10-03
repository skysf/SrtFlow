import Foundation
import SrtFlowMCPKit

// MARK: - 工具：读文稿、整理文件
//
// 管什么：read_document —— 用户给的讲稿、课程大纲、卖点清单（Word、PDF、RTF、txt、md）读成文字交给 AI
// （方案第 22 条），长文稿分段读（`from_char` / `max_chars`）；manage_files —— 在用户点名的文件夹里移动、改名、
// 建文件夹、删除进废纸篓（第 23、24 条；删除先问）。
// 不管什么：怎么读（AIDocumentReader）、怎么动文件（AIFileOperations）、能不能读这个文件（AIWorkspace）。

@MainActor
enum AIFileTools {
    static let defaultMaxCharacters = 20_000

    static func readDocument(_ args: AIToolArguments, _ project: VideoEditProject) async throws -> AIToolResult {
        let path = try args.requiredString("file")
        let url = AIWorkspace.shared.resolve(path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw AIToolError("\(path) does not exist.") }
        if let ask = try AIWorkspace.shared.confirmReading([url], verb: "read", args: args, project: project) {
            return ask
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

    // MARK: 删文件先问

    /// 把这些文件挪进废纸篓之前先问（MCP 方案第 21、23、34 条：删文件是唯一要用户点头的改动）。令牌绑着这一批文件，
    /// 换了文件拿它来不认；点过头返回 nil，否则回 needs_confirmation。manage_files 的删除和 record_screen 丢弃上次没收完的录制都走这里
    /// —— 会问的地方只许这里和 AIWorkspace.confirmReading（scripts/check-mcp.sh 钉着）。
    /// - Parameter describing: 问题里怎么称呼这批文件（nil = 「N 个文件」）。
    static func confirmTrash(_ files: [URL], args: AIToolArguments, describing: String? = nil) throws -> AIToolResult? {
        let key = "trash:" + files.map(\.standardizedFileURL.path).sorted().joined(separator: "|")
        if AIConfirmations.shared.consume(try args.string("confirm_token"), action: key) { return nil }
        let names = files.map(\.lastPathComponent)
        let list = names.prefix(5).joined(separator: ", ") + (names.count > 5 ? " and \(names.count - 5) more" : "")
        let question = describing.map { "SrtFlow will move \($0) (\(list)) to the Trash. Go ahead?" }
            ?? "SrtFlow will move \(names.count) file(s) to the Trash: \(list). Go ahead?"
        return AIConfirmations.shared.ask(question, action: key)
    }

    // MARK: manage_files

    static func manageFiles(_ args: AIToolArguments, _ project: VideoEditProject) throws -> AIToolResult {
        let names = AIFileOperations.Action.allCases.map(\.rawValue)
        guard let raw = try args.choice("action", from: names), let action = AIFileOperations.Action(rawValue: raw) else {
            throw AIToolError("action is required: \(names.joined(separator: ", ")).")
        }
        let workspace = AIWorkspace.shared
        var sources = try (args.stringArray("files") ?? []).map { workspace.resolve($0) }
        if let one = try args.string("file") { sources.append(workspace.resolve(one)) }
        let target = try (args.string("to") ?? args.string("path")).map { workspace.resolve($0) }
        let steps: [AIFileOperations.Step]
        do {
            steps = try AIFileOperations.plan(
                action, sources: sources, to: target, newName: try args.string("new_name"), roots: workspace.folders,
                exists: { FileManager.default.fileExists(atPath: $0.path) }
            )
        } catch let refusal as AIFileOperations.Refusal {
            throw AIToolError(refusal.message)
        }
        // 删除一律先问（方案第 21、23 条），令牌绑着这一批文件。
        if action == .trash, let ask = try confirmTrash(steps.compactMap(\.source), args: args) { return ask }
        let outcome = AIFileOperations.perform(steps, action: action)
        // 工程里用到的素材挪了、改了名：按书签跟过去（和用户在访达里挪了素材同一条路）。
        if action == .move || action == .rename, !outcome.done.isEmpty { project.revalidateMediaLocations() }
        let done: [JSONValue] = outcome.done.map { step in
            var entry: [String: JSONValue] = [:]
            if let source = step.source { entry["from"] = .string(workspace.display(source)) }
            if let destination = step.destination {
                entry[action == .trash ? "in_trash" : "to"] = .string(action == .trash ? destination.path : workspace.display(destination))
            }
            return .object(entry)
        }
        var result: [String: JSONValue] = [
            "action": .string(action.rawValue),
            "done": .array(done),
            "note": "File changes are not undone by Command-Z or undo; tell the user what you moved, renamed or trashed (trashed files are in the Trash)."
        ]
        guard let error = outcome.error else { return .ok(.object(result)) }
        result["error"] = .string(error)
        var failed = AIToolResult.ok(.object(result))
        failed.isError = true
        return failed
    }
}
