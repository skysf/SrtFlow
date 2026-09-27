import Foundation

// MARK: - 新东西默认放哪
//
// 管什么：一条规则 —— **用户正在用的文件夹**（跟 AI 点名的文件夹 → 工程的家），都没有就是「下载」。
// 手动的「打开工程」「存储为」、导出面板第一次用的位置、AI 做出来的工程和成片，都从这里拿起点。
// 2026-09-27 用户拍板：「不要到 Movies，到目标文件夹；用户没有给任何文件夹，就默认都到 Downloads」。
// 纯函数，自检够得着（scripts/check-mcp.sh）。
// 不管什么：导出面板记住的上次位置（VideoEditExporter）、AI 在起点下面建的 `SrtFlow/<导出|工程>`（AIWorkspace）。

enum DefaultFolder {
    /// AI 在起点下面建的那个子文件夹：`<起点>/SrtFlow/<导出|工程>`。
    static let aiFolderName = "SrtFlow"

    /// 工程的「家」：一般就是工程文件所在的文件夹；AI 存在 `X/SrtFlow/<工程>/` 里的工程，家是 X ——
    /// 不然之后的成片会进 `X/SrtFlow/工程/SrtFlow/导出`，AI 读 X 里的素材也要多问一句。
    /// `projectFolderNames`：「工程」这个子文件夹在每种界面语言里的名字（切过语言也认得出来）。
    /// 用户自己恰好有个叫 SrtFlow 的文件夹、下面的子文件夹不叫「工程」时不往上跳。
    static func home(ofProjectFile file: URL, projectFolderNames: Set<String>) -> URL {
        let folder = file.deletingLastPathComponent()
        let parent = folder.deletingLastPathComponent()
        guard parent.lastPathComponent == aiFolderName, projectFolderNames.contains(folder.lastPathComponent) else {
            return folder
        }
        return parent.deletingLastPathComponent()
    }

    /// 起点：点名的文件夹 → 工程的家 → 「下载」→ 家目录。**没有「影片」。**
    static func start(named: URL?, projectHome: URL?, downloads: URL?, userHome: URL) -> URL {
        named ?? projectHome ?? downloads ?? userHome
    }

    /// 不覆盖已有文件、也不问：`名字.后缀` 占了就 `名字 2.后缀`、`名字 3.后缀`……
    static func unoccupied(in folder: URL, stem: String, pathExtension: String, exists: (URL) -> Bool) -> URL {
        var candidate = folder.appendingPathComponent(stem).appendingPathExtension(pathExtension)
        var number = 2
        while exists(candidate) {
            candidate = folder.appendingPathComponent("\(stem) \(number)").appendingPathExtension(pathExtension)
            number += 1
        }
        return candidate
    }
}
