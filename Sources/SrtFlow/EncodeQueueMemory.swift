import Foundation
import SrtFlowCore

// MARK: - 压缩 / 烧录两页记住的设置：存在哪、什么时候读回来
//
// 管什么：两个编码队列的编码设置、字幕样式、「再挂一条可开关的字幕轨」存在 UserDefaults 的哪个键，
// 以及**队列一被创建就读回来**（`EncodeQueue.init`）。以前只在打开那一页时读：直接进剪辑页的用户，
// 字幕预览、导出和 AI 用的都是默认样式，要先去烧录页转一圈才换成自己存的那套
// （docs/bugfixes/2026-09-27-remembered-subtitle-style-waits-for-burn-in-page.md）。
// 不管什么：什么时候写（两页各自在改动时写，键从这里拿）、设置本身的含义（SrtFlowCore）。
//
// 读回来只有这一处（`checks/encode-settings-memory.sh` 钉着：别处不许自己解码这几样）。

enum EncodeQueueMemory {
    /// 一个队列记住的几样东西的键。没有的那样是 nil。
    struct Keys: Sendable {
        var settings: String
        var style: String?
        var softTrack: String?
    }

    static let burnInStyleKey = "burnInStyle"
    static let burnInSoftTrackKey = "burnInSoftTrack"
    static let compress = Keys(settings: "compressSettings")
    static let burnIn = Keys(settings: "burnInSettings", style: burnInStyleKey, softTrack: burnInSoftTrackKey)

    /// 把记住的读进队列。没存过、存的读不懂的那一样保持默认。
    @MainActor
    static func restore(_ queue: EncodeQueue, _ keys: Keys, from defaults: UserDefaults = .standard) {
        if let settings = decode(VideoEncodeSettings.self, defaults.string(forKey: keys.settings)) {
            queue.settings = settings
        }
        if let key = keys.style, let style = decode(BurnInStyle.self, defaults.string(forKey: key)) {
            queue.burnInStyle = style
        }
        if let key = keys.softTrack {
            queue.attachSoftSubtitleTrack = defaults.bool(forKey: key)
        }
    }

    /// 用户存过自己的字幕样式没有（烧录页第一次用时据此挑一个有中文字形的默认字体）。
    static func hasRememberedStyle(from defaults: UserDefaults = .standard) -> Bool {
        decode(BurnInStyle.self, defaults.string(forKey: burnInStyleKey)) != nil
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ stored: String?) -> T? {
        guard let stored, !stored.isEmpty else { return nil }
        return try? JSONDecoder().decode(type, from: Data(stored.utf8))
    }
}
