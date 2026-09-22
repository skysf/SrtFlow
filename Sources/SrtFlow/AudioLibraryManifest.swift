import Foundation

// R2 上那份音频库清单的数据合同。产品口径见
// docs/plans/2026-09-22-audio-library.md 第四节。
//
// 四条硬约束在这里落地，改之前先读那一节：
//
// 1. **只认 `url` 字段给出的完整地址，绝不在代码里拼路径。** 守住这条，以后从
//    公开域名换到 Worker 网关只是换一份 manifest，App 一行不动。
// 2. **`id` 稳定不变。** 工程文件存的就是它（`EditClip.remoteKey`），改了等于
//    所有老工程集体失链。
// 3. **tags 是数据不是界面文案**，双语对照就放在这份 JSON 里，不进
//    Localizable.strings —— tag 会随 manifest 增长，不该每加一个就发一次 App。
// 4. **`license` 必填。** 署名义务靠它驱动，漏一条就是漏一次署名。

/// 清单里的一条素材。
struct AudioLibraryItem: Identifiable, Hashable, Sendable {
    let id: String
    var kind: Kind
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var size: Int
    /// **完整地址**，不是路径片段（约束 1）。
    var url: URL
    var cover: URL?
    /// 实测响度（LUFS）。规格化的目标是 -16，但峰值顶住时到不了 —— 那是有意的
    /// （保动态优先），所以这里存的是**真值**，不是目标值。
    var loudness: Double?
    /// 响度没到目标是因为峰值顶住了。用于解释「这首为什么偏轻」。
    var peakLimited: Bool
    var hasVocals: Bool
    /// 1–5。
    var intensity: Int
    var tags: [AudioLibraryTag]
    var license: AudioLibraryLicense

    enum Kind: String, Sendable {
        case music, sfx
    }
}

/// 一个双语标签。`group` 用于分组显示（质感 / 情绪 / 场景）。
struct AudioLibraryTag: Hashable, Sendable {
    var zh: String
    var en: String
    var group: String

    /// 按当前界面语言显示哪一个。
    func label(chinese: Bool) -> String { chinese ? zh : en }

    /// 搜索：中英两边都匹配，大小写不敏感。用户会搜「悲伤」也会搜「sad」。
    func matches(_ needle: String) -> Bool {
        zh.localizedCaseInsensitiveContains(needle)
            || en.localizedCaseInsensitiveContains(needle)
    }
}

/// 署名信息。CC-BY 的强制义务，不是装饰。
struct AudioLibraryLicense: Hashable, Sendable {
    var code: String
    var by: String
    var src: URL?
    /// 现成的署名句，直接显示在署名页上。
    var text: String
}

/// 整份清单。
struct AudioLibraryManifest: Sendable {
    /// App 支持到的最高清单版本。读到更高的版本要**明确报错**，不能半解析。
    static let supportedVersion = 1

    var version: Int
    var kind: AudioLibraryItem.Kind
    var generatedAt: Date?
    var items: [AudioLibraryItem]
}

// MARK: - 解析

