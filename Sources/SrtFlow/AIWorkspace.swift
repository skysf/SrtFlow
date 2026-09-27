import Foundation
import SrtFlowMCPKit

// MARK: - AI 能用哪些文件、新文件放哪、什么时候要用户点头
//
// 管什么：用户点名的文件夹（open_folder 登记，里面每一层都能用）、AI 做出来的文件放哪
// （点名文件夹里的 `SrtFlow/` 子文件夹，按导出 / 工程分开）、确认令牌。
// 产品口径见 docs/plans/2026-09-27-mcp.md 第 21–25 条。
// 不管什么：文件夹里有什么（AIMediaScan）、工具怎么做。
//
// **只有动硬盘上的文件才问**：覆盖已有文件、读点名文件夹以外的文件。时间线上的改动
// 一律不问 —— 有 ⌘Z 和「撤销这一轮」兜底。问法是结果里回 needs_confirmation + 令牌，
// AI 把问题转述给用户，用户同意之后带着令牌再调一次（令牌一次有效、十分钟过期）。

@MainActor
final class AIWorkspace {
    static let shared = AIWorkspace()

    /// 用户点名过的文件夹，最近的在最后。
    private(set) var folders: [URL] = []

    /// 「打开的文件夹」：相对路径按它解析、结果里的路径按它写短、新文件放它下面。
    var current: URL? { folders.last }

    private init() {}

    func register(_ folder: URL) {
        let standardized = folder.standardizedFileURL
        folders.removeAll { $0.path == standardized.path }
        folders.append(standardized)
    }

    func resolve(_ path: String) -> URL {
        AIFormat.url(fromPath: path, relativeTo: current)
    }

    func display(_ url: URL) -> String {
        AIFormat.path(url, relativeTo: current)
    }

    /// 不用再问就能读的文件：在点名的文件夹里、在工程文件旁边、或者工程里本来就在用。
    func allowsReading(_ url: URL, project: VideoEditProject) -> Bool {
        let path = url.standardizedFileURL.path
        let roots = folders.map(\.path) + [project.documentURL?.deletingLastPathComponent().standardizedFileURL.path].compactMap { $0 }
        if roots.contains(where: { path.hasPrefix($0 + "/") }) { return true }
        return project.state.mediaURLs.contains { $0.standardizedFileURL.path == path }
    }

    /// AI 做出来的文件放哪：`<点名的文件夹>/SrtFlow/<导出|工程>`；没点名过就放在工程文件旁边，
    /// 再没有就是「影片」文件夹。文件夹名跟着 App 的语言。
    func outputFolder(_ kind: Output, project: VideoEditProject) -> URL {
        let base = current
            ?? project.documentURL?.deletingLastPathComponent()
            ?? VideoEditProject.defaultProjectDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("SrtFlow", isDirectory: true)
            .appendingPathComponent(kind.folderName, isDirectory: true)
    }

    enum Output {
        case exports, projects

        var folderName: String {
            switch self {
            case .exports: return L10n("Exports")
            case .projects: return L10n("Projects")
            }
        }
    }
}

/// 确认令牌：「用户在对话里点过头」的凭据。
@MainActor
final class AIConfirmations {
    static let shared = AIConfirmations()

    private var pending: [String: (action: String, expires: Date)] = [:]
    private static let lifetime: TimeInterval = 600
    private static let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")

    private init() {}

    /// 发一张令牌。`action` 写清楚这张令牌放行的是哪一件事（「覆盖某个文件」），
    /// 换了一件事拿它来不认。
    func ask(_ question: String, action: String) -> AIToolResult {
        pending = pending.filter { $0.value.expires > Date() }
        let token = String((0..<6).map { _ in Self.alphabet.randomElement()! })
        pending[token] = (action, Date().addingTimeInterval(Self.lifetime))
        return .needsConfirmation(question: question, token: token)
    }

    /// 令牌对得上这件事就收下（一次有效）。
    func consume(_ token: String?, action: String) -> Bool {
        guard let token, let entry = pending[token], entry.action == action, entry.expires > Date() else {
            return false
        }
        pending.removeValue(forKey: token)
        return true
    }
}
