import CoreGraphics
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
    /// （rotationDegrees/opacity/flip/crop）；v3 关键帧动画（animation）；
    /// v4 关联字幕 companion（译文轨/cueMeta，**按需写入**）；
    /// v5 工程帧率（frameRate，**无条件**写入）；
    /// v6 字幕轨的工程级布局与可见性（subtitleLayout / subtitleHidden）；
    /// v7 译文轨的眼睛（translationHidden）—— 一个语言一条轨、烧录跟着眼睛走；
    /// v8 轨道块上的标记（EditClip.markers，**按需写入**）。
    var formatVersion: Int
    var savedAt: Date
    var timeline: TimelineState
    /// 时间线里每个素材路径配一份定位信息，素材被改名/移动后靠它找回来。
    var media: [MediaRecord]

    /// reader 认识的最高版本（闸门比较对象）。
    static let latestFormatVersion = 8
    /// writer 的基线版本：没有任何高版本 only 数据的工程一律写它，旧版照常能开。
    /// 具体判据见 `TimelineState.requiresFormatVersion4` / `...5` / `...6` /
    /// `...7` / `...8`（登记清单在那边）。
    static let baselineFormatVersion = 3
    static let fileExtension = "srtflowproj"

    private enum CodingKeys: String, CodingKey {
        case formatVersion, savedAt, timeline, media
    }

    init(timeline: TimelineState, media: [MediaRecord]) {
        // 定版：帧率是无条件的 v5 数据（每个工程都有帧率，且旧版会按 30 硬编码
        // 渲染），所以**新版 writer 一律写 latest**，不再降级。
        // 「按需定版」这个机制对 v4/v6 仍然成立，但已被 v5 的无条件要求覆盖 ——
        // 保留判据只为登记清单的可读性。
        _ = timeline.requiresFormatVersion4
        _ = timeline.requiresFormatVersion6
        _ = timeline.requiresFormatVersion7
        _ = timeline.requiresFormatVersion8
        formatVersion = Self.latestFormatVersion
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
        /// 静帧缓存没了、需要重新转的图片段（带当初用的分辨率政策）。
        var stillsToRegenerate: [StillRegeneration]
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
        guard file.formatVersion <= VideoEditProjectFile.latestFormatVersion else {
            throw IOError(message: String(
                format: L10n("“%@” was made by a newer version of SrtFlow."),
                url.lastPathComponent
            ))
        }

        var timeline = file.timeline
        // v6 及更早没有「译文轨的眼睛」：那些版本的默认预览/烧录是**只有原文**
        // （预览轨选择是运行时状态、默认 .original；烧录默认 Original text）。
        // 缺键回退 false 会让升级把这些工程的成片悄悄变成双语 —— 所以按版本
        // 显式迁移成「译文轨隐藏」，保住旧文件当初渲染出来的样子。
        // 用户之后点一下眼睛就能把译文放出来，那是他的显式选择。
        if file.formatVersion < 7 {
            timeline.translationHidden = true
        }
        // 关联字幕（v4）：译文/cueMeta 必须锚在现有原文 cue 上，坏数据当场清掉。
        timeline.normalizeSubtitleCompanion()
        // 老版本存盘的主轨数组可能乱序（磁吸关掉的拖动不重排），打开时治好。
        timeline.sortMainClipsByStart()
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

    /// 运行中重核对一批素材（App 激活、预览重建时调）：跟打开工程完全同一套
    /// 四层线索。找回来的以「旧 → 新」报告，四层都翻不到的进 missing，
    /// 原地没动的两边都不出现。纯函数，只读文件系统，不碰任何共享状态。
    nonisolated static func relocateMedia(
        urls: [URL],
        records: [String: MediaRecord],
        projectDirectory: URL?
    ) -> (moved: [URL: URL], missing: [URL]) {
        var moved: [URL: URL] = [:]
        var missing: [URL] = []
        var knownDirectories = [projectDirectory].compactMap { $0 }
        var budget = searchEntryBudget
        for original in urls {
            // 没存过盘的素材没有记录（书签在存盘时才建），退化成只查原路径。
            let record = records[original.path] ?? MediaRecord(url: original, projectDirectory: nil)
            switch resolve(
                record,
                projectDirectory: projectDirectory,
                knownDirectories: knownDirectories,
                budget: &budget
            ) {
            case .found(let resolved, let didMove):
                if didMove { moved[original] = resolved }
                let directory = resolved.deletingLastPathComponent()
                if !knownDirectories.contains(directory) { knownDirectories.append(directory) }
            case .missing:
                missing.append(original)
            }
        }
        return (moved, missing)
    }

    /// 四层线索依次试，越靠前越快。
    private nonisolated static func resolve(
        _ record: MediaRecord,
        projectDirectory: URL?,
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
        //    未命名工程连位置都还没有，这层和第 4 层的「工程目录」线索自然缺席。
        if let relative = record.relativePath, let projectDirectory {
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
    nonisolated static func refreshStillClips(in timeline: inout TimelineState) -> [StillRegeneration] {
        var needsRegeneration: [StillRegeneration] = []

        func repair(_ clip: inout EditClip) {
            guard let image = clip.stillImageURL else { return }
            // 这一段当初按哪条分辨率政策转的，从存进工程文件的静帧尺寸反推。
            // 查缓存和重转都必须带上它，否则同一张 PNG 被两种政策共用时会串线
            // （定格段被悄悄降成 1080p，或者照片段拿到原生版本）。
            let native = StillImageClipFactory.needsNativeResolution(for: clip.info?.displaySize)
            if let cached = StillImageClipFactory.cachedStillVideo(for: image, nativeResolution: native) {
                clip.sourceURL = cached
                clip.needsStillConversion = false
            } else {
                clip.needsStillConversion = true
                let request = StillRegeneration(image: image, nativeResolution: native)
                if !needsRegeneration.contains(request) { needsRegeneration.append(request) }
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

    /// 把转好的静帧视频接到引用这张原图、**且政策一致**的段上。
    ///
    /// 政策过滤是重点：同一张 PNG 可能既被定格段（原生）又被普通图片段
    /// （照片政策）引用，两项任务各转各的。不过滤的话，后跑完的那项会把
    /// **所有**引用改成自己的产物，另一半就拿到了错误分辨率的静帧，
    /// 连 `info.displaySize` 都跟着对不上。
    nonisolated static func attachStill(
        _ video: URL,
        forImage image: URL,
        nativeResolution: Bool,
        in timeline: inout TimelineState
    ) {
        for clip in timeline.allClips
        where clip.stillImageURL == image
            && StillImageClipFactory.needsNativeResolution(for: clip.info?.displaySize) == nativeResolution {
            timeline.update(clip.id) { pending in
                pending.sourceURL = video
                pending.needsStillConversion = false
            }
        }
    }
}

/// 需要重新转的一个图片段：原图 + 当初用的分辨率政策。
///
/// **政策是键的一部分**：同一张 PNG 可能同时被定格段（原生）和普通图片段
/// （照片政策）引用，那就是两项各转各的任务，落地时也只更新同政策的段。
struct StillRegeneration: Hashable, Sendable {
    var image: URL
    var nativeResolution: Bool
}
