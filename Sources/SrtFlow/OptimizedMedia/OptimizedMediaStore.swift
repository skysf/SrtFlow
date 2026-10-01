import CryptoKit
import Darwin
import Foundation

// MARK: - 优化媒体的缓存：按源文件的身份存块、记索引、超过上限丢最久没用的
//
// 管什么：`~/Library/Caches/SrtFlow/OptimizedMedia/<源身份的哈希>/chunk-<i>.mov` + 同目录一份 `index.json`
// （源的路径、身份、参数版本、每块最后用到的时间和大小）；总量上限；源换了文件 / 原地改写过、参数版本变了就作废。
// 不管什么：块怎么转（OptimizedMediaTranscoder）、要不要转（OptimizedMediaPolicy）、怎么换进预览（builder，V2）。
//
// 身份的认法和 `MediaAssetCache` 一样：路径 + inode + 卷 + 大小 + 修改时间（纳秒）。改转码参数就 +1 `parametersVersion`，
// 老块全部作废。索引坏了、块文件不在了都当没转过（缓存丢了就重转，不是错误）。
// 文件操作都是同步的小 IO，调用方在后台队列或主线程上调都行（索引文件几 KB）。

enum OptimizedMediaStore {
    /// 转码参数的版本：改关键帧间隔、码率、尺寸规则、编码器都要 +1。
    static let parametersVersion = 1
    static let capacityDefaultsKey = "optimizedMedia.capacityBytes"
    static let defaultCapacityBytes: Int64 = 10 * 1024 * 1024 * 1024

    /// 总量上限（设置里可改）。
    static var capacityBytes: Int64 {
        let value = UserDefaults.standard.object(forKey: capacityDefaultsKey) as? Int64
        return value.map { max(256 * 1024 * 1024, $0) } ?? defaultCapacityBytes
    }

    /// 源文件的身份（同 MediaAssetCache 的认法）。
    struct SourceIdentity: Codable, Equatable {
        var path: String
        var inode: UInt64
        var device: Int32
        var size: Int64
        var modifiedSeconds: Int
        var modifiedNanoseconds: Int

        init?(url: URL) {
            var info = stat()
            guard stat(url.path, &info) == 0 else { return nil }
            path = url.path
            inode = UInt64(info.st_ino)
            device = info.st_dev
            size = Int64(info.st_size)
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
        }

        /// 目录名：**路径**的哈希（同一个文件复制到两处是两份缓存）。身份的其余部分记在索引里：路径上换了文件、
        /// 原地改写过，索引对不上，整个目录作废重来 —— 目录按路径找才找得到要作废的那一份。
        var key: String {
            SHA256.hash(data: Data(path.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        }
    }

    struct ChunkRecord: Codable, Equatable {
        var fileName: String
        var bytes: Int64
        var lastUsed: Date
    }

    struct Index: Codable, Equatable {
        var parametersVersion: Int
        var identity: SourceIdentity
        var chunks: [Int: ChunkRecord] = [:]
    }

    static var root: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SrtFlow/OptimizedMedia", isDirectory: true)
    }

    /// 自检用：把缓存根换到别处（默认 `~/Library/Caches/SrtFlow/OptimizedMedia`）。
    nonisolated(unsafe) static var rootOverride: URL?
    static var effectiveRoot: URL { rootOverride ?? root }

    static func directory(for identity: SourceIdentity) -> URL {
        effectiveRoot.appendingPathComponent(identity.key, isDirectory: true)
    }

    static func chunkFileName(_ index: Int) -> String { "chunk-\(index).mov" }

    // MARK: 读

    /// 这个源的索引（身份对得上、版本对得上才算；不然当没转过，旧目录顺手删掉）。
    static func index(for url: URL) -> Index? {
        guard let identity = SourceIdentity(url: url) else { return nil }
        let file = directory(for: identity).appendingPathComponent("index.json")
        guard let data = try? Data(contentsOf: file),
              let index = try? JSONDecoder().decode(Index.self, from: data) else { return nil }
        guard index.parametersVersion == parametersVersion, index.identity == identity else {
            try? FileManager.default.removeItem(at: directory(for: identity))
            return nil
        }
        return index
    }

