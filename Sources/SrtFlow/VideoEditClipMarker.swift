import Foundation

// 标记：轨道上的每一种块（素材段 / 文字 / 形状 / 滤镜段）和标尺都能打。纯值逻辑，
// checks/ProjectFile 编进去做守卫。长期约束见 docs/architecture/clip-markers.md。
//
// 管什么：一枚标记长什么样（ClipMarker）、谁能挂标记（MarkerHost：各自的时间轴怎么换算到
// 时间线、窗口在哪）、指着「哪一块的哪一枚」（MarkerRef）、TimelineState 按归属增删改查。
// 不管什么：画法和交互（VideoEditTimelineMarkers.swift）、M 打在哪（VideoEditMarkerTargets.swift）。

// MARK: - 标记

/// 贴在宿主某一刻上的标记，给用户自己做标注用。
///
/// `sourceTime` 记在**宿主自己的时间轴**上：素材段是源时间（和关键帧同一套锚定，见
/// docs/architecture/keyframe-animation.md）；文字 / 形状 / 滤镜段是离块起点多少秒；
/// 标尺就是时间线本身。理由是标记标的是「这一块里的这一刻」，不是「时间线上的这一刻」：
/// 整块挪窝、变速、裁头尾之后，标记必须还贴在同一处内容上。若锚时间线绝对时间，随手拖一下
/// 整块，所有标记就跟内容脱节了。
///
/// 标记只是编辑期的标注：不进合成、不进导出，改它不需要重建预览。
struct ClipMarker: Identifiable, Hashable, Sendable {
    let id: UUID
    /// 在宿主自己时间轴上的位置（秒）。换算到时间线走 `MarkerHost.timelineTime(atSource:)`。
    var sourceTime: Double
    var color: MarkerColor
    /// 备注文字。默认空 —— 空标记只是一个色点，悬停不弹气泡。
    var text: String

    init(id: UUID = UUID(), sourceTime: Double, color: MarkerColor = .red, text: String = "") {
        self.id = id
        self.sourceTime = sourceTime
        self.color = color
        self.text = text
    }

    /// 有没有值得弹出来的文字（全空白不算）。
    var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// 标记的可选颜色。
///
/// 存名字而不是存 RGB：以后想调配色，老工程里的标记跟着一起变，不会被锁死在
/// 一串当年的数值上。取值不认识时退回 `.red`（`LenientCodableEnum`）。
enum MarkerColor: String, CaseIterable, Identifiable, Sendable {
    case red
    case orange
    case yellow
    case green
    case blue
    case purple

    var id: String { rawValue }
}

// MARK: - 归属与引用

/// 标记挂在谁身上。
enum MarkerOwner: Hashable, Sendable {
    case clip(UUID)
    case text(UUID)
    case shape(UUID)
    case filter(UUID)
    /// 标尺：锚在时间线的绝对时刻，不跟任何块走（2026-09-30 用户拍板：磁吸挪了主轨的段它也不动）。
    case ruler
}

/// 指向「哪一块的哪一枚标记」。
///
/// 标记 id 只在所在宿主内唯一：分割会把整份标记表原样复制给两半（见
/// `TimelineState.split`），两半里存在 id 相同的标记。所以任何引用都必须带上
/// 宿主的身份，光拿 markerID 会指向两枚。
struct MarkerRef: Hashable, Sendable {
    let owner: MarkerOwner
    let markerID: UUID
}

// MARK: - 能挂标记的东西

/// 能挂标记的东西：素材段、文字、形状、滤镜段、标尺。各自只回答「我的时间轴怎么换算到
/// 时间线」和「窗口在哪」，增删、画法全部共用。
protocol MarkerHost {
    var markers: [ClipMarker] { get set }
    /// 在时间线上从哪儿画起（块的横坐标原点；标尺是 0）。
    var timelineStart: Double { get }
    func timelineTime(atSource source: Double) -> Double
    func sourceTime(atTimeline time: Double) -> Double
    /// 这个时刻在当前窗口内吗。裁到窗口外的标记**不画但不删**。
    func containsMarker(atSourceTime source: Double) -> Bool
}

extension MarkerHost {
    /// 落在当前窗口里的标记，按时间排序。界面只画这些。
    ///
    /// 窗口外的标记**不删只藏**：裁头尾随时可能被撤销或再拉回来，顺手删掉的话
    /// 用户拉回来只能重标一遍。和关键帧留整份轨是同一个取舍。
    var visibleMarkers: [ClipMarker] {
        markers
            .filter { containsMarker(atSourceTime: $0.sourceTime) }
            .sorted { $0.sourceTime < $1.sourceTime }
    }

