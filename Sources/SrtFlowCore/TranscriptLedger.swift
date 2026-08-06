import Foundation

// 转写缓存的区间账本（docs/plans/2026-08-06-native-subtitle-generation.md 11.2）。
//
// 缓存按素材存**源时间词流**，账本记「已分析过哪些源区间」——包括分析过但
// 没有语音的区间，避免反复重扫静音段。命中 = desired − covered 只补缺口；
// 素材指纹或转写配置变化整条失效。纯数据 + 纯函数，磁盘 IO 在 App 侧
// （TranscriptSidecarStore）。

/// 半开源时间区间 [start, end)，秒。
public struct SourceRange: Hashable, Sendable, Codable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    public var isEmpty: Bool { end <= start }
    public var duration: Double { max(0, end - start) }
}

public enum TranscriptLedger {

    /// 排序 + 合并（相接或几乎相接的并成一段；epsilon 吸掉浮点毛刺）。
    public static func normalize(_ ranges: [SourceRange], epsilon: Double = 0.001) -> [SourceRange] {
        let sorted = ranges.filter { !$0.isEmpty }.sorted { $0.start < $1.start }
        var merged: [SourceRange] = []
        for range in sorted {
            if var last = merged.last, range.start <= last.end + epsilon {
                last.end = max(last.end, range.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// 缺口 = desired − covered（两边都会先 normalize）。
    public static func gaps(desired: [SourceRange], covered: [SourceRange]) -> [SourceRange] {
        let want = normalize(desired)
        let have = normalize(covered)
        var result: [SourceRange] = []
        for range in want {
            var cursor = range.start
            for block in have where block.end > range.start && block.start < range.end {
                if block.start > cursor {
                    result.append(SourceRange(start: cursor, end: block.start))
                }
                cursor = max(cursor, block.end)
            }
            if cursor < range.end {
                result.append(SourceRange(start: cursor, end: range.end))
            }
        }
        return result.filter { !$0.isEmpty }
    }

    /// 缺口两侧加上下文 padding（识别边界句子更稳），再夹回素材范围并合并。
    public static func padded(
        _ gaps: [SourceRange], padding: Double, within bounds: SourceRange
    ) -> [SourceRange] {
        normalize(gaps.map {
            SourceRange(
                start: max(bounds.start, $0.start - padding),
                end: min(bounds.end, $0.end + padding)
            )
        })
    }

    /// 把大区间切成 ≤ maxDuration 的固定窗口 —— 长素材断点续跑的粒度：
    /// 每个窗口转写完立即入账落盘，中途取消/崩溃最多丢一个窗口。
    public static func windows(
        _ ranges: [SourceRange], maxDuration: Double
    ) -> [SourceRange] {
        guard maxDuration > 0 else { return normalize(ranges) }
        var result: [SourceRange] = []
        for range in normalize(ranges) {
            var cursor = range.start
            while cursor < range.end {
                let end = min(cursor + maxDuration, range.end)
                result.append(SourceRange(start: cursor, end: end))
                cursor = end
            }
        }
        return result
    }
}

/// 一个素材一条缓存（sidecar，紧凑 JSON，不进工程文件、不参与 formatVersion）。
public struct TranscriptCacheEntry: Codable, Sendable, Equatable {
    /// 缓存格式版本：不认识的直接作废重建（缓存可重建，不做迁移）。
    public var version: Int
    /// 素材指纹（路径+大小+时长，对齐 MediaRecord 线索），对不上整条失效。
    public var fingerprint: String
    public var localeIdentifier: String
    /// 转写模块与配置：换了模块/参数就失效。
    public var transcriber: String
    public var configVersion: Int
    /// 已分析的源区间（含无语音区间），normalize 后存。
    public var covered: [SourceRange]
    /// 源时间词流，只存 finalized 结果。
    public var words: [TimedWord]

    public static let currentVersion = 1

    public init(
        fingerprint: String,
        localeIdentifier: String,
        transcriber: String,
        configVersion: Int,
        covered: [SourceRange] = [],
        words: [TimedWord] = []
    ) {
        version = Self.currentVersion
        self.fingerprint = fingerprint
        self.localeIdentifier = localeIdentifier
        self.transcriber = transcriber
        self.configVersion = configVersion
        self.covered = covered
        self.words = words
    }

    /// 这条缓存还配不配当前请求用。
    public func matches(
        fingerprint: String, localeIdentifier: String, transcriber: String, configVersion: Int
    ) -> Bool {
        version == Self.currentVersion
            && self.fingerprint == fingerprint
            && self.localeIdentifier == localeIdentifier
            && self.transcriber == transcriber
            && self.configVersion == configVersion
    }

    /// 合并一段新转写：该区间内旧词（按中点判定）被新结果覆盖，按源时间排好。
    /// range 记入账本 —— **就算 newWords 为空也要记**（分析过、没有语音）。
    public mutating func merge(words newWords: [TimedWord], analyzed range: SourceRange) {
        words.removeAll { word in
            let mid = (word.start + word.end) / 2
            return mid >= range.start && mid < range.end
        }
        words.append(contentsOf: newWords)
        words.sort { $0.start < $1.start }
        covered = TranscriptLedger.normalize(covered + [range])
    }
}
