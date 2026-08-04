import Foundation

/// 一个 `.srtflowproj` 工程文件。
///
/// 就是一份几十 KB 的 JSON：只记时间线和「素材在哪」，素材本身一个都不拷贝。
/// 所以工程文件能随便放、随便改名、丢进 iCloud Drive 或 Time Machine，
/// 文件夹管理交给 Finder，App 里不再自建一套。
struct VideoEditProjectFile: Codable {
    /// 格式版本。**加了旧版会静默丢掉的新字段就要 +1** —— 版本闸门的意义
    /// 就是让旧版拒绝打开新工程，而不是打开后在下一次自动保存时把不认识的
    /// 字段悄悄删光（新版读旧版永远宽容，随便开）。
    /// 版本史：v1 首版；v2 自由摆放（placement）+ Transform
    /// （rotationDegrees/opacity/flip/crop）；v3 关键帧动画（animation）。
    var formatVersion: Int
    var savedAt: Date
    var timeline: TimelineState
    /// 时间线里每个素材路径配一份定位信息，素材被改名/移动后靠它找回来。
    var media: [MediaRecord]

    static let currentFormatVersion = 3
    static let fileExtension = "srtflowproj"

    private enum CodingKeys: String, CodingKey {
        case formatVersion, savedAt, timeline, media
    }

    init(timeline: TimelineState, media: [MediaRecord]) {
        formatVersion = Self.currentFormatVersion
        savedAt = Date()
        self.timeline = timeline
        self.media = media
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        savedAt = try c.decodeIfPresent(Date.self, forKey: .savedAt) ?? Date()
        timeline = try c.decode(TimelineState.self, forKey: .timeline)
        media = try c.decodeIfPresent([MediaRecord].self, forKey: .media) ?? []
    }
}

/// 一个素材的定位信息：存三种线索，从快到慢依次试。
struct MediaRecord: Codable, Sendable {
    /// 存盘时的绝对路径。素材没动过就直接命中，这是绝大多数情况。
    var path: String
    /// 系统书签：记的是文件的 inode + 卷标识，不是路径。素材改名、移到同一个盘
    /// 的任何角落，甚至又改名又移动，都能靠它解回来 —— 这是 macOS 自带的能力。
    var bookmark: Data?
    /// 相对工程文件的位置。整个文件夹（工程 + 素材）一起搬走或拷到别的机器时，
    /// 书签会失效（inode 变了），这条还在。
    var relativePath: String?
    /// 最后的线索：按文件名找，用大小验一下是不是同一个。
    var fileName: String
    var byteSize: Int64?

    private enum CodingKeys: String, CodingKey {
        case path, bookmark, relativePath, fileName, byteSize
    }

    /// - Parameter previous: 上次存盘时这个素材的记录。
    ///
    ///   **旧记录只能补，不能覆盖成 nil。** 素材此刻不可达时（在工程打开期间被
    ///   移走、外接盘拔了），`bookmarkData()` 会失败返回 nil；要是就这么存下去，
    ///   本来还能定位到它的那份书签就被自己抹掉了 —— 而且随便哪个素材触发一次
    ///   自动保存，就会连带抹掉**其他**丢失素材的线索。
    init(url: URL, projectDirectory: URL?, previous: MediaRecord? = nil) {
        path = url.path
        fileName = url.lastPathComponent
        let fresh = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        bookmark = fresh ?? previous?.bookmark
        // 相对路径纯粹是路径运算，文件在不在都算得出来，可以放心重算。
        relativePath = projectDirectory.flatMap { MediaRecord.relativePath(from: $0, to: url) }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
        byteSize = size ?? previous?.byteSize
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        bookmark = try c.decodeIfPresent(Data.self, forKey: .bookmark)
        relativePath = try c.decodeIfPresent(String.self, forKey: .relativePath)
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName)
            ?? (path as NSString).lastPathComponent
        byteSize = try c.decodeIfPresent(Int64.self, forKey: .byteSize)
    }

    var url: URL { URL(fileURLWithPath: path) }

    /// 从工程所在目录走到素材的相对路径。最多往上走三层 —— 再远就不像是
    /// 「一起搬走」的关系了，留着反而会误配到别的文件。
    static func relativePath(from directory: URL, to file: URL) -> String? {
        let base = directory.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let target = file.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        var shared = 0
        while shared < base.count, shared < target.count, base[shared] == target[shared] {
            shared += 1
        }
        let up = base.count - shared
        guard up <= 3 else { return nil }
        return (Array(repeating: "..", count: up) + target[shared...]).joined(separator: "/")
    }
}