    /// 这枚标记落在时间线的哪一刻。
    func timelineTime(of marker: ClipMarker) -> Double {
        timelineTime(atSource: marker.sourceTime)
    }

    /// 在时间线的 `time` 处打一枚标记，返回新标记的 id。
    ///
    /// 落点不在窗口里，或者原地已经有一枚（`tolerance` 以内）时返回 nil 且什么都不改
    /// —— 连按 M 不会在同一帧叠出一摞互相压住、点都点不开的标记。容差由调用方按工程
    /// 帧率和宿主的速度算（`TimelineState.markerTolerance(for:)`），跟关键帧用同一把尺子。
    @discardableResult
    mutating func addMarker(atTimeline time: Double, color: MarkerColor, tolerance: Double) -> UUID? {
        let source = sourceTime(atTimeline: time)
        guard containsMarker(atSourceTime: source) else { return nil }
        guard !markers.contains(where: { abs($0.sourceTime - source) <= tolerance }) else { return nil }
        let marker = ClipMarker(sourceTime: source, color: color)
        markers.append(marker)
        markers.sort { $0.sourceTime < $1.sourceTime }
        return marker.id
    }
}

/// 素材段：源时间 + 变速（`EditClip.timelineTime(atSource:)` 在 VideoEditAnimation.swift）。
extension EditClip: MarkerHost {
    /// 这个源时刻在当前窗口内吗（两端各留半毫秒，别让边界上的标记闪来闪去）。
    func containsMarker(atSourceTime source: Double) -> Bool {
        source >= sourceStart - 0.0005 && source <= sourceStart + sourceDuration + 0.0005
    }
}

/// 叠层类的块（文字 / 形状 / 滤镜段）：没有素材，「源时间」就是离块起点多少秒。
///
/// 裁头时块的起点变了，标记要留在时间线上的**同一刻**（和素材段「贴在同一帧画面」同一个
/// 语义），所以裁头的那一步要调 `keepMarkersInPlace(afterLeadingTrim:)`，只有挪窝才带着走。
protocol OverlayMarkerHost: MarkerHost {
    var duration: Double { get }
}

extension OverlayMarkerHost {
    func timelineTime(atSource source: Double) -> Double { timelineStart + source }
    func sourceTime(atTimeline time: Double) -> Double { time - timelineStart }
    func containsMarker(atSourceTime source: Double) -> Bool {
        source >= -0.0005 && source <= duration + 0.0005
    }

    /// 起点端裁了 `delta` 秒（正 = 往右缩、负 = 往左拉）之后，让每枚标记留在原来的时间线时刻。
    mutating func keepMarkersInPlace(afterLeadingTrim delta: Double) {
        guard delta != 0 else { return }
        for index in markers.indices { markers[index].sourceTime -= delta }
    }
}

extension TextOverlay: OverlayMarkerHost {}
extension ShapeAnnotation: OverlayMarkerHost {}
extension FilterClip: OverlayMarkerHost {}

/// 标尺：标记锚在时间线的绝对时刻，窗口是整条时间线（片尾以后也算，工程变短了标记照留）。
struct RulerMarkerHost: MarkerHost, Hashable, Sendable {
    var markers: [ClipMarker]
    var timelineStart: Double { 0 }
    func timelineTime(atSource source: Double) -> Double { source }
    func sourceTime(atTimeline time: Double) -> Double { time }
    func containsMarker(atSourceTime source: Double) -> Bool { source >= -0.0005 }
}

// MARK: - TimelineState 按归属读写

extension TimelineState {
    /// 素材段上还有没有标记（v8 的登记清单要用）。
    var hasClipMarkers: Bool {
        allClips.contains { !$0.markers.isEmpty }
    }