    /// 第 `chunk` 块转好了吗：索引里有、文件也在才算。
    static func chunkURL(for url: URL, chunk: Int) -> URL? {
        guard let identity = SourceIdentity(url: url), let index = index(for: url),
              let record = index.chunks[chunk] else { return nil }
        let file = directory(for: identity).appendingPathComponent(record.fileName)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// 用到了这些块：最后用到的时间改成现在（LRU 的依据）。
    static func touch(_ url: URL, chunks: [Int], now: Date = Date()) {
        guard var index = index(for: url) else { return }
        for chunk in chunks where index.chunks[chunk] != nil { index.chunks[chunk]?.lastUsed = now }
        save(index)
    }

    // MARK: 写

    /// 转码落盘的临时文件放哪（同一目录，最后原子改名）。
    static func temporaryURL(for identity: SourceIdentity) -> URL {
        let directory = directory(for: identity)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("tmp-\(UUID().uuidString).mov")
    }

    /// 一块转好了：从临时文件原子改名成正式的块、记进索引、超了上限就丢最久没用的。
    @discardableResult
    static func commit(chunk: Int, temporary: URL, for identity: SourceIdentity, now: Date = Date()) throws -> URL {
        let directory = directory(for: identity)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(chunkFileName(chunk))
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? Int64 ?? 0
        var index = loadIndex(identity) ?? Index(parametersVersion: parametersVersion, identity: identity)
        index.chunks[chunk] = ChunkRecord(fileName: chunkFileName(chunk), bytes: bytes, lastUsed: now)
        save(index)
        enforceCapacity(limit: capacityBytes, now: now)
        return destination
    }

    private static func loadIndex(_ identity: SourceIdentity) -> Index? {
        let file = directory(for: identity).appendingPathComponent("index.json")
        guard let data = try? Data(contentsOf: file),
              let index = try? JSONDecoder().decode(Index.self, from: data),
              index.parametersVersion == parametersVersion, index.identity == identity else { return nil }
        return index
    }

    private static func save(_ index: Index) {
        let directory = directory(for: index.identity)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(index) else { return }
        try? data.write(to: directory.appendingPathComponent("index.json"), options: .atomic)
    }

    // MARK: 总量

    /// 所有源的所有块一共多少字节（按索引算）。
    static func totalBytes() -> Int64 {
        allIndexes().reduce(0) { $0 + $1.chunks.values.reduce(0) { $0 + $1.bytes } }
    }

    /// 超过 `limit` 就按「最后用到的时间」从最早的开始丢，直到够；空了的源目录一起删。
    static func enforceCapacity(limit: Int64, now: Date = Date()) {
        var indexes = allIndexes()
        var total = indexes.reduce(0) { $0 + $1.chunks.values.reduce(0) { $0 + $1.bytes } }
        guard total > limit else { return }
        var entries: [(indexPosition: Int, chunk: Int, record: ChunkRecord)] = []
        for (position, index) in indexes.enumerated() {
            for (chunk, record) in index.chunks { entries.append((position, chunk, record)) }
        }
        entries.sort { $0.record.lastUsed < $1.record.lastUsed }
        for entry in entries where total > limit {
            let directory = directory(for: indexes[entry.indexPosition].identity)
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.record.fileName))
            indexes[entry.indexPosition].chunks[entry.chunk] = nil
            total -= entry.record.bytes
        }
        for index in indexes {
            if index.chunks.isEmpty {
                try? FileManager.default.removeItem(at: directory(for: index.identity))
            } else {
                save(index)
            }
        }
    }

    /// 超过 `days` 天没有任何工程用到的块删掉（启动时在后台扫一遍）。
    static func expire(olderThan days: Double, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-days * 86_400)
        for var index in allIndexes() {
            let stale = index.chunks.filter { $0.value.lastUsed < cutoff }
            guard !stale.isEmpty else { continue }
            let directory = directory(for: index.identity)
            for (chunk, record) in stale {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(record.fileName))
                index.chunks[chunk] = nil
            }
            if index.chunks.isEmpty {
                try? FileManager.default.removeItem(at: directory)
            } else {
                save(index)
            }
        }
    }

    /// 全部清空（设置里的「清空」）。
    static func removeAll() {
        try? FileManager.default.removeItem(at: effectiveRoot)
    }

    private static func allIndexes() -> [Index] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: effectiveRoot.path) else { return [] }
        return names.compactMap { name in
            let file = effectiveRoot.appendingPathComponent(name).appendingPathComponent("index.json")
            guard let data = try? Data(contentsOf: file),
                  let index = try? JSONDecoder().decode(Index.self, from: data),
                  index.identity.key == name else { return nil }
            return index
        }
    }
}
