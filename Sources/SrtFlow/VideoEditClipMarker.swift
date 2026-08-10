import Foundation

// 轨道块上的标记。纯值逻辑，checks/ProjectFile 编进去做守卫。
// 长期约束见 docs/architecture/clip-markers.md。

// MARK: - 标记

/// 贴在一段素材某一帧上的标记，给用户自己做标注用。
///
/// **锚在源时间上**（`sourceTime`），和关键帧同一套锚定方式（见
/// docs/architecture/keyframe-animation.md）。理由是标记标的是「画面里的这一
/// 帧」，不是「时间线上的这一刻」：整段挪窝、变速、裁头尾之后，标记必须还贴在
/// 同一帧画面上。若锚时间线绝对时间，随手拖一下整段，所有标记就跟内容脱节了。
///
/// 标记只是编辑期的标注：不进合成、不进导出，改它不需要重建预览。
struct ClipMarker: Identifiable, Hashable, Sendable {
    let id: UUID
    /// 在素材自己时间轴上的位置（秒）。换算到时间线走 `timelineTime(atSource:)`。
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

/// 指向「哪一段里的哪一枚标记」。
///
/// 标记 id 只在所在段内唯一：分割会把整份标记表原样复制给两半（见
/// `TimelineState.split`），两半里存在 id 相同的标记。所以任何引用都必须带上
/// 段的身份，光拿 markerID 会指向两枚。
struct ClipMarkerRef: Hashable, Sendable {
    let clipID: UUID
    let markerID: UUID
}

// MARK: - EditClip 上的标记读写

extension EditClip {
    /// 落在当前窗口（`sourceStart ..< sourceStart + sourceDuration`）里的标记，
    /// 按时间排序。界面只画这些。
    ///
    /// 窗口外的标记**不删只藏**：裁头尾随时可能被撤销或再拉回来，顺手删掉的话
    /// 用户拉回来只能重标一遍。和关键帧留整份轨是同一个取舍。
    var visibleMarkers: [ClipMarker] {
        markers
            .filter { containsMarker(atSourceTime: $0.sourceTime) }
            .sorted { $0.sourceTime < $1.sourceTime }
    }

    /// 这个源时刻在当前窗口内吗（两端各留半毫秒，别让边界上的标记闪来闪去）。
    func containsMarker(atSourceTime source: Double) -> Bool {
        source >= sourceStart - 0.0005 && source <= sourceStart + sourceDuration + 0.0005
    }

    /// 这枚标记落在时间线的哪一刻。
    func timelineTime(of marker: ClipMarker) -> Double {
        timelineTime(atSource: marker.sourceTime)
    }

    /// 在时间线的 `time` 处打一枚标记，返回新标记的 id。
    ///
    /// 落点不在这一段的窗口里，或者原地已经有一枚（`tolerance` 以内）时返回
    /// nil 且什么都不改 —— 连按 M 不会在同一帧叠出一摞互相压住、点都点不开的
    /// 标记。容差由调用方按工程帧率和本段速度算（`KeyframeTrack.sourceTolerance`），
    /// 跟关键帧用同一把尺子。
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

// MARK: - TimelineState 上的标记读写

extension TimelineState {
    /// 工程里还有没有标记（格式版本登记清单要用）。
    var hasClipMarkers: Bool {
        allClips.contains { !$0.markers.isEmpty }
    }

    func marker(_ ref: ClipMarkerRef) -> ClipMarker? {
        clip(with: ref.clipID)?.markers.first { $0.id == ref.markerID }
    }

    /// 这枚标记还在、且还落在所在段的窗口里吗。选择的有效性以它为准：
    /// 段被删掉、标记被删掉、或者被裁到窗口外，选择都该跟着摘掉。
    func isMarkerSelectable(_ ref: ClipMarkerRef) -> Bool {
        guard let clip = clip(with: ref.clipID),
              let marker = clip.markers.first(where: { $0.id == ref.markerID }) else { return false }
        return clip.containsMarker(atSourceTime: marker.sourceTime)
    }

    /// 在某段的时间线时刻打标记，返回新标记的引用（没打成是 nil）。
    @discardableResult
    mutating func addMarker(
        toClip clipID: UUID,
        atTimeline time: Double,
        color: MarkerColor,
        tolerance: Double
    ) -> ClipMarkerRef? {
        var created: UUID?
        update(clipID) { clip in
            created = clip.addMarker(atTimeline: time, color: color, tolerance: tolerance)
        }
        return created.map { ClipMarkerRef(clipID: clipID, markerID: $0) }
    }

    mutating func removeMarker(_ ref: ClipMarkerRef) {
        update(ref.clipID) { clip in
            clip.markers.removeAll { $0.id == ref.markerID }
        }
    }

    mutating func updateMarker(_ ref: ClipMarkerRef, _ change: (inout ClipMarker) -> Void) {
        update(ref.clipID) { clip in
            guard let index = clip.markers.firstIndex(where: { $0.id == ref.markerID }) else { return }
            change(&clip.markers[index])
        }
    }
}
