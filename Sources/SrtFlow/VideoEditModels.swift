import Foundation
import SrtFlowCore

// MARK: - 转场

/// 主轨相邻两段之间的转场。
///
/// 三种都按「重叠 d 秒」来算：前一段的尾巴和后一段的开头叠在一起渐变。
/// 这样预览（双轨透明度渐变）和导出（ffmpeg xfade）的时间账完全一致。
enum ClipTransition: String, CaseIterable, Identifiable, Hashable, Sendable {
    case none
    case blackFade
    case crossFade
    case whiteFade

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .blackFade: return "Black fade"
        case .crossFade: return "Cross dissolve"
        case .whiteFade: return "White fade"
        }
    }

    /// ffmpeg `xfade` 滤镜里对应的名字。
    var xfadeName: String? {
        switch self {
        case .none: return nil
        case .blackFade: return "fadeblack"
        case .crossFade: return "fade"
        case .whiteFade: return "fadewhite"
        }
    }
}

// MARK: - 画中画位置

/// 画中画的九宫格停靠位。
enum OverlayAnchor: String, CaseIterable, Identifiable, Hashable, Sendable {
    case topLeading, top, topTrailing
    case leading, center, trailing
    case bottomLeading, bottom, bottomTrailing

    var id: String { rawValue }

    /// 列 0/1/2、行 0/1/2（行 0 在上）。
    var column: Int {
        switch self {
        case .topLeading, .leading, .bottomLeading: return 0
        case .top, .center, .bottom: return 1
        case .topTrailing, .trailing, .bottomTrailing: return 2
        }
    }

    var row: Int {
        switch self {
        case .topLeading, .top, .topTrailing: return 0
        case .leading, .center, .trailing: return 1
        case .bottomLeading, .bottom, .bottomTrailing: return 2
        }
    }

    /// 画中画左上角的位置。`inset` 是到边缘的留白，都按输出画面的像素来。
    func origin(canvas: CGSize, overlay: CGSize, inset: Double) -> CGPoint {
        let x: Double
        switch column {
        case 0: x = inset
        case 1: x = (canvas.width - overlay.width) / 2
        default: x = canvas.width - overlay.width - inset
        }
        let y: Double
        switch row {
        case 0: y = inset
        case 1: y = (canvas.height - overlay.height) / 2
        default: y = canvas.height - overlay.height - inset
        }
        return CGPoint(x: x, y: y)
    }
}

// MARK: - 画布比例

/// 输出画面的宽高比。`auto` 跟随主轨第一段素材。
enum CanvasRatio: String, CaseIterable, Identifiable, Hashable, Sendable {
    case auto
    case wide16x9
    case tall9x16
    case standard4x3
    case tall3x4
    case square

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .wide16x9: return "16:9"
        case .tall9x16: return "9:16"
        case .standard4x3: return "4:3"
        case .tall3x4: return "3:4"
        case .square: return "1:1"
        }
    }

    /// 固定比例对应的标准输出尺寸；auto 返回 nil（按素材算）。
    var fixedSize: CGSize? {
        switch self {
        case .auto: return nil
        case .wide16x9: return CGSize(width: 1920, height: 1080)
        case .tall9x16: return CGSize(width: 1080, height: 1920)
        case .standard4x3: return CGSize(width: 1440, height: 1080)
        case .tall3x4: return CGSize(width: 1080, height: 1440)
        case .square: return CGSize(width: 1080, height: 1080)
        }
    }
}

// MARK: - 形状标注

/// 画在画面上的形状：线条、长方形、正方形。
enum ShapeKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case line
    case rectangle
    case square

    var id: String { rawValue }

    var title: String {
        switch self {
        case .line: return "Line"
        case .rectangle: return "Rectangle"
        case .square: return "Square"
        }
    }

    var icon: String {
        switch self {
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .square: return "square"
        }
    }
}

/// 一条形状标注。位置和大小都是相对输出画面的 0…1 归一化值，
/// 预览（SwiftUI 绘制）和导出（渲成 PNG 叠加）用同一套坐标，所见即所得。
struct ShapeAnnotation: Identifiable, Hashable, Sendable {
    let id: UUID
    var kind: ShapeKind

    var timelineStart: Double
    var duration: Double

    var color: SubtitleColor
    /// 描边宽度，按 1080p 基准的像素数。
    var lineWidth: Double

