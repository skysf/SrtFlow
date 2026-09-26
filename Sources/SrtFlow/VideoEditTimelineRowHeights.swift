import Foundation

// MARK: - 每条轨自己的行高
//
// 2026-09-22 产品决策：行高**一轨一个值**，拖谁只动谁。在那之前是一类一个值
//（`videoRowHeight` / `audioRowHeight`），拖一条音频轨，所有音频轨一起变高 ——
// 用户要的是「每一个轨道的高度都独立可调」。
//
// 这个文件是纯值（不 import SwiftUI），所以自检编得动它：
// 「删掉中间一条轨，剩下的轨不换高度」这类规则只有断言守得住。
// 手势接线在 `VideoEditTimelineRowHeightDrag.swift`，存盘在
// `VideoEditProjectFile.swift`，长期约束见
// docs/architecture/video-tracks.md 与 docs/architecture/video-edit-project-file.md。

/// 轨道行的类别。
///
/// 它现在只决定**默认值和夹紧区间**，不再决定「谁跟谁一起动」——
/// 后者由 `TimelineRowHeightKey` 按轨道身份分开。
enum TrackRowKind: Hashable, Sendable {
    case video, audio, other

    /// 从轨道身份翻译过来。**只有这一份翻译**：轨道头和行高存储共用它，
    /// 分开写迟早分叉（上层轨曾经被当成「画中画」另算一套）。
    init(_ slot: TrackSlot?) {
        switch slot {
        case .main, .overlay: self = .video
        case .audio: self = .audio
        case nil: self = .other
        }
    }

    /// 可拖区间。`nil` = 这一类根本不给拖。
    ///
    /// 只放开视频轨和音频轨（2026-09-22 用户拍板）。上限 2026-09-23 从 120 / 100 抬到
    /// 200：立体声拆成两条、在波形上拖音量曲线，都要一条够高的轨。字幕 / 文字 / 形状 /
    /// 滤镜行的行高和块高是一对硬编码常量（字幕行 22 而 cue 块 14、形状行 26
    /// 而块 20），框选的命中判据直接依赖那个差
    /// （docs/architecture/timeline-drag-gestures.md §框选的高）——
    /// 放开就得把那套几何重做一遍。
    var heightRange: ClosedRange<Double>? {
        switch self {
        case .video: return 28...200
        case .audio: return 20...200
        case .other: return nil
        }
    }

    /// 夹进区间。不可拖的类、以及 NaN/inf 一律返回 nil，调用方据此什么都不做。
    func clamped(_ height: Double) -> Double? {
        guard let range = heightRange, height.isFinite else { return nil }
        return min(max(height, range.lowerBound), range.upperBound)
    }
}

/// 一条轨的身份，**不带索引**。
///
/// 键不能用 `TrackSlot`：`overlay(Int)` / `audio(Int)` 是位置号，删掉中间一条轨
/// 之后，下面那条就会继承别人的高度。这和轨道配色是同一条教训 ——
/// 「色号绑轨道身份，不绑行号」（docs/architecture/video-tracks.md）。
///
/// 主轨不是 `EditLane`、没有 UUID，所以单开一个 case（同 `colorIndex` 里
/// 「主轨恒定占视频色号 0」的不对称）。
enum TimelineRowHeightKey: Hashable, Sendable {
    case main
    case lane(UUID)
}

/// 每条轨自己的行高。没有条目 = 跟纵向缩放定的统一高度走，再没有就跟这一类的默认值走
/// （同 `colorIndex == nil`）。
///
/// **它不在 `TimelineState` 里**，因此不进撤销栈、不触发预览重建：行高是装饰
/// 状态，进了撤销栈之后「调完行高按 ⌘Z」撤掉的是行高，而不是用户上一次真编辑。
/// 存盘时它是 `VideoEditProjectFile` 里与 `timeline` 平级的一段。
struct TimelineRowHeights: Hashable, Sendable {
    /// 主轨。
    var main: Double?
    /// 上层视频轨和音频轨，键是 `EditLane.id`。
    var lanes: [UUID: Double]
    /// 纵向缩放（⌥ 捏合、⌘↑ ⌘↓）定的统一高度：视频轨和音频轨**全部**用它，除非之后又单独拖过
    /// 某一条（2026-09-26 用户拍板：纵向缩放时所有轨变成一样高，单独调过的作废）。nil = 没缩放过。
    var uniform: Double?

    /// 统一高度的区间：视频轨和音频轨可调区间的交集 —— 「一样高」得两类都够得着。
    static let uniformRange: ClosedRange<Double> = 28...200

    init(main: Double? = nil, lanes: [UUID: Double] = [:], uniform: Double? = nil) {
        self.main = main
        self.lanes = lanes
        self.uniform = uniform
    }

