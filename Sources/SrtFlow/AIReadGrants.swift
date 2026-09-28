import Foundation

// MARK: - 点名文件夹以外的文件：问一次，记住那个文件夹
//
// 管什么：用户在对话里同意过「读这个文件」之后记下的地方（方案第 34 条：问一次就记住，重启也记得）。
// 以后读同一个文件夹（含子文件夹）里的文件不再问；设置 → AI 里列出来，可以一条条删。
// 记的是文件所在的文件夹；那个文件夹太大（根目录、顶层的 /Users 这类、某个卷的根、个人文件夹本身）时只记这一个文件 ——
// 不然同意读一个文件就等于放开了整个家目录。
// 不管什么：什么时候问（AIWorkspace.confirmReading）、点名的文件夹（AIWorkspace.folders，只在这次运行里有效）。

@MainActor
final class AIReadGrants: ObservableObject {
    static let shared = AIReadGrants()

    /// 记下的文件夹或文件（标准化过的绝对路径），按字母排。
    @Published private(set) var paths: [String]

    private static let defaultsKey = "AIReadGrants"

    private init() {
        paths = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
    }

    func covers(_ url: URL) -> Bool {
        Self.covers(url.standardizedFileURL.path, grants: paths)
    }

    /// 用户同意读这几个文件了：记下各自的文件夹（已经被记下的地方盖住的不重复记）。
    func remember(_ urls: [URL]) {
        let next = Self.adding(urls, to: paths, home: FileManager.default.homeDirectoryForCurrentUser)
        guard next != paths else { return }
        save(next)
    }

    func remove(_ path: String) {
        save(paths.filter { $0 != path })
    }

    private func save(_ next: [String]) {
        paths = next
        UserDefaults.standard.set(next, forKey: Self.defaultsKey)
    }

    // MARK: 纯计算（scripts/check-mcp.sh 钉着）

    /// 同意读 `file` 之后记下哪里：它所在的文件夹；那个文件夹太大就只记这个文件。
    nonisolated static func grant(for file: URL, home: URL) -> String {
        let file = file.standardizedFileURL
        let folder = file.deletingLastPathComponent()
        return isTooBroad(folder, home: home) ? file.path : folder.path
    }

    /// 根目录、顶层文件夹（/Users、/Applications、/tmp……）、某个卷的根（/Volumes/X）、个人文件夹本身。
    nonisolated static func isTooBroad(_ folder: URL, home: URL) -> Bool {
        let folder = folder.standardizedFileURL
        if folder.path == home.standardizedFileURL.path { return true }
        let components = folder.pathComponents
        if components.count <= 2 { return true }
        return components.count == 3 && components[1] == "Volumes"
    }

    nonisolated static func covers(_ path: String, grants: [String]) -> Bool {
        grants.contains { path == $0 || path.hasPrefix($0 == "/" ? $0 : $0 + "/") }
    }

    /// 记下这几个文件之后的清单：新记的盖住了旧的（旧的是它的子文件夹）就把旧的去掉；已经被盖住的不记。
    nonisolated static func adding(_ files: [URL], to grants: [String], home: URL) -> [String] {
        var next = grants
        for file in files {
            let grant = grant(for: file, home: home)
            guard !covers(grant, grants: next) else { continue }
            next.removeAll { covers($0, grants: [grant]) }
            next.append(grant)
        }
        return next.sorted()
    }
}