    var centerX: Double
    var centerY: Double
    /// 线条：width 是长度，height 无用；正方形：两者取 width。
    var width: Double
    var height: Double
    /// 只对线条有意义：顺时针角度（度）。
    var rotationDegrees: Double

    init(
        id: UUID = UUID(),
        kind: ShapeKind,
        timelineStart: Double,
        duration: Double = 3,
        color: SubtitleColor = .yellow,
        lineWidth: Double = 6,
        centerX: Double = 0.5,
        centerY: Double = 0.5,
        width: Double = 0.3,
        height: Double = 0.2,
        rotationDegrees: Double = 0
    ) {
        self.id = id
        self.kind = kind
        self.timelineStart = timelineStart
        self.duration = duration
        self.color = color
        self.lineWidth = lineWidth
        self.centerX = centerX
        self.centerY = centerY
        self.width = width
        self.height = kind == .square ? width : height
        self.rotationDegrees = rotationDegrees
    }

    var timelineEnd: Double { timelineStart + duration }

    func contains(time: Double) -> Bool {
        time >= timelineStart && time < timelineEnd
    }

    /// 画布上的外接框（按给定画布尺寸换算）。正方形按画布**宽度**取边长，
    /// 保证在任何比例的画面里都是正的。
    func frame(in canvas: CGSize) -> CGRect {
        let w: Double
        let h: Double
        switch kind {
        case .square:
            w = width * canvas.width
            h = w
        case .rectangle:
            w = width * canvas.width
            h = height * canvas.height
        case .line:
            w = width * canvas.width
            h = 0
        }
        return CGRect(
            x: centerX * canvas.width - w / 2,
            y: centerY * canvas.height - h / 2,
            width: w,
            height: h
        )
    }
}

// MARK: - 剪辑

/// 时间线上的一段素材。
///
/// 时间有两套：`sourceStart`/`sourceDuration` 是素材自己的时间（裁掉头尾就是改
/// 它们），`timelineStart` 是这段落在时间线上的位置。变速只改换算关系：
/// 时间线上的长度 = 源长度 ÷ 速度。
struct EditClip: Identifiable, Hashable, Sendable {
    let id: UUID
    var sourceURL: URL
    /// 素材本身是视频还是纯音频（决定画不画到画面上）。
    var isAudioOnly: Bool

    var sourceStart: Double
    var sourceDuration: Double
    var speed: Double
    var timelineStart: Double

    var isMuted: Bool
    var volume: Double
    /// 同组的剪辑（分离出的音频）在「链接」开着时一起移动、分割、删除。
    var linkGroup: UUID?

    /// 这段和**下一段**之间的转场，只对主轨有意义。
    var transitionAfter: ClipTransition
    var transitionDuration: Double

    /// 画中画：相对主画面宽度的比例，以及停靠位。
    var overlayFraction: Double
    var overlayAnchor: OverlayAnchor

    /// 探测到的源信息（时长、尺寸、有没有音轨）。纯音频素材是 nil。
    var info: MediaInfo?
    /// 纯音频素材的总时长（MediaProbe 只管视频，音频单独记）。
    var audioAssetDuration: Double?
    /// 静态图片素材：`sourceURL` 指向生成的循环视频，这里留着原图路径当名字用。
    var stillImageURL: URL?
    /// 图片刚拖进来、静帧视频还在后台转：块先上轨可编辑，预览暂时跳过它。
    var needsStillConversion = false

    init(
        id: UUID = UUID(),
        sourceURL: URL,
        isAudioOnly: Bool = false,
        sourceStart: Double = 0,
        sourceDuration: Double,
        speed: Double = 1,
        timelineStart: Double = 0,
        isMuted: Bool = false,
        volume: Double = 1,
        linkGroup: UUID? = nil,
        transitionAfter: ClipTransition = .none,
        transitionDuration: Double = 0.5,
        overlayFraction: Double = 0.4,
        overlayAnchor: OverlayAnchor = .topTrailing,
        info: MediaInfo? = nil,
        audioAssetDuration: Double? = nil,
        stillImageURL: URL? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.isAudioOnly = isAudioOnly
        self.sourceStart = sourceStart
        self.sourceDuration = sourceDuration
        self.speed = speed
        self.timelineStart = timelineStart
        self.isMuted = isMuted
        self.volume = volume
        self.linkGroup = linkGroup
        self.transitionAfter = transitionAfter
        self.transitionDuration = transitionDuration
        self.overlayFraction = overlayFraction
        self.overlayAnchor = overlayAnchor
        self.info = info
        self.audioAssetDuration = audioAssetDuration
        self.stillImageURL = stillImageURL
    }

