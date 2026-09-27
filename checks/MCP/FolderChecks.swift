import Foundation
import SrtFlowCore

// 新东西默认放哪（Sources/SrtFlow/DefaultFolder.swift）。2026-09-27 用户拍板：
// 「不要到 Movies，到目标文件夹；用户没有给任何文件夹，就默认都到 Downloads」。
// 生产接线（手动面板、导出面板、AI 的输出都走这条规则，AI 改了没存过的工程马上存）由
// scripts/check-mcp.sh 里的扫描那一段钉着。

func runFolderChecks() {
    let names: Set<String> = ["Projects", "工程"]
    let downloads = URL(fileURLWithPath: "/Users/u/Downloads")
    let userHome = URL(fileURLWithPath: "/Users/u")
    let named = URL(fileURLWithPath: "/Users/u/Downloads/剪辑测试素材/素材A")

    // 工程的家
    let aiProject = URL(fileURLWithPath: "/Users/u/Trip/SrtFlow/工程/Trip.srtflowproj")
    checkEqual(DefaultFolder.home(ofProjectFile: aiProject, projectFolderNames: names).path, "/Users/u/Trip",
               "a project AI saved in X/SrtFlow/工程 lives at home X")
    let englishProject = URL(fileURLWithPath: "/Users/u/Trip/SrtFlow/Projects/Trip.srtflowproj")
    checkEqual(DefaultFolder.home(ofProjectFile: englishProject, projectFolderNames: names).path, "/Users/u/Trip",
               "saved while the app was in English: still X")
    let plainProject = URL(fileURLWithPath: "/Users/u/Trip/Trip.srtflowproj")
    checkEqual(DefaultFolder.home(ofProjectFile: plainProject, projectFolderNames: names).path, "/Users/u/Trip",
               "a project saved by hand lives in its own folder")
    let userSrtFlowFolder = URL(fileURLWithPath: "/Users/u/Documents/SrtFlow/Trip/Trip.srtflowproj")
    checkEqual(DefaultFolder.home(ofProjectFile: userSrtFlowFolder, projectFolderNames: names).path,
               "/Users/u/Documents/SrtFlow/Trip", "the user's own SrtFlow folder with other subfolders: no jump up")

    // 起点：点名的文件夹 → 工程的家 → 下载 → 家目录，没有「影片」
    checkEqual(DefaultFolder.start(named: named, projectHome: userHome, downloads: downloads, userHome: userHome), named,
               "the folder the user named comes first")
    let trip = URL(fileURLWithPath: "/Users/u/Trip")
    checkEqual(DefaultFolder.start(named: nil, projectHome: trip, downloads: downloads, userHome: userHome), trip,
               "no named folder: the project's home")
    checkEqual(DefaultFolder.start(named: nil, projectHome: nil, downloads: downloads, userHome: userHome), downloads,
               "no folder at all: Downloads")
    checkEqual(DefaultFolder.start(named: nil, projectHome: nil, downloads: nil, userHome: userHome), userHome,
               "no Downloads either: the home folder")

    // 撞名不覆盖、也不问
    let folder = URL(fileURLWithPath: "/Users/u/Trip/SrtFlow/工程")
    var taken: Set<String> = []
    let free = { (url: URL) in taken.contains(url.lastPathComponent) }
    checkEqual(ExportFileName.unoccupied(in: folder, stem: "Shot", pathExtension: "srtflowproj", exists: free).lastPathComponent,
               "Shot.srtflowproj", "a free name is used as is")
    taken = ["Shot.srtflowproj"]
    checkEqual(ExportFileName.unoccupied(in: folder, stem: "Shot", pathExtension: "srtflowproj", exists: free).lastPathComponent,
               "Shot 2.srtflowproj", "taken: add 2")
    taken = ["Shot.srtflowproj", "Shot 2.srtflowproj"]
    checkEqual(ExportFileName.unoccupied(in: folder, stem: "Shot", pathExtension: "srtflowproj", exists: free).lastPathComponent,
               "Shot 3.srtflowproj", "2 is taken too: add 3")
}
