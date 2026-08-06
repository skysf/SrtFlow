import CryptoKit
import Foundation
import SrtFlowCore

// 词级转写缓存的磁盘仓（docs/plans/…… 第 11 节）。
//
// 位置：~/Library/Caches/SrtFlow/Transcripts/（系统视为可重建缓存）；
// 形态：紧凑 JSON（非 pretty），每素材一个文件，键名 = 指纹哈希；
// 纪律：原子写、读回校验（版本/指纹不合直接作废）、容量上限 LRU 清理、
// 丢失/损坏一律安全退化为重新转写 ——「文件存在 ≠ 文件可用」。

enum TranscriptSidecarStore {

    /// 缓存总量上限。词流是文本级体积（1–3MB/小时），64MB 够存几十部片。
    static let capacityBytes: Int64 = 64 * 1024 * 1024

    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SrtFlow/Transcripts", isDirectory: true)
    }

    /// 素材指纹：路径 + 大小 + 时长（对齐 MediaRecord 的定位线索）。
    /// 探测信息拿不到时（纯音频 clip 的 info 为 nil）回退到磁盘实测大小与
    /// mtime —— 决不允许「同路径换了文件还命中旧缓存」。
    static func fingerprint(
        forFileAt url: URL, knownBytes: Int64?, knownDuration: Double?
    ) -> String {
        var bytes = knownBytes
        var third = knownDuration.map { "\(Int($0 * 1000))" }
        if bytes == nil || third == nil {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            if bytes == nil {
                bytes = (attributes?[.size] as? NSNumber)?.int64Value
            }
            if third == nil, let date = attributes?[.modificationDate] as? Date {
                third = "m\(Int(date.timeIntervalSince1970))"
            }
        }
        return "\(url.path)|\(bytes ?? -1)|\(third ?? "-")"
    }

    private static func fileURL(for fingerprint: String) -> URL {
        let digest = SHA256.hash(data: Data(fingerprint.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(digest).json")
    }

    /// 落盘信封：payload 是条目的 JSON 字节，checksum 是它的 SHA256 ——
    /// 「文件存在 ≠ 文件可用」，半截/被改的文件在这里就地作废。
    private struct Envelope: Codable {
        var checksum: String
        var payload: Data
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 读缓存：任何一步不对（缺文件/解不开/校验和不符/版本或指纹配置不合）
    /// 都返回 nil，由调用方重新转写 —— 缓存丢失永远安全。
    /// 命中会 touch mtime，让容量清理成为真 LRU（按最近使用淘汰）。
    static func load(
        fingerprint: String, localeIdentifier: String, transcriber: String, configVersion: Int
    ) -> TranscriptCacheEntry? {
        let url = fileURL(for: fingerprint)
        guard let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              sha256Hex(envelope.payload) == envelope.checksum,
              let entry = try? JSONDecoder().decode(TranscriptCacheEntry.self, from: envelope.payload),
              entry.matches(
                  fingerprint: fingerprint, localeIdentifier: localeIdentifier,
                  transcriber: transcriber, configVersion: configVersion
              )
        else { return nil }
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: url.path
        )
        return entry
    }

    /// 原子写盘（紧凑编码 + 校验和信封），随手做一次容量清理。写失败不抛——
    /// 缓存写不进只影响下次要重转，不值得中断生成任务。
    static func save(_ entry: TranscriptCacheEntry) {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let payload = try JSONEncoder().encode(entry)
            let envelope = Envelope(checksum: sha256Hex(payload), payload: payload)
            let data = try JSONEncoder().encode(envelope)
            try data.write(to: fileURL(for: entry.fingerprint), options: .atomic)
        } catch {
            return
        }
        enforceCapacity()
    }

    static func remove(fingerprint: String) {
        try? FileManager.default.removeItem(at: fileURL(for: fingerprint))
    }

    /// LRU：超容量时从最久未碰的开始删。
    static func enforceCapacity(limit: Int64 = capacityBytes) {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return }
        var entries: [(url: URL, date: Date, size: Int64)] = files.compactMap { url in
            guard let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey]
            ) else { return nil }
            return (url, values.contentModificationDate ?? .distantPast,
                    Int64(values.fileSize ?? 0))
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > limit else { return }
        entries.sort { $0.date < $1.date }
        for entry in entries where total > limit {
            try? manager.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}