    var name: String {
        (stillImageURL ?? sourceURL).deletingPathExtension().lastPathComponent
    }

    var isStillImage: Bool { stillImageURL != nil }

    /// 素材文件的总长度（还能往两头拉出多少，取决于它）。
    var assetDuration: Double { info?.duration ?? audioAssetDuration ?? sourceDuration }

    var hasAudio: Bool { isAudioOnly || (info?.hasAudio ?? false) }

    var timelineDuration: Double { sourceDuration / max(0.05, speed) }
    var timelineEnd: Double { timelineStart + timelineDuration }

    func contains(time: Double) -> Bool {
        time > timelineStart + 0.001 && time < timelineEnd - 0.001
    }
}

// MARK: - 时间线整体状态

/// 一条画中画轨或音频轨：有身份（行的增删不串号）、可整轨隐藏。
struct EditLane: Identifiable, Hashable, Sendable {
    let id: UUID
    var clips: [EditClip]
    /// 隐藏的轨：灰显不可编辑，预览和导出都当它不存在。
    var isHidden: Bool

    init(id: UUID = UUID(), clips: [EditClip] = [], isHidden: Bool = false) {
        self.id = id
        self.clips = clips
        self.isHidden = isHidden
    }
}

/// 一份完整的时间线。撤销/重做就是整个换掉它，所以全部是值类型。
struct TimelineState: Hashable, Sendable {
    /// 主视频轨。数组顺序就是时间顺序；磁吸开着时位置由 `packMain` 排。
    var mainClips: [EditClip] = []
    /// 主轨的整轨隐藏（预览成黑场，导出跳过）。
    var mainHidden = false
    /// 画中画轨（可以有多条，叠放顺序：靠后的画在上面）。
    var overlayTracks: [EditLane] = []
    /// 音频轨（背景音乐、分离出的人声等）。
    var audioTracks: [EditLane] = []

    var subtitle: SubtitleDocumentModel?
    var subtitleURL: URL?
    /// 画面上的形状标注。
    var shapes: [ShapeAnnotation] = []
    /// 输出画面比例（预览和导出共用）。
    var canvasRatio: CanvasRatio = .auto

    var isEmpty: Bool {
        mainClips.isEmpty && overlayTracks.allSatisfy(\.clips.isEmpty)
            && audioTracks.allSatisfy(\.clips.isEmpty) && subtitle == nil && shapes.isEmpty
    }

    /// 整条时间线的长度：所有轨里最晚结束的那一刻。
    var duration: Double {
        var end = mainClips.map(\.timelineEnd).max() ?? 0
        for lane in overlayTracks { end = max(end, lane.clips.map(\.timelineEnd).max() ?? 0) }
        for lane in audioTracks { end = max(end, lane.clips.map(\.timelineEnd).max() ?? 0) }
        for shape in shapes { end = max(end, shape.timelineEnd) }
        return end
    }

    mutating func updateShape(_ id: UUID, _ change: (inout ShapeAnnotation) -> Void) {
        guard let index = shapes.firstIndex(where: { $0.id == id }) else { return }
        change(&shapes[index])
        // 正方形永远保持正方形。
        if shapes[index].kind == .square { shapes[index].height = shapes[index].width }
    }

    // MARK: 主轨排列

    /// 磁吸：主轨各段首尾相接，有转场的地方按转场时长叠进去。
    mutating func packMain() {
        var cursor = 0.0
        for index in mainClips.indices {
            mainClips[index].timelineStart = cursor
            cursor = mainClips[index].timelineEnd - transitionOverlap(afterMainIndex: index)
        }
    }

    /// 第 index 段和下一段之间实际叠掉的时长。
    ///
    /// xfade 要求叠的部分不能超过两边任何一段，这里再收紧到 45%，
    /// 免得一段短素材被两头的转场吃光。
    func transitionOverlap(afterMainIndex index: Int) -> Double {
        guard index >= 0, index + 1 < mainClips.count else { return 0 }
        let clip = mainClips[index]
        guard clip.transitionAfter != .none else { return 0 }
        return min(
            clip.transitionDuration,
            clip.timelineDuration * 0.45,
            mainClips[index + 1].timelineDuration * 0.45
        )
    }

    // MARK: 查找

    /// 所有轨的所有剪辑。
    var allClips: [EditClip] {
        mainClips + overlayTracks.flatMap(\.clips) + audioTracks.flatMap(\.clips)
    }