    /// 文字 / 形状 / 滤镜段 / 标尺上还有没有标记（v28 的登记清单要用）。
    var hasMarkersBeyondClips: Bool {
        !rulerMarkers.isEmpty || textOverlays.contains { !$0.markers.isEmpty }
            || shapes.contains { !$0.markers.isEmpty } || filters.contains { !$0.markers.isEmpty }
    }

    /// 这个归属现在是谁（不在了就是 nil）。
    func markerHost(_ owner: MarkerOwner) -> (any MarkerHost)? {
        switch owner {
        case .clip(let id): return clip(with: id)
        case .text(let id): return textOverlays.first { $0.id == id }
        case .shape(let id): return shapes.first { $0.id == id }
        case .filter(let id): return filters.first { $0.id == id }
        case .ruler: return RulerMarkerHost(markers: rulerMarkers)
        }
    }

    /// 改这个归属的标记表。归属不在了就什么都不做。
    mutating func updateMarkers(of owner: MarkerOwner, _ change: (inout [ClipMarker]) -> Void) {
        switch owner {
        case .clip(let id): update(id) { change(&$0.markers) }
        case .text(let id): updateTextOverlay(id) { change(&$0.markers) }
        case .shape(let id): updateShape(id) { change(&$0.markers) }
        case .filter(let id): updateFilter(id) { change(&$0.markers) }
        case .ruler: change(&rulerMarkers)
        }
    }

    /// 打标记的容差：按工程帧率和宿主的速度算，跟关键帧同一把尺子（只有素材段有变速）。
    func markerTolerance(for owner: MarkerOwner) -> Double {
        let speed: Double
        if case .clip(let id) = owner, let clip = clip(with: id) { speed = clip.speed } else { speed = 1 }
        return KeyframeTrack.sourceTolerance(frameRate: frameRate, speed: speed)
    }

    func marker(_ ref: MarkerRef) -> ClipMarker? {
        markerHost(ref.owner)?.markers.first { $0.id == ref.markerID }
    }

    /// 这枚标记还在、且还落在宿主的窗口里吗。选择的有效性以它为准：
    /// 宿主被删掉、标记被删掉、或者被裁到窗口外，选择都该跟着摘掉。
    func isMarkerSelectable(_ ref: MarkerRef) -> Bool {
        guard let host = markerHost(ref.owner),
              let marker = host.markers.first(where: { $0.id == ref.markerID }) else { return false }
        return host.containsMarker(atSourceTime: marker.sourceTime)
    }

    /// 在某个归属的时间线时刻打标记，返回新标记的引用（没打成是 nil）。
    @discardableResult
    mutating func addMarker(
        to owner: MarkerOwner,
        atTimeline time: Double,
        color: MarkerColor,
        tolerance: Double
    ) -> MarkerRef? {
        guard var host = markerHost(owner),
              let id = host.addMarker(atTimeline: time, color: color, tolerance: tolerance) else { return nil }
        updateMarkers(of: owner) { $0 = host.markers }
        return MarkerRef(owner: owner, markerID: id)
    }

    mutating func removeMarker(_ ref: MarkerRef) {
        updateMarkers(of: ref.owner) { $0.removeAll { $0.id == ref.markerID } }
    }

    mutating func updateMarker(_ ref: MarkerRef, _ change: (inout ClipMarker) -> Void) {
        updateMarkers(of: ref.owner) { markers in
            guard let index = markers.firstIndex(where: { $0.id == ref.markerID }) else { return }
            change(&markers[index])
        }
    }
}

// MARK: - 存盘
//
// 2026-09-24 从 VideoEditModels.swift 搬过来（那个文件过了 600 行的上限）：标记怎么存盘是标记自己的事。

extension ClipMarker: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, sourceTime, color, text
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 位置是唯一必需的字段：没有它这枚标记不知道该画在哪。
        self.init(
            id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            sourceTime: try c.decode(Double.self, forKey: .sourceTime),
            color: try c.decodeIfPresent(MarkerColor.self, forKey: .color) ?? .red,
            text: try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sourceTime, forKey: .sourceTime)
        try c.encode(color, forKey: .color)
        if !text.isEmpty { try c.encode(text, forKey: .text) }
    }
}

extension MarkerColor: LenientCodableEnum {
    static var decodingFallback: MarkerColor { .red }
}
