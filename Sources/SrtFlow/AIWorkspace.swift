import Foundation
import SrtFlowMCPKit

// MARK: - AI 能用哪些文件、新文件放哪、什么时候要用户点头
//
// 管什么：用户点名的文件夹（open_folder 登记，里面每一层都能用）、AI 做出来的文件放哪
// （起点下面的 `SrtFlow/` 子文件夹，按导出 / 工程分开；起点的规则在 DefaultFolder）、确认令牌。
// 产品口径见 docs/plans/2026-09-27-mcp.md 第 21–25 条。
// 不管什么：文件夹里有什么（AIMediaScan）、工具怎么做。
//
// **只有删文件才问**（方案第 34 条，2026-09-28 用户拍板）：删进废纸篓先问；读点名文件夹以外的文件问一次，
// 同意了就记住那个文件夹、以后不再问（AIReadGrants）；从不覆盖（撞名加编号），所以也不问；开着的工程没存过就先存下来再换，
// 不问也不丢。时间线上的改动一律不问 —— 有 ⌘Z 和「撤销这一轮」兜底。问法是结果里回 needs_confirmation + 令牌，
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

    /// 不用再问就能读的文件：在点名的文件夹里、在工程的家里（DefaultFolder.home）、在用户同意过的地方（AIReadGrants）、
    /// 或者工程里本来就在用。
    func allowsReading(_ url: URL, project: VideoEditProject) -> Bool {
        let path = url.standardizedFileURL.path
        let roots = folders.map(\.path) + [projectHome(project)?.standardizedFileURL.path].compactMap { $0 }
        if roots.contains(where: { path.hasPrefix($0 + "/") }) { return true }
        if AIReadGrants.shared.covers(url) { return true }
        return project.state.mediaURLs.contains { $0.standardizedFileURL.path == path }
    }

    /// 读点名文件夹以外的文件要用户点头：都能读就 nil，否则回 needs_confirmation。令牌绑着这一组文件
    /// （换了文件拿它来不认）；点过头就记住它们的文件夹，以后不再问。`verb` 写进问题里：「read」「look at」「listen to」。
    func confirmReading(
        _ urls: [URL], verb: String, args: AIToolArguments, project: VideoEditProject
    ) throws -> AIToolResult? {
        let outside = Set(urls.map(\.standardizedFileURL).filter { !allowsReading($0, project: project) }.map(\.path)).sorted()
        guard !outside.isEmpty else { return nil }
        let action = "read:" + outside.joined(separator: "|")
        if AIConfirmations.shared.consume(try args.string("confirm_token"), action: action) {
            AIReadGrants.shared.remember(outside.map { URL(fileURLWithPath: $0) })
            return nil
        }
        var names = outside.prefix(5).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        if outside.count > 5 { names += " and \(outside.count - 5) more" }
        let which = outside.count == 1 ? "which is" : "which are"
        return AIConfirmations.shared.ask(
            "SrtFlow needs to \(verb) \(names), \(which) outside the folder you opened. Allow it? "
                + "SrtFlow then remembers that folder and does not ask again for files in it.",
            action: action
        )
    }

    /// 新东西默认从哪开始：点名的文件夹 → 工程的家 → 「下载」（规则在 DefaultFolder）。
    /// 手动的「打开工程」「存储为」和导出面板第一次用的位置也从这里拿。
    func startFolder(project: VideoEditProject) -> URL {
        DefaultFolder.start(
            named: current,
            projectHome: projectHome(project),
            downloads: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first,
            userHome: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    /// AI 做出来的文件放哪：`<起点>/SrtFlow/<导出|工程>`。文件夹名跟着 App 的语言。
    func outputFolder(_ kind: Output, project: VideoEditProject) -> URL {
        startFolder(project: project)
            .appendingPathComponent(DefaultFolder.aiFolderName, isDirectory: true)
            .appendingPathComponent(kind.folderName, isDirectory: true)
    }

    private func projectHome(_ project: VideoEditProject) -> URL? {
        project.documentURL.map { DefaultFolder.home(ofProjectFile: $0, projectFolderNames: Self.projectFolderNames) }
    }

    /// 「工程」子文件夹在每种界面语言里的名字：切过语言，之前存的工程也认得出自己的家。
    private static let projectFolderNames = Set(
        AppLanguage.allCases.map { $0.bundle.localizedString(forKey: "Projects", value: "Projects", table: nil) }
    )

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