    func clip(with id: UUID) -> EditClip? {
        allClips.first { $0.id == id }
    }

    /// 这个剪辑在哪条轨上。
    func location(of id: UUID) -> ClipLocation? {
        if let index = mainClips.firstIndex(where: { $0.id == id }) {
            return ClipLocation(track: .main, clipIndex: index)
        }
        for (trackIndex, lane) in overlayTracks.enumerated() {
            if let index = lane.clips.firstIndex(where: { $0.id == id }) {
                return ClipLocation(track: .overlay(trackIndex), clipIndex: index)
            }
        }
        for (trackIndex, lane) in audioTracks.enumerated() {
            if let index = lane.clips.firstIndex(where: { $0.id == id }) {
                return ClipLocation(track: .audio(trackIndex), clipIndex: index)
            }
        }
        return nil
    }

    /// 这条轨隐藏了吗。
    func isLaneHidden(_ slot: TrackSlot) -> Bool {
        switch slot {
        case .main: return mainHidden
        case .overlay(let index):
            return overlayTracks.indices.contains(index) && overlayTracks[index].isHidden
        case .audio(let index):
            return audioTracks.indices.contains(index) && audioTracks[index].isHidden
        }
    }

    /// 链接组里的所有成员（含它自己）。
    func linkedClipIDs(of id: UUID) -> Set<UUID> {
        guard let clip = clip(with: id), let group = clip.linkGroup else { return [id] }
        return Set(allClips.filter { $0.linkGroup == group }.map(\.id)).union([id])
    }

    // MARK: 通用读写

    subscript(track track: TrackSlot) -> [EditClip] {
        get {
            switch track {
            case .main: return mainClips
            case .overlay(let index): return overlayTracks.indices.contains(index) ? overlayTracks[index].clips : []
            case .audio(let index): return audioTracks.indices.contains(index) ? audioTracks[index].clips : []
            }
        }
        set {
            switch track {
            case .main: mainClips = newValue
            case .overlay(let index): if overlayTracks.indices.contains(index) { overlayTracks[index].clips = newValue }
            case .audio(let index): if audioTracks.indices.contains(index) { audioTracks[index].clips = newValue }
            }
        }
    }

    mutating func update(_ id: UUID, _ change: (inout EditClip) -> Void) {
        guard let location = location(of: id) else { return }
        var clips = self[track: location.track]
        change(&clips[location.clipIndex])
        self[track: location.track] = clips
    }

    mutating func remove(_ id: UUID) {
        guard let location = location(of: id) else { return }
        var clips = self[track: location.track]
        clips.remove(at: location.clipIndex)
        self[track: location.track] = clips
        pruneEmptyTracks()
    }

    /// 清掉空出来的画中画/音频轨，别让界面上留一排空槽。
    mutating func pruneEmptyTracks() {
        overlayTracks.removeAll { $0.clips.isEmpty }
        audioTracks.removeAll { $0.clips.isEmpty }
    }

    /// 把剪辑放进某类自由轨：塞进第一条放得下的（隐藏的不塞），
    /// 都放不下就新开一条。返回落进了哪条轨。
    mutating func place(_ clip: EditClip, intoAudio: Bool) -> Int {
        var lanes = intoAudio ? audioTracks : overlayTracks
        for index in lanes.indices where !lanes[index].isHidden && fits(clip, in: lanes[index].clips) {
            lanes[index].clips.append(clip)
            lanes[index].clips.sort { $0.timelineStart < $1.timelineStart }
            if intoAudio { audioTracks = lanes } else { overlayTracks = lanes }
            return index
        }
        lanes.append(EditLane(clips: [clip]))
        if intoAudio { audioTracks = lanes } else { overlayTracks = lanes }
        return lanes.count - 1
    }

    private func fits(_ clip: EditClip, in track: [EditClip]) -> Bool {
        !track.contains { $0.timelineStart < clip.timelineEnd - 0.001 && clip.timelineStart < $0.timelineEnd - 0.001 }
    }
}

/// 轨道的身份：主轨、第几条画中画轨、第几条音频轨。
enum TrackSlot: Hashable, Sendable {
    case main
    case overlay(Int)
    case audio(Int)

    var isMain: Bool { if case .main = self { return true }; return false }
    var isAudio: Bool { if case .audio = self { return true }; return false }
}

struct ClipLocation: Hashable, Sendable {
    var track: TrackSlot
    var clipIndex: Int
}
