import AppKit

// MARK: - 最近打开的工程
//
// 管什么：系统那份「最近打开」列表里的 SrtFlow 工程（记一笔、踢掉打不开的、列出还在的）。
// 不管什么：工程怎么打开和保存（VideoEditProjectDocument.swift）。
// 2026-09-27 从 VideoEditProjectDocument.swift 挪出来（那个文件登记过超标、只许降）。

/// 「最近的工程」直接用系统那份列表：File ▸ Open Recent 菜单、Dock 图标右键
/// 的最近文件，和编辑器空状态里的网格读的是同一份数据，不用自己维护。
enum RecentProjects {

    @MainActor
    static func note(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    /// 已经打不开了（被删了、盘拔了）就从列表里去掉。
    @MainActor
    static func forget(_ url: URL) {
        let remaining = NSDocumentController.shared.recentDocumentURLs.filter { $0 != url }
        NSDocumentController.shared.clearRecentDocuments(nil)
        for item in remaining.reversed() {
            NSDocumentController.shared.noteNewRecentDocumentURL(item)
        }
    }

    /// 还真实存在的最近工程。列表里可能留着已经被删掉的文件，进界面前过一遍。
    @MainActor
    static func existing(limit: Int = 12) -> [URL] {
        NSDocumentController.shared.recentDocumentURLs
            .filter { $0.pathExtension.lowercased() == VideoEditProjectFile.fileExtension }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .prefix(limit)
            .map { $0 }
    }

    @MainActor
    static func modifiedAt(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