    var isEmpty: Bool { main == nil && lanes.isEmpty && uniform == nil }

    subscript(key: TimelineRowHeightKey) -> Double? {
        get {
            switch key {
            case .main: return main
            case .lane(let id): return lanes[id]
            }
        }
        set {
            switch key {
            case .main: main = newValue
            case .lane(let id): lanes[id] = newValue
            }
        }
    }

    /// 这条轨该多高：自己调过就用自己的，没调过跟统一高度走，再没有跟这一类的默认值走。
    ///
    /// `key` 为 nil（不给拖的行：标尺、字幕、文字、形状、滤镜）时只走默认值 —— 纵向缩放不碰那几条细行
    /// （它们的行高和块高是写死的一对，框选的命中靠那个差）。调用方拿到的永远是个能用的高度。
    func height(for key: TimelineRowHeightKey?, fallback: Double) -> Double {
        guard let key else { return fallback }
        return self[key] ?? uniform ?? fallback
    }

    /// 写入一条轨的行高。夹紧在这里做，**这是单独一条轨的唯一写入口**。
    mutating func set(_ height: Double, for key: TimelineRowHeightKey, kind: TrackRowKind) {
        guard let clamped = kind.clamped(height) else { return }
        self[key] = clamped
    }

    /// 纵向缩放：视频轨和音频轨统一成这个高度（夹进 `uniformRange`），**单独调过的全部作废**。
    /// NaN / inf 什么都不做。
    mutating func setUniform(_ height: Double) {
        guard height.isFinite else { return }
        uniform = min(max(height, Self.uniformRange.lowerBound), Self.uniformRange.upperBound)
        main = nil
        lanes = [:]
    }

    /// 丢掉已经不存在的轨。
    ///
    /// **只给写盘那一份拷贝用，不许拿它盖回内存里的那份**：删掉一条轨会触发
    /// 自动保存，若同时把内存里的条目也清了，用户 ⌘Z 把轨撤回来时高度就没了
    ///（`EditLane.id` 撤回来还是同一个 UUID，条目留着就能接上）。
    func pruned(keeping liveLanes: Set<UUID>) -> TimelineRowHeights {
        TimelineRowHeights(main: main, lanes: lanes.filter { liveLanes.contains($0.key) }, uniform: uniform)
    }

    /// 行 → 存高度用的键。不可拖的行返回 nil。
    static func key(for slot: TrackSlot?, in state: TimelineState) -> TimelineRowHeightKey? {
        switch slot {
        case .main:
            return .main
        case .overlay(let index):
            guard state.overlayTracks.indices.contains(index) else { return nil }
            return .lane(state.overlayTracks[index].id)
        case .audio(let index):
            guard state.audioTracks.indices.contains(index) else { return nil }
            return .lane(state.audioTracks[index].id)
        case nil:
            return nil
        }
    }
}

// MARK: - 存盘

extension TimelineRowHeights: Codable {
    private enum CodingKeys: String, CodingKey { case main, lanes, uniform }

    /// 一条轨一条记录。
    ///
    /// 不直接编 `[UUID: Double]`：Swift 会把非字符串键的字典编成
    /// `[键, 值, 键, 值…]` 的裸数组，顺序还不稳定 —— 工程文件是
    /// `prettyPrinted + sortedKeys` 的，人肉看得见、也可能进 git，
    /// 不该每存一次就 diff 一片。
    private struct Entry: Codable {
        var id: UUID
        var height: Double
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let entries = try c.decodeIfPresent([Entry].self, forKey: .lanes) ?? []
        self.init(
            main: try c.decodeIfPresent(Double.self, forKey: .main),
            lanes: Dictionary(entries.map { ($0.id, $0.height) }, uniquingKeysWith: { a, _ in a }),
            // 缺键 = 没纵向缩放过（2026-09-26 之前的工程）。旧版读到这个键会忽略它 —— 丢的只是高度，
            // 成片一帧不变，所以不开新的 formatVersion（同 rowHeights 这一段本身的口径）。
            uniform: try c.decodeIfPresent(Double.self, forKey: .uniform).flatMap { height in
                height.isFinite ? min(max(height, Self.uniformRange.lowerBound), Self.uniformRange.upperBound) : nil
            }
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(main, forKey: .main)
        try c.encodeIfPresent(uniform, forKey: .uniform)
        if !lanes.isEmpty {
            let entries = lanes
                .map { Entry(id: $0.key, height: $0.value) }
                .sorted { $0.id.uuidString < $1.id.uuidString }
            try c.encode(entries, forKey: .lanes)
        }
    }
}

extension TimelineState {
    /// 现在还活着的轨道身份。写盘时拿它丢掉删了的轨。
    var laneIDs: Set<UUID> {
        Set(overlayTracks.map(\.id)).union(audioTracks.map(\.id))
    }
}
