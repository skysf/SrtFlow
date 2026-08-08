import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// `.srtflowproj`。Info.plist 里声明了同一个标识符，双击工程文件才会回到 SrtFlow。
    static let srtFlowProject = UTType(
        exportedAs: "com.srtflow.project",
        conformingTo: .json
    )
}

/// 工程的打开、保存、自动保存和素材重链接。
///
/// 刻意**不**用 NSDocument：那套东西要一个工程一个窗口，跟「一个主窗口 + 侧边栏
/// 切工具」的结构对不上。但「最近打开」照样白嫖 `NSDocumentController` ——
/// File ▸ Open Recent 和 Dock 图标右键的列表都是它管的。
extension VideoEditProject {

    var projectName: String {
        documentURL?.deletingPathExtension().lastPathComponent ?? L10n("Untitled")
    }

    var isUntitled: Bool { documentURL == nil }

    // MARK: - 新建

    func newProject() {
        guard prepareToCloseDocument() else { return }
        closeCurrentDocument()
        replaceStateForDocument(TimelineState())
    }

    // MARK: - 切换工程的把关

    /// 关掉当前工程之前先把改动落定。**返回 false 表示调用方必须中止切换。**
    ///
    /// 以前这里是无条件 `flushAutosave()` 然后直接关。磁盘满、权限变了、外接盘
    /// 被拔掉的时候，保存是失败的，而当前工程照样被关掉 —— 未保存的编辑就这么
    /// 没了。切工程必须是要么整个成功、要么原地不动。
    ///
    /// 退出 App（`applicationShouldTerminate`）也走这里，所以不是 private。
    func prepareToCloseDocument() -> Bool {
        // 录制期间禁止切换工程。**挂在这里而不是按钮的 disabled 上** ——
        // 计划 §11.3 要求「实际执行入口」再校验一次：New / Open / Open Recent /
        // Finder 外部打开 / 退出全都经过这个方法，菜单置灰挡不住这些路径。
        // `.importing` / `.partialRecovery` 也算录制中：文件写完了但入轨事务
        // 没提交、或用户还没处置 partial，此时切工程素材会进错工程。
        if #available(macOS 15.0, *), ScreenRecordingCoordinator.shared.locksProjectSwitching {
            notice = L10n("Stop the screen recording first.")
            return false
        }
        if documentURL != nil {
            // flushAutosave 失败时已经把原因写进 notice 了，这里别再覆盖。
            return flushAutosave()
        }
        // 从没存过、但已经剪了东西：直接扔掉就是数据丢失，得问一句。
        guard !state.isEmpty else { return true }
        return confirmDiscardUntitled()
    }

    private func confirmDiscardUntitled() -> Bool {
        let alert = NSAlert()
        alert.messageText = L10n("Save this project before closing it?")
        alert.informativeText = L10n("It has never been saved, so the edits will be lost.")
        alert.addButton(withTitle: L10n("Save…"))
        alert.addButton(withTitle: L10n("Discard"))
        alert.addButton(withTitle: L10n("Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveDocumentAs()
            // 用户在存盘面板上点了取消，或者写盘失败 —— 都不能继续往下切。
            return documentURL != nil && !hasUnsavedChanges
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    /// 清掉属于「上一个工程」的所有运行时状态。**只在 `prepareToCloseDocument`
    /// 放行之后调用。** 漏掉任何一条都会串味：播放器还在放上一条片子、⌘Z 能把
    /// 上一条的内容撤回来、后台导入把素材追加进新工程。
    private func closeCurrentDocument() {
        invalidateDocumentGeneration()
        autosaveTask?.cancel()
        autosaveTask = nil
        clock.pause()
        clock.detach()
        cancelLiveEdit()
        selectedClipIDs = []
        selectedShapeID = nil
        missingMedia = []
        notice = nil
        documentURL = nil
        documentBookmark = nil
        mediaRecords = [:]
        hasUnsavedChanges = false
        effectiveUndoManager?.removeAllActions()
    }

    // MARK: - 打开

    func promptOpenProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.srtFlowProject]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = Self.defaultProjectDirectory
        panel.prompt = L10n("Open")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await openProject(at: url) }
    }

    /// 打开工程。
    ///
    /// 顺序很讲究：**先把目标读出来验明正身，再动手里这条**。反过来的话，目标
    /// 文件损坏时当前工程已经被关掉了 —— 画面还在，但 documentURL、撤销栈、脏
    /// 标记全没了，后面的编辑再也不会自动保存。
    func openProject(at url: URL) async {
        // 「重新打开」当前工程 = 把改动落定，不走载入。真走载入的话顺序是
        // 读到磁盘上的旧状态 → flush 把新状态写下去 → 再拿旧状态盖回内存 ——
        // 下一次编辑就会把新状态从磁盘上也抹掉。
        if let current = documentURL,
           current.standardizedFileURL.resolvingSymlinksInPath().path
               == url.standardizedFileURL.resolvingSymlinksInPath().path {
            flushAutosave()
            return
        }

        openRequestToken &+= 1
        let token = openRequestToken

        let result: VideoEditProjectIO.LoadResult
        do {
            // 载入要遍历素材、可能还要搜目录，别占着主线程。
            result = try await Task.detached(priority: .userInitiated) {
                try VideoEditProjectIO.load(from: url)
            }.value
        } catch {
            guard token == openRequestToken else { return }
            notice = error.localizedDescription
            // 文件是坏的或者版本太新 —— 那也还是个存在的文件，别从最近列表里踢掉；
            // 只有彻底找不到了才清理。
            if !FileManager.default.fileExists(atPath: url.path) {
                RecentProjects.forget(url)
            }
            return
        }

        // 载入期间用户又点开了别的工程：这份结果过期了，别拿它顶掉人家。
        guard token == openRequestToken else { return }
        guard prepareToCloseDocument() else { return }
        // prepareToCloseDocument 可能弹过模态框（跑嵌套 runloop），再验一次。
        guard token == openRequestToken else { return }
        closeCurrentDocument()

        replaceStateForDocument(result.timeline)
        documentURL = url
        documentBookmark = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        mediaRecords = result.records
        missingMedia = result.missingMedia
        RecentProjects.note(url)
        scheduleRebuild()

        // 丢失的素材由预览区顶上的 MissingMediaBar 长期显示（那里还带重链接入口），
        // 不再往 notice 里塞一遍 —— 同一句话说两遍。

        // 素材是靠书签/相对路径找回来的：工程里记的路径已经过时，趁热存一次，
        // 下次打开就能走「原地命中」的快路径。
        if result.didRelink {
            hasUnsavedChanges = true
            saveNow()
        } else {
            hasUnsavedChanges = false
        }

        if !result.stillsToRegenerate.isEmpty {
            let generation = documentGeneration
            trackImportTask(Task {
                await regenerateStills(result.stillsToRegenerate, generation: generation)
            })
        }
    }

    // MARK: - 图片段的静帧

    /// 静帧缓存被系统清掉了就重转一遍。图片本身还在工程里记着，用户无感。
    private func regenerateStills(_ requests: [StillRegeneration], generation: Int) async {
        guard let ffmpeg = await awaitVideoEngine() else {
            guard isCurrentGeneration(generation) else { return }
            notice = L10n("The video engine isn’t available, so image clips couldn’t be prepared.")
            return
        }
        for request in requests {
            let image = request.image
            guard isCurrentGeneration(generation) else { return }
            guard let still = try? await StillImageClipFactory.stillVideo(
                for: image,
                ffmpeg: ffmpeg,
                nativeResolution: request.nativeResolution
            ) else { continue }
            guard isCurrentGeneration(generation) else { return }
            applyDocumentRepair { state in
                // 只认同政策的段，理由见 `attachStill`（纯值函数，自检里有回归）。
                VideoEditProjectIO.attachStill(
                    still,
                    forImage: image,
                    nativeResolution: request.nativeResolution,
                    in: &state
                )
            }
        }
    }

    /// 等 ffmpeg 就位。
    ///
    /// **不能直接取 `runtime`**：冷启动双击工程时，`application(_:open:)` 跑在
    /// 窗口出现之前，而 `resolveIfNeeded()` 要等 `onAppear` 才被调到 ——
    /// 那一刻 `runtime` 必然是 nil。以前在这里直接 return，图片段就永久停在
    /// 「待转换」，导出时还会被静默排除，图片从成片里凭空消失。
    private func awaitVideoEngine() async -> URL? {
        let toolchain = MediaToolchain.shared
        if let url = toolchain.runtime?.url { return url }
        toolchain.resolveIfNeeded()
        // 解析是查几个固定路径 + 跑一次 `ffmpeg -version`，20 秒足够有余。
        for _ in 0..<130 {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return nil }
            if let url = toolchain.runtime?.url { return url }
            // 解析结束了还是没有，就是真没有，别干等。
            if !toolchain.isResolving { return nil }
        }
        return toolchain.runtime?.url
    }

    // MARK: - 保存

    /// 改动后延迟落盘。拖动时间线时这个方法每帧都会被调到，靠取消重排实现防抖。
    func scheduleAutosave() {
        autosaveTask?.cancel()
        // 还没选过位置的未命名工程不偷偷建文件，等第一次 ⌘S 或导出。
        guard documentURL != nil else { return }
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// ⌘S：立刻把挂着的自动保存写下去。没存过的工程先问存哪。
    func saveDocument() {
        if documentURL == nil {
            saveDocumentAs()
        } else {
            flushAutosave()
        }
    }

    /// 把待写的改动立刻落盘（关窗、切工程、退出前都走一次）。
    /// **返回值必须被在意**：写不下去就不能继续做「关掉当前工程」这类破坏性操作。
    @discardableResult
    func flushAutosave() -> Bool {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard documentURL != nil, hasUnsavedChanges else { return true }
        return saveNow()
    }

    func saveDocumentAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.srtFlowProject]
        panel.nameFieldStringValue = suggestedFileName
        panel.directoryURL = Self.defaultProjectDirectory
        panel.canCreateDirectories = true
        panel.prompt = L10n("Save")
        guard panel.runModal() == .OK, var url = panel.url else { return }
        // 用户把扩展名删了也照样存成工程文件，不然下次双击打不开。
        if url.pathExtension.lowercased() != VideoEditProjectFile.fileExtension {
            url = url.appendingPathExtension(VideoEditProjectFile.fileExtension)
        }
        // 新身份只有写盘成功才作数。先换后写的话，写失败（目标盘只读、满了）
        // 会让工程卡在一个根本写不进去的 URL 上，原来那份从此不再更新。
        let previousURL = documentURL
        let previousBookmark = documentBookmark
        documentURL = url
        documentBookmark = nil
        hasUnsavedChanges = true
        if !saveNow() {
            documentURL = previousURL
            documentBookmark = previousBookmark
        }
    }

    /// 未命名工程的建议文件名：拿主轨第一段素材的名字，比 "Untitled" 好认。
    private var suggestedFileName: String {
        let base = state.mainClips.first?.name ?? L10n("Untitled")
        return "\(base).\(VideoEditProjectFile.fileExtension)"
    }

    @discardableResult
    func saveNow() -> Bool {
        guard var url = documentURL else { return false }

        // 工程文件本身可能在访达里被改了名或挪了地方。不跟过去的话，这次保存会在
        // 旧位置重新造一个旧名字的文件，用户以为正在编辑的那份反而再也不更新。
        if !FileManager.default.fileExists(atPath: url.path),
           let moved = relocatedDocumentURL() {
            url = moved
            documentURL = moved
        }

        do {
            mediaRecords = try VideoEditProjectIO.save(
                state,
                to: url,
                knownRecords: mediaRecords
            )
            if documentBookmark == nil {
                documentBookmark = try? url.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            }
            hasUnsavedChanges = false
            RecentProjects.note(url)
            return true
        } catch {
            notice = String(
                format: L10n("Could not save the project: %@"),
                error.localizedDescription
            )
            return false
        }
    }

    /// 工程文件被改名/移动后的新位置（同一个盘）。
    private func relocatedDocumentURL() -> URL? {
        guard let documentBookmark else { return nil }
        var stale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: documentBookmark,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ), FileManager.default.fileExists(atPath: resolved.path) else { return nil }
        return resolved
    }

    /// 新工程默认往哪存。`~/Movies` 是 macOS 给影片的标准位置，不自建目录。
    static var defaultProjectDirectory: URL? {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
    }

    // MARK: - Finder

    func revealInFinder() {
        guard let documentURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([documentURL])
    }

    // MARK: - 素材重链接

    /// 让用户指认一个丢失的素材。指完之后，**同一个目录下**其他丢失的素材按
    /// 文件名自动配上 —— 素材通常整批一起搬，一次别让人点十遍。
    func promptRelink(_ missing: URL) {
        let panel = NSOpenPanel()
        panel.message = String(
            format: L10n("Where is “%@”?"),
            missing.lastPathComponent
        )
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = L10n("Relink")
        guard panel.runModal() == .OK, let replacement = panel.url else { return }

        let directory = replacement.deletingLastPathComponent()
        var relinked: [URL: URL] = [missing: replacement]
        for other in missingMedia where other != missing {
            let candidate = directory.appendingPathComponent(other.lastPathComponent)
            if FileManager.default.fileExists(atPath: candidate.path) {
                relinked[other] = candidate
            }
        }

        var pendingStills: [StillRegeneration] = []
        applyDocumentRepair { state in
            for (old, new) in relinked { state.replaceMedia(old, with: new) }
            // 重链接的要是图片，换掉的只是 `stillImageURL`，`sourceURL` 还指着
            // 那份多半已经不存在的静帧缓存。这里重新对一次，对不上的报出来重转。
            pendingStills = VideoEditProjectIO.refreshStillClips(in: &state)
        }
        missingMedia.removeAll { relinked[$0] != nil }

        // 定位表的键要跟着换成新路径，否则下次存盘按旧路径找不到旧记录，
        // 刚建立的书签又会丢。
        let projectDirectory = documentURL?.deletingLastPathComponent()
        for (old, new) in relinked {
            let previous = mediaRecords.removeValue(forKey: old.path)
            mediaRecords[new.path] = MediaRecord(
                url: new,
                projectDirectory: projectDirectory,
                previous: previous
            )
        }

        // 路径变了得赶紧记下来，别等下次打开又要重找一遍。
        hasUnsavedChanges = true
        flushAutosave()

        if !pendingStills.isEmpty {
            let generation = documentGeneration
            trackImportTask(Task {
                await regenerateStills(pendingStills, generation: generation)
            })
        }
    }

    // MARK: - 运行中的素材核对

    /// 工程开着的时候素材也会在访达里被改名、挪走。以前只有**打开工程**才跑
    /// 四层线索，运行中失踪只会让预览重建时静默跳过那段 —— 黑屏零提示，轨道
    /// 缩略图还是缓存的旧画面，看着一切正常。这里把同一套线索在运行中也跑：
    /// 跟得上的当场改引用（轨道块名字随 `sourceURL` 现算，立刻显示新名字），
    /// 跟不上的进 `missingMedia` 亮出重链接条。App 激活和每次预览重建各触发
    /// 一次；素材都在原地时就是每素材一次 fileExists 的开销。
    func revalidateMediaLocations() {
        guard mediaRevalidateTask == nil else { return }
        guard !state.isEmpty else {
            if !missingMedia.isEmpty { missingMedia = [] }
            return
        }
        let urls = state.mediaURLs
        let records = mediaRecords
        let projectDirectory = documentURL?.deletingLastPathComponent()
        let generation = documentGeneration
        mediaRevalidateTask = Task { [weak self] in
            // 四层线索可能要翻目录，跟 openProject 一样别占主线程。
            let outcome = await Task.detached(priority: .utility) {
                VideoEditProjectIO.relocateMedia(
                    urls: urls,
                    records: records,
                    projectDirectory: projectDirectory
                )
            }.value
            guard let self else { return }
            // 先放开单飞再落账：落账会触发重建 → 重建又触发核对，那次要能起飞，
            // 它会核出「全部原地命中」从而收敛，不会循环。
            self.mediaRevalidateTask = nil
            guard self.isCurrentGeneration(generation) else { return }
            self.applyMediaRelocation(moved: outcome.moved, missing: outcome.missing)
        }
    }

    /// 把核对结果落回工程。**await 回来的世界可能已经变了**（编辑没停、
    /// 甚至换了素材）：只对此刻仍被时间线引用的路径动手。
    private func applyMediaRelocation(moved: [URL: URL], missing: [URL]) {
        let current = Set(state.mediaURLs)
        let applicable = moved.filter { current.contains($0.key) }

        if !applicable.isEmpty {
            var pendingStills: [StillRegeneration] = []
            applyDocumentRepair { state in
                for (old, new) in applicable { state.replaceMedia(old, with: new) }
                // 找回来的要是图片，静帧缓存要重新对一次（同 promptRelink）。
                pendingStills = VideoEditProjectIO.refreshStillClips(in: &state)
            }
            // 定位表跟 promptRelink 同一套账：键换成新路径，旧记录当兜底。
            let projectDirectory = documentURL?.deletingLastPathComponent()
            for (old, new) in applicable {
                let previous = mediaRecords.removeValue(forKey: old.path)
                mediaRecords[new.path] = MediaRecord(
                    url: new,
                    projectDirectory: projectDirectory,
                    previous: previous
                )
            }
            // 路径变了立刻回存，跟打开工程时 didRelink 的处理一致。
            if documentURL != nil {
                hasUnsavedChanges = true
                flushAutosave()
            }
            if !pendingStills.isEmpty {
                let generation = documentGeneration
                trackImportTask(Task {
                    await regenerateStills(pendingStills, generation: generation)
                })
            }
        }

        // 丢失名单以本次核对为准：被挪回原位/找回来的自动消条。
        let stillMissing = missing.filter { current.contains($0) }
        if missingMedia != stillMissing { missingMedia = stillMissing }
    }
}

// MARK: - 最近打开

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
