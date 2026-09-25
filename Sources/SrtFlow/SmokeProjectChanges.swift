import Foundation
import Observation

// MARK: - 冒烟里数「工程的哪个属性变了几轮」
//
// 管：`perf` 快照里的 `event:project.changed.<属性>` —— 两次快照之间，工程的每个被观察的属性
// 各变了几轮。不管：别的计数（视图重算几次在 `PerfCounters`），也不管 CI 的性能测试（那边不数这个）。
//
// 工程是 `@Observable`（2026-09-25 起）：视图读了哪个属性，就只在那个属性变时重算。所以「谁在白白
// 叫醒大家」要看**哪个属性**变了：只改了 `selection`，读 `state` 的视图一个都不该动。换 Observation
// 之前这里数的是 `objectWillChange`（工程变一次、订阅工程的视图全部重算），那个数已经没有意义了。
//
// 每个属性各挂一份 `withObservationTracking`：变了记一笔，下一拍再挂回去 —— 同一拍里写几次只算
// 一轮，和 SwiftUI 一样（它一拍只重算一次）。值没变的写入不算（Observation 对能比较的类型不发通知）。

@MainActor
enum SmokeProjectChanges {
    /// 被观察的属性，一个不能少：漏了的那个变了也不记账，数就不可信。启动时拿 `Mirror` 核对
    /// （被观察的存储属性在 Mirror 里叫 `_名字`，`@ObservationIgnored` 的没有下划线）。
    static let watched: [(name: String, keyPath: PartialKeyPath<VideoEditProject>)] = [
        ("state", \.state), ("selection", \.selection), ("documentURL", \.documentURL),
        ("hasUnsavedChanges", \.hasUnsavedChanges), ("missingMedia", \.missingMedia),
        ("textEditingRequest", \.textEditingRequest), ("activeTool", \.activeTool),
        ("showsSubtitleList", \.showsSubtitleList), ("subtitleDraft", \.subtitleDraft),
        ("magnetEnabled", \.magnetEnabled), ("snappingEnabled", \.snappingEnabled),
        ("linkageEnabled", \.linkageEnabled), ("pixelsPerSecond", \.pixelsPerSecond),
        ("rowHeights", \.rowHeights), ("importingCount", \.importingCount), ("isFreezing", \.isFreezing),
        ("renderSize", \.renderSize), ("notice", \.notice), ("canvasEditGeneration", \.canvasEditGeneration),
    ]

    private static var counts: [String: Int] = [:]

    /// 冒烟开始时挂一次。清单和工程对不上就报错（整个脚本不跑，别拿一份漏数的结果去比）。
    static func start(_ project: VideoEditProject) throws {
        let observed = Set(Mirror(reflecting: project).children.compactMap { child -> String? in
            guard let label = child.label, label.hasPrefix("_"), !label.hasPrefix("_$") else { return nil }
            return String(label.dropFirst())
        })
        let listed = Set(watched.map(\.name))
        guard observed == listed else {
            throw SmokeScriptError(
                "SmokeProjectChanges.watched 和工程被观察的属性对不上：漏了 \(observed.subtracting(listed).sorted())，"
                    + "多了 \(listed.subtracting(observed).sorted())"
            )
        }
        for item in watched { watch(item.name, item.keyPath, in: project) }
    }

    static func reset() { counts = [:] }

    /// `perf` 快照里的那几项：只写变过的属性。
    static func snapshot() -> [String: Int] {
        Dictionary(uniqueKeysWithValues: counts.map { ("event:project.changed.\($0.key)", $0.value) })
    }

    private static func watch(_ name: String, _ keyPath: PartialKeyPath<VideoEditProject>, in project: VideoEditProject) {
        withObservationTracking {
            _ = project[keyPath: keyPath]
        } onChange: {
            // 在写入的那一刻（主线程上）同步调过来；挂回去要等这一拍写完。
            MainActor.assumeIsolated { counts[name, default: 0] += 1 }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { watch(name, keyPath, in: project) }
            }
        }
    }
}