extension AudioLibraryManifest {
    enum ParseError: Error, LocalizedError, Equatable {
        /// 清单版本比这个 App 新。**不降级半解析** —— 新版本可能改了字段语义，
        /// 硬读出来的东西会以「能用」的样子出错，比直接说不认识更难查。
        case unsupportedVersion(found: Int, supported: Int)
        case notJSON
        case missingItems

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let found, let supported):
                return String(format: L10n("This audio library needs a newer version of the app (list format v%d, this app reads up to v%d)."), found, supported)
            case .notJSON, .missingItems:
                return L10n("The audio library list is damaged.")
            }
        }
    }

    /// 从 JSON 解析。
    ///
    /// **宽容的边界**：不认识的字段一律忽略（以后加字段不用动老 App），缺的可选
    /// 字段走默认值，**单条坏数据跳过而不是整份失败**（一首歌的 url 写错不该让
    /// 整个库打不开）。但版本号比自己新时**整份拒绝** —— 那不是"坏数据"，
    /// 是"这份清单不是给我读的"。
    static func parse(_ data: Data) throws -> AudioLibraryManifest {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.notJSON
        }
        let version = root["manifest_version"] as? Int ?? 0
        guard version <= supportedVersion else {
            throw ParseError.unsupportedVersion(found: version, supported: supportedVersion)
        }
        guard let rawItems = root["items"] as? [[String: Any]] else {
            throw ParseError.missingItems
        }
        let kind = AudioLibraryItem.Kind(rawValue: root["kind"] as? String ?? "") ?? .music
        return AudioLibraryManifest(
            version: version,
            kind: kind,
            generatedAt: (root["generated_at"] as? String).flatMap(Self.date(from:)),
            items: rawItems.compactMap { item(from: $0, fallbackKind: kind) }
        )
    }

    private static func item(from d: [String: Any], fallbackKind: AudioLibraryItem.Kind) -> AudioLibraryItem? {
        // 这四样缺一条这条就没法用：没 id 存不进工程，没 url 下不下来，
        // 没时长排不了版，没 license 不能合法分发。
        guard let id = d["id"] as? String, !id.isEmpty,
              let urlString = d["url"] as? String, let url = URL(string: urlString),
              let duration = d["duration"] as? Double, duration > 0,
              let license = license(from: d["license"] as? [String: Any])
        else { return nil }

        return AudioLibraryItem(
            id: id,
            kind: AudioLibraryItem.Kind(rawValue: d["kind"] as? String ?? "") ?? fallbackKind,
            title: (d["title"] as? String) ?? id,
            artist: (d["artist"] as? String) ?? "",
            album: (d["album"] as? String) ?? "",
            duration: duration,
            size: (d["size"] as? Int) ?? 0,
            url: url,
            cover: (d["cover"] as? String).flatMap(URL.init(string:)),
            loudness: d["loudness"] as? Double,
            peakLimited: (d["peak_limited"] as? Bool) ?? false,
            hasVocals: (d["has_vocals"] as? Bool) ?? false,
            intensity: min(5, max(1, (d["intensity"] as? Int) ?? 3)),
            tags: (d["tags"] as? [[String: Any]] ?? []).compactMap(tag(from:)),
            license: license
        )
    }

    private static func tag(from d: [String: Any]) -> AudioLibraryTag? {
        // 两边都得有：只有一边的话另一种语言下这个标签会变成空白。
        guard let zh = d["zh"] as? String, !zh.isEmpty,
              let en = d["en"] as? String, !en.isEmpty
        else { return nil }
        return AudioLibraryTag(zh: zh, en: en, group: (d["group"] as? String) ?? "")
    }

    private static func license(from d: [String: Any]?) -> AudioLibraryLicense? {
        guard let d, let code = d["code"] as? String, !code.isEmpty else { return nil }
        let by = (d["by"] as? String) ?? ""
        return AudioLibraryLicense(
            code: code,
            by: by,
            src: (d["src"] as? String).flatMap(URL.init(string:)),
            // 没给现成句子就拼一句，署名页上不能是空的。
            text: (d["text"] as? String) ?? "\(by) — \(code)"
        )
    }

    private static func date(from s: String) -> Date? {
        let f = ISO8601DateFormatter()
        return f.date(from: s)
    }
}

// MARK: - 搜索

extension AudioLibraryManifest {
    /// 按关键词过滤。
    ///
    /// 口径（plan 第十二节第 2 条）：**多个词之间是「与」** —— 搜「dark piano」
    /// 要的是既黑暗又有钢琴的，不是两者随便沾一个。每个词可以命中曲名、艺人、
    /// 或任意一个标签的任意一种语言。
    static func filter(_ items: [AudioLibraryItem], query: String) -> [AudioLibraryItem] {
        let needles = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !needles.isEmpty else { return items }
        return items.filter { item in
            needles.allSatisfy { needle in
                item.title.localizedCaseInsensitiveContains(needle)
                    || item.artist.localizedCaseInsensitiveContains(needle)
                    || item.tags.contains { $0.matches(needle) }
            }
        }
    }
}
