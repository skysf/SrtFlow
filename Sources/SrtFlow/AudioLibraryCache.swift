import Foundation

// 音频库素材的本地缓存。产品口径见
// docs/plans/2026-09-22-audio-library.md 第二、六节。
//
// 两条分工，别混：
//
// - **试听走流播**，`AVPlayer` 直接吃 `item.url`，一个字节都不落盘。翻库因此是
//   零下载零占空间的 —— 用户听十首只为挑一首，没道理先把十首都存下来。
// - **拖进时间线才下载**。那一刻这条素材要进工程文件、要参与导出，必须有本地
//   文件（`AVAsset` 对远程 URL 能播但导出不可靠，而且断网就全毁）。
//
// 缓存落 `Application Support` 而不是 `Caches`：系统会在磁盘紧张时清掉后者，
// 而用户的工程正引用着这些文件 —— 被清掉就是「素材丢失」，而他会觉得
// 「这是 App 自带的音乐，怎么会丢」。代价是得自己给一个清理入口。

@MainActor
final class AudioLibraryCache: ObservableObject {
    static let shared = AudioLibraryCache()

    /// 已经在本地的素材 id。
    @Published private(set) var cachedIDs: Set<String> = []
    /// 正在下的：id → 0…1。
    @Published private(set) var progress: [String: Double] = [:]

    private var tasks: [String: Task<URL, Error>] = [:]
    private let fm = FileManager.default

    init() { refresh() }

    // MARK: - 位置

    /// `~/Library/Application Support/SrtFlow/AudioLibrary/`
    ///
    /// **nonisolated**：打开工程时的素材重链接是个不碰共享状态的纯函数
    /// （`VideoEditProjectFile.load`），它要在主 actor 之外算出「这条 remoteKey
    /// 的文件在不在本地」。路径纯粹是拼字符串，没有状态可争。
    nonisolated static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SrtFlow/AudioLibrary", isDirectory: true)
    }

    var directory: URL { Self.directory }

    /// 这条素材在本地的落点。
    ///
    /// **文件名必须消毒。** `id` 来自 R2 上的 manifest —— 那是远程数据，不是我们
    /// 代码里的常量。一个写着 `../../../etc/something` 的 id 会让下载把文件写到
    /// 缓存目录外面去。这里只保留字母数字、下划线和短横，其余一律换成下划线。
    nonisolated static func fileURL(for id: String) -> URL {
        let safe = String(id.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" })
        // 全被过滤光、或者只剩点号的情况下用哈希兜底，绝不允许拼出空名字。
        let name = safe.isEmpty ? String(abs(id.hashValue)) : safe
        return directory.appendingPathComponent(name).appendingPathExtension("m4a")
    }

    /// 已下载才返回；没下过返回 nil（调用方据此决定要不要下）。
    nonisolated static func localURL(for id: String) -> URL? {
        let url = fileURL(for: id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func fileURL(for id: String) -> URL { Self.fileURL(for: id) }

    func localURL(for id: String) -> URL? { Self.localURL(for: id) }

    // MARK: - 下载

    /// 下载并落盘，返回本地 URL。已经在本地就直接返回，不重复下。
    ///
    /// 同一条素材重复调用共用同一个任务 —— 用户连点两下不该下两遍。
    func download(_ item: AudioLibraryItem) async throws -> URL {
        if let have = localURL(for: item.id) { return have }
        if let running = tasks[item.id] { return try await running.value }

        let task = Task<URL, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            let dest = await self.fileURL(for: item.id)
            try await self.ensureDirectory()

            let (tmp, response) = try await URLSession.shared.download(from: item.url)
            // 下完立刻搬走：URLSession 给的临时文件在闭包返回后就会被清掉。
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                try? FileManager.default.removeItem(at: tmp)
                throw DownloadError.http(http.statusCode)
            }
            // 原子替换：半截文件绝不能以正式名字出现，否则下次打开会当成
            // 「已缓存」直接拿去用，用户听到的是半首歌或者一段噪音。
            let staging = dest.appendingPathExtension("part")
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.moveItem(at: tmp, to: staging)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: staging, to: dest)
            return dest
        }
        tasks[item.id] = task
        progress[item.id] = 0
        defer {
            tasks[item.id] = nil
            progress[item.id] = nil
        }
        do {
            let url = try await task.value
            cachedIDs.insert(item.id)
            return url
        } catch {
            // 失败要把残留清掉，别留下会被误认成「已缓存」的碎片。
            try? fm.removeItem(at: fileURL(for: item.id).appendingPathExtension("part"))
            throw error
        }
    }

    func cancel(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        progress[id] = nil
    }

    var isDownloading: Bool { !tasks.isEmpty }

    func isDownloading(_ id: String) -> Bool { tasks[id] != nil }

    // MARK: - 清理

    /// 缓存占了多少字节。
    var totalSize: Int64 {
        guard let items = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return items.reduce(0) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// 清空已下载的素材。
    ///
    /// **正在被工程引用的也会被清掉** —— 这是有意的：清理入口的意思就是"腾空间"。
    /// 之后重新打开那些工程，`remoteKey` 会把它们按 id 重新拉回来
    /// （见 video-edit-project-file.md 的重链接线索），所以不会真的丢。
    func clearAll() throws {
        for url in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: url)
        }
        refresh()
    }

    func refresh() {
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        cachedIDs = Set(names.filter { $0.hasSuffix(".m4a") }.map { String($0.dropLast(4)) })
    }

    private func ensureDirectory() throws {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    enum DownloadError: Error, LocalizedError {
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .http(let code):
                return String(format: L10n("Could not download this track (server said %d)."), code)
            }
        }
    }
}
