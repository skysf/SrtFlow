import Foundation

// MARK: - 剪辑页上记住的开关
//
// 管什么：工具栏的磁吸 / 吸附 / 联动 / 播放跟随，和字幕列表的「播放时滚到正在说的那句」——
// 每个开关的键、默认值、怎么读回来、怎么记下去。记在 UserDefaults（全 App 一份，不进工程文件），
// 2026-10-01 用户拍板：四个工具栏开关一起记住、字幕列表那个也记，新加的「播放跟随」默认关。
// 不管什么：拨了之后做什么（磁吸合拢主轨在 VideoEditProject、翻页在 TimelinePlayheadLines、
// 字幕列表的滚动在 VideoEditSubtitlePanel）。
//
// 冒烟 / 性能场景起手用默认值：它们起的是真 App，记住的开关会把这台机器上次拨的状态带进来，
// 场景就不是固定的了。性能测试或冒烟脚本开着时（`PerfCounters.isEnabled`）读永远给默认值、
// 写不落盘 —— 规矩见 docs/architecture/editor-remembered-toggles.md。
//
// 不 import AppKit：scripts/check-timeline-zoom.sh 单独编它。

enum EditorToggles {
    enum Key: String, CaseIterable {
        /// 主轨磁吸（自动合拢空档）。默认关：这个用户的剪法就是留着间隙（2026-09-18 拍板）。
        case magnet = "magnetEnabled"
        /// 拖动时吸附。默认开：只在边缘附近帮忙对齐，不改任何自动行为。
        case snapping = "snappingEnabled"
        /// 联动：压在主轨块上的东西（上层轨 / 音频轨的段、文字、形状、滤镜、字幕句）跟着它挪、跟着它删，分离出来的音频照旧
        /// 跟着视频走。默认开（2026-10-02，同剪映）：没有它，剪掉一段之后后面的字幕、音效全错位；拖音频本身永远只动音频，
        /// 所以「分离音频是为了单独动它」照样成立（docs/architecture/timeline-linkage.md）。
        case linkage = "linkageEnabled"
        /// 播放时时间线跟着播放头翻页。默认关：播放时轨道区域停在哪就停在哪（2026-10-01 拍板）。
        case followPlayhead = "timelineFollowsPlayhead"
        /// 剪辑页的字幕列表播放时滚到正在说的那句。默认关（同一天拍板；烧录页的那个不归这里管）。
        case subtitleListFollows = "subtitleListFollowsPlayback"

        /// 每次启动、没记过时的值 —— 这几行就是产品口径本身，守卫钉着
        /// （checks/timeline-drag-wiring/toggles.sh）。
        var defaultValue: Bool {
            switch self {
            case .magnet: false
            case .snapping: true
            case .linkage: true
            case .followPlayhead: false
            case .subtitleListFollows: false
            }
        }
    }

    /// 记在哪：平时是 `UserDefaults.standard`；脚本驱动（性能测试 / 冒烟）时是 nil —— 读给默认值、写丢掉。
    static var store: UserDefaults? { store(scripted: PerfCounters.isEnabled) }

    static func store(scripted: Bool) -> UserDefaults? { scripted ? nil : .standard }

    static func read(_ key: Key) -> Bool { read(key, from: store) }

    static func write(_ key: Key, _ value: Bool) { write(key, value, to: store) }

    /// 没记过、或记的不是布尔 → 默认值；没有地方可记（nil）→ 永远默认值。
    static func read(_ key: Key, from store: UserDefaults?) -> Bool {
        guard let store, let value = store.object(forKey: key.rawValue) as? Bool else { return key.defaultValue }
        return value
    }

    static func write(_ key: Key, _ value: Bool, to store: UserDefaults?) {
        store?.set(value, forKey: key.rawValue)
    }
}