// MARK: - 读写

enum VideoEditProjectIO {

    struct IOError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// 打开工程的结果。素材可能已经不在原地了，所以除了时间线还得报告找没找齐。
    struct LoadResult: Sendable {
        var timeline: TimelineState
        /// 四层都没找到的素材，界面上要标红并让用户手动重链接。
        var missingMedia: [URL]
        /// 有素材是靠书签/相对路径/搜名字找回来的 —— 路径变了，该重新存一次盘。
        var didRelink: Bool
        /// 静帧缓存没了、需要重新转的图片段。
        var stillsToRegenerate: [URL]
        /// 读到的素材定位表（键是**解析之后**的路径）。存盘时要拿它来兜底，
        /// 不然这次没找到的素材，书签会被下一次自动保存抹掉。
        var records: [String: MediaRecord]
    }

    // MARK: 存

    /// - Parameter knownRecords: 上次读/写时的定位表，键是素材路径。
    /// - Returns: 这次写下去的定位表，调用方要存着传给下一次。
    @discardableResult
    nonisolated static func save(
        _ timeline: TimelineState,
        to url: URL,
        knownRecords: [String: MediaRecord] = [:]
    ) throws -> [String: MediaRecord] {
        let directory = url.deletingLastPathComponent()
        let media = timeline.mediaURLs.map {
            MediaRecord(url: $0, projectDirectory: directory, previous: knownRecords[$0.path])
        }
        let file = VideoEditProjectFile(timeline: timeline, media: media)

        let encoder = JSONEncoder()
        // 存得可读：工程文件进了 git 或者要人肉看一眼时有用，几十 KB 不心疼。
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(file)
        // 原子写：中途崩了也不会把上一份好工程截断成半截。
        try data.write(to: url, options: .atomic)
        return Dictionary(media.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: 读

    /// 整次载入总共允许翻多少个文件条目。
    ///
    /// 这是**全局**预算，不是每个素材一份：丢了 20 个素材、又攒了 5 个已知目录时，
    /// 每素材一份预算意味着最坏 20 × 5 × 4000 次 stat，能把打开工程拖到卡死。
    private static let searchEntryBudget = 4000

    nonisolated static func load(from url: URL) throws -> LoadResult {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file: VideoEditProjectFile
        do {
            file = try decoder.decode(VideoEditProjectFile.self, from: data)
        } catch {
            throw IOError(message: String(
                format: L10n("“%@” isn’t a SrtFlow project file."),
                url.lastPathComponent
            ))
        }
        // 未来版本的工程可能有这版看不懂的语义。硬打开的话，自动保存会把不认识的
        // 字段**删掉**，等于悄悄毁掉用户在新版里做的活。
        guard file.formatVersion <= VideoEditProjectFile.currentFormatVersion else {
            throw IOError(message: String(
                format: L10n("“%@” was made by a newer version of SrtFlow."),
                url.lastPathComponent
            ))
        }

        var timeline = file.timeline
        let projectDirectory = url.deletingLastPathComponent()
        let stored = Dictionary(file.media.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var records: [String: MediaRecord] = [:]

        var missing: [URL] = []
        var didRelink = false
        // 已经找到的素材所在目录：后面找不到的素材优先去这些地方碰运气 ——
        // 素材通常整批一起搬，找到一个就等于找到一窝。
        var knownDirectories: [URL] = [projectDirectory]
        var budget = searchEntryBudget

        for original in timeline.mediaURLs {
            let record = stored[original.path] ?? MediaRecord(url: original, projectDirectory: nil)
            let outcome = resolve(
                record,
                projectDirectory: projectDirectory,
                knownDirectories: knownDirectories,
                budget: &budget
            )
            switch outcome {
            case .found(let resolved, let moved):
                if moved {
                    timeline.replaceMedia(original, with: resolved)
                    didRelink = true
                }
                records[resolved.path] = MediaRecord(
                    url: resolved,
                    projectDirectory: projectDirectory,
                    previous: record
                )
                let directory = resolved.deletingLastPathComponent()
                if !knownDirectories.contains(directory) { knownDirectories.append(directory) }
            case .missing:
                missing.append(original)
                // 找不到也要把旧记录留着 —— 那份书签是它唯一的线索。
                records[original.path] = record
            }
        }

        let stills = refreshStillClips(in: &timeline)
        return LoadResult(
            timeline: timeline,
            missingMedia: missing,
            didRelink: didRelink,
            stillsToRegenerate: stills,
            records: records
        )
    }

    // MARK: 素材定位

    private enum Resolution {
        /// 找到了。`moved` 表示位置跟存盘时不一样，时间线里的引用要跟着改。
        case found(URL, moved: Bool)
        case missing
    }

    /// 四层线索依次试，越靠前越快。
    private nonisolated static func resolve(
        _ record: MediaRecord,
        projectDirectory: URL,
        knownDirectories: [URL],
        budget: inout Int
    ) -> Resolution {
        let manager = FileManager.default

        // 1. 原地没动 —— 绝大多数情况在这里就返回了。
        if manager.fileExists(atPath: record.path) {
            return .found(record.url, moved: false)
        }

        // 2. 书签：改了名、换了文件夹都能跟过去（同一个卷）。
        if let bookmark = record.bookmark {
            var stale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), manager.fileExists(atPath: resolved.path) {
                return .found(resolved, moved: true)
            }
        }

        // 3. 相对工程文件的位置：工程和素材整个文件夹一起被搬走/拷到别的机器。
        if let relative = record.relativePath {
            let candidate = URL(
                fileURLWithPath: relative,
                relativeTo: projectDirectory
            ).standardizedFileURL
            if manager.fileExists(atPath: candidate.path) {
                return .found(candidate, moved: true)
            }
        }

        // 4. 按文件名在工程目录和已找到素材的目录里翻一层。
        //    外接盘换了挂载点、从备份恢复导致 inode 变了，就靠这条。
        for directory in knownDirectories where budget > 0 {
            if let hit = search(
                fileName: record.fileName,
                byteSize: record.byteSize,
                under: directory,
                budget: &budget
            ) {
                return .found(hit, moved: true)
            }
        }

        return .missing
    }

    /// 在一个目录下按名字找文件。往下最多翻 3 层，并且消耗整次载入共用的
    /// `budget` —— 打开工程不能因为有人把工程放在了下载文件夹而卡住。
    private nonisolated static func search(
        fileName: String,
        byteSize: Int64?,
        under directory: URL,
        budget: inout Int
    ) -> URL? {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        while let candidate = enumerator.nextObject() as? URL {
            budget -= 1
            if budget <= 0 { return nil }
            if enumerator.level > 3 {
                enumerator.skipDescendants()
                continue
            }
            guard candidate.lastPathComponent == fileName else { continue }
            let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            // 记了大小就验一下，别把同名的别的文件配上去。
            if let byteSize, let size = values?.fileSize, Int64(size) != byteSize { continue }
            return candidate
        }
        return nil
    }

    // MARK: 图片段

    /// 图片段在时间线上其实是一段生成出来的静帧视频，那个视频在缓存目录里，
    /// 随时可能被系统清掉。所以工程只认原图：打开时缓存还在就直接接上，
    /// 没了就报出来让 VideoEditProject 重新转一遍。
    ///
    /// 打开工程和**手动重链接图片**之后都要走一遍：重链接只换了 `stillImageURL`，
    /// `sourceURL` 还指着旧的（多半已经不存在的）缓存文件。
    @discardableResult
    nonisolated static func refreshStillClips(in timeline: inout TimelineState) -> [URL] {
        var needsRegeneration: [URL] = []

        func repair(_ clip: inout EditClip) {
            guard let image = clip.stillImageURL else { return }
            if let cached = StillImageClipFactory.cachedStillVideo(for: image) {
                clip.sourceURL = cached
                clip.needsStillConversion = false
            } else {
                clip.needsStillConversion = true
                if !needsRegeneration.contains(image) { needsRegeneration.append(image) }
            }
        }

        for index in timeline.mainClips.indices { repair(&timeline.mainClips[index]) }
        for lane in timeline.overlayTracks.indices {
            for index in timeline.overlayTracks[lane].clips.indices {
                repair(&timeline.overlayTracks[lane].clips[index])
            }
        }
        for lane in timeline.audioTracks.indices {
            for index in timeline.audioTracks[lane].clips.indices {
                repair(&timeline.audioTracks[lane].clips[index])
            }
        }
        return needsRegeneration
    }
}
