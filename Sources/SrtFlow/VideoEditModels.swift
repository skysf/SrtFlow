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

// MARK: - 自由变换

/// 画面段在输出画布上的自由摆放：中心和宽高都是相对画布的 0…1 归一化值。
///
/// `nil`（不设）表示默认布局 —— 主轨等比铺满居中、画中画走
/// `overlayFraction`/`overlayAnchor` 的九宫格。一旦用户在预览里拖过缩放框，
/// 就换成这份显式的摆放；预览（AVFoundation 变换）和导出（ffmpeg scale+overlay）
/// 都按同一份归一化值换算，所见即所得。宽高各自独立 —— 拉边把手允许变形。
struct ClipPlacement: Hashable, Sendable {
    var centerX: Double
    var centerY: Double
    /// 相对画布宽的比例。
    var width: Double
    /// 相对画布高的比例。
    var height: Double

    /// 画布上的像素框。
    func frame(in canvas: CGSize) -> CGRect {
        CGRect(
            x: (centerX - width / 2) * canvas.width,
            y: (centerY - height / 2) * canvas.height,
            width: width * canvas.width,
            height: height * canvas.height
        )
    }

    init(centerX: Double, centerY: Double, width: Double, height: Double) {
        self.centerX = centerX
        self.centerY = centerY
        self.width = width
        self.height = height
    }

    init(frame: CGRect, in canvas: CGSize) {
        guard canvas.width > 0, canvas.height > 0 else {
            self.init(centerX: 0.5, centerY: 0.5, width: 1, height: 1)
            return
        }
        self.init(
            centerX: frame.midX / canvas.width,
            centerY: frame.midY / canvas.height,
            width: frame.width / canvas.width,
            height: frame.height / canvas.height
        )
    }

    /// 兜住失控的值：尺寸别缩没，中心别整个飞出画面。
    var clamped: ClipPlacement {
        ClipPlacement(
            centerX: min(max(centerX, 0), 1),
            centerY: min(max(centerY, 0), 1),
            width: min(max(width, 0.02), 4),
            height: min(max(height, 0.02), 4)
        )
    }
}

// MARK: - 四边裁切

/// 画面段的四边裁切：每边裁掉源画面（按显示方向）的归一化比例，0…0.45。
/// 裁完剩下的画面填进摆放框；默认摆放框本身也按裁后的宽高比算。
struct ClipCrop: Hashable, Sendable {
    var top: Double
    var bottom: Double
    var leading: Double
    var trailing: Double

    init(top: Double = 0, bottom: Double = 0, leading: Double = 0, trailing: Double = 0) {
        self.top = min(max(top, 0), 0.45)
        self.bottom = min(max(bottom, 0), 0.45)
        self.leading = min(max(leading, 0), 0.45)
        self.trailing = min(max(trailing, 0), 0.45)
    }

    var isEmpty: Bool {
        top < 0.0005 && bottom < 0.0005 && leading < 0.0005 && trailing < 0.0005
    }

    /// 在给定显示尺寸上的裁切矩形（像素）。
    func rect(in display: CGSize) -> CGRect {
        CGRect(
            x: leading * display.width,
            y: top * display.height,
            width: max(1, display.width * (1 - leading - trailing)),
            height: max(1, display.height * (1 - top - bottom))
        )
    }

    /// 把源画面居中裁到目标宽高比（Inspector 里的比例预设）。
    static func centered(aspect: Double, in display: CGSize) -> ClipCrop {
        guard display.width > 0, display.height > 0, aspect > 0 else { return ClipCrop() }
        let current = display.width / display.height
        if current > aspect {
            // 太宽：裁左右。
            let keep = aspect / current
            let inset = (1 - keep) / 2
            return ClipCrop(leading: inset, trailing: inset)
        } else {
            // 太高：裁上下。
            let keep = current / aspect
            let inset = (1 - keep) / 2
            return ClipCrop(top: inset, bottom: inset)
        }
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

    /// 用户在预览里摆过的自由位置/尺寸；nil = 默认布局（主轨铺满、画中画九宫格）。
    var placement: ClipPlacement?

    // Inspector Transform 区的四项静态变换。都有「无操作」默认值，
    // 全默认时预览/导出走原来的轻量路径。
    /// 顺时针旋转角（度），绕摆放框中心。
    var rotationDegrees: Double
    /// 画面不透明度 0…1。
    var opacity: Double
    var flippedHorizontally: Bool
    var flippedVertically: Bool
    /// 四边裁切；nil = 不裁。
    var crop: ClipCrop?

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
        placement: ClipPlacement? = nil,
        rotationDegrees: Double = 0,
        opacity: Double = 1,
        flippedHorizontally: Bool = false,
        flippedVertically: Bool = false,
        crop: ClipCrop? = nil,
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
        self.placement = placement
        self.rotationDegrees = rotationDegrees
        self.opacity = opacity
        self.flippedHorizontally = flippedHorizontally
        self.flippedVertically = flippedVertically
        self.crop = crop
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

    /// 画面上有任何非默认的变换吗（导出走覆盖分支、检查器显示复原用）。
    var hasVisualTransform: Bool {
        placement != nil || abs(rotationDegrees) > 0.01 || opacity < 0.999
            || flippedHorizontally || flippedVertically || !(crop?.isEmpty ?? true)
    }

    /// 裁切后的源画面尺寸（显示方向）。默认摆放框按它算宽高比。
    var croppedDisplaySize: CGSize? {
        guard let display = info?.displaySize, display.width > 0, display.height > 0 else { return nil }
        guard let crop, !crop.isEmpty else { return display }
        return crop.rect(in: display).size
    }

    /// 此刻实际生效的画面摆放：用户摆过的优先；没摆过按默认布局换算。
    /// 预览里的选中框和拖动起点都从这里取，跟合成/导出的默认摆法一致。
    func resolvedPlacement(canvas: CGSize, isOverlay: Bool) -> ClipPlacement {
        placement ?? defaultPlacement(canvas: canvas, isOverlay: isOverlay)
    }

    /// 默认布局：主轨等比铺满居中，画中画按 `overlayFraction` 宽度停靠九宫格。
    /// 裁切过的段按**裁后的宽高比**摆（裁成 1:1 就显示成正方形）。
    /// Inspector 的 Scale/Position 以它为 100%/原点基准。
    func defaultPlacement(canvas: CGSize, isOverlay: Bool) -> ClipPlacement {
        guard let display = croppedDisplaySize,
              canvas.width > 0, canvas.height > 0 else {
            return ClipPlacement(centerX: 0.5, centerY: 0.5, width: 1, height: 1)
        }
        if isOverlay {
            let scale = canvas.width * overlayFraction / display.width
            let size = CGSize(width: display.width * scale, height: display.height * scale)
            let origin = overlayAnchor.origin(canvas: canvas, overlay: size, inset: canvas.width * 0.02)
            return ClipPlacement(frame: CGRect(origin: origin, size: size), in: canvas)
        }
        let scale = min(canvas.width / display.width, canvas.height / display.height)
        return ClipPlacement(
            centerX: 0.5,
            centerY: 0.5,
            width: display.width * scale / canvas.width,
            height: display.height * scale / canvas.height
        )
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

// MARK: - 选中导出的子集

extension TimelineState {
    /// 只含 `ids` 的时间线（平移到 0 起点），「Selected only」导出用。
    ///
    /// 只选了画中画不选主轨时，把最下面那条画中画升为主轨 —— 「导出单个视频」
    /// 拿到的就是完整画面而不是黑底小窗。所以**升轨的段必须丢掉自由摆放
    /// （placement）**：那是相对完整画面摆的，画面本身都不在这次导出里。
    /// 没升轨的画中画保持原样（含摆放），所见即所得。
    func selectionForExport(ids: Set<UUID>) -> TimelineState {
        let picked = allClips.filter { ids.contains($0.id) }
        guard let earliest = picked.map(\.timelineStart).min() else { return self }

        func shifted(_ clip: EditClip) -> EditClip {
            var copy = clip
            copy.timelineStart -= earliest
            copy.transitionAfter = .none
            return copy
        }

        var sub = TimelineState()
        sub.mainClips = mainClips.filter { ids.contains($0.id) }.map(shifted)
        for lane in overlayTracks where !lane.isHidden {
            let clips = lane.clips.filter { ids.contains($0.id) }.map(shifted)
            if !clips.isEmpty { sub.overlayTracks.append(EditLane(clips: clips)) }
        }
        for lane in audioTracks where !lane.isHidden {
            let clips = lane.clips.filter { ids.contains($0.id) }.map(shifted)
            if !clips.isEmpty { sub.audioTracks.append(EditLane(clips: clips)) }
        }
        if sub.mainClips.isEmpty, !sub.overlayTracks.isEmpty {
            sub.mainClips = sub.overlayTracks.removeFirst().clips.map { clip in
                var promoted = clip
                // 摆放/旋转/透明度是相对完整画面的，画面不在这次导出里，丢掉；
                // 裁切和翻转是内容本身的属性，保留。
                promoted.placement = nil
                promoted.rotationDegrees = 0
                promoted.opacity = 1
                return promoted
            }
        }
        sub.canvasRatio = canvasRatio
        // 只挑了主轨内容时拼紧凑（多选导出＝顺序拼接）；带着画中画/音频时保持相对位置。
        if sub.overlayTracks.isEmpty, sub.audioTracks.isEmpty {
            sub.packMain()
        }
        return sub
    }
}

// MARK: - 存盘（.srtflowproj）
//
// 工程文件是长期格式，读旧文件不能因为「多了/少了一个字段」就整份打不开，
// 所以这里全部手写宽容解码：缺的字段取默认值，不认识的枚举值退回兜底项。
// 有默认值的新字段可以随便加，老工程照样能开。

/// 读到不认识的原始值时退回默认项，而不是让整份工程解不开。
protocol LenientCodableEnum: RawRepresentable, Codable where RawValue == String {
    static var decodingFallback: Self { get }
}

extension LenientCodableEnum {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? Self.decodingFallback
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension ClipTransition: LenientCodableEnum {
    static var decodingFallback: ClipTransition { .none }
}

extension OverlayAnchor: LenientCodableEnum {
    static var decodingFallback: OverlayAnchor { .topTrailing }
}

extension CanvasRatio: LenientCodableEnum {
    static var decodingFallback: CanvasRatio { .auto }
}

extension ShapeKind: LenientCodableEnum {
    static var decodingFallback: ShapeKind { .rectangle }
}

extension ShapeAnnotation: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, kind, timelineStart, duration, color, lineWidth
        case centerX, centerY, width, height, rotationDegrees
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            kind: try c.decodeIfPresent(ShapeKind.self, forKey: .kind) ?? .rectangle,
            timelineStart: try c.decodeIfPresent(Double.self, forKey: .timelineStart) ?? 0,
            duration: try c.decodeIfPresent(Double.self, forKey: .duration) ?? 3,
            color: try c.decodeIfPresent(SubtitleColor.self, forKey: .color) ?? .yellow,
            lineWidth: try c.decodeIfPresent(Double.self, forKey: .lineWidth) ?? 6,
            centerX: try c.decodeIfPresent(Double.self, forKey: .centerX) ?? 0.5,
            centerY: try c.decodeIfPresent(Double.self, forKey: .centerY) ?? 0.5,
            width: try c.decodeIfPresent(Double.self, forKey: .width) ?? 0.3,
            height: try c.decodeIfPresent(Double.self, forKey: .height) ?? 0.2,
            rotationDegrees: try c.decodeIfPresent(Double.self, forKey: .rotationDegrees) ?? 0
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(timelineStart, forKey: .timelineStart)
        try c.encode(duration, forKey: .duration)
        try c.encode(color, forKey: .color)
        try c.encode(lineWidth, forKey: .lineWidth)
        try c.encode(centerX, forKey: .centerX)
        try c.encode(centerY, forKey: .centerY)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(rotationDegrees, forKey: .rotationDegrees)
    }
}

extension ClipPlacement: Codable {
    private enum CodingKeys: String, CodingKey {
        case centerX, centerY, width, height
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            centerX: try c.decodeIfPresent(Double.self, forKey: .centerX) ?? 0.5,
            centerY: try c.decodeIfPresent(Double.self, forKey: .centerY) ?? 0.5,
            width: try c.decodeIfPresent(Double.self, forKey: .width) ?? 1,
            height: try c.decodeIfPresent(Double.self, forKey: .height) ?? 1
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(centerX, forKey: .centerX)
        try c.encode(centerY, forKey: .centerY)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
    }
}

extension ClipCrop: Codable {
    private enum CodingKeys: String, CodingKey {
        case top, bottom, leading, trailing
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            top: try c.decodeIfPresent(Double.self, forKey: .top) ?? 0,
            bottom: try c.decodeIfPresent(Double.self, forKey: .bottom) ?? 0,
            leading: try c.decodeIfPresent(Double.self, forKey: .leading) ?? 0,
            trailing: try c.decodeIfPresent(Double.self, forKey: .trailing) ?? 0
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(top, forKey: .top)
        try c.encode(bottom, forKey: .bottom)
        try c.encode(leading, forKey: .leading)
        try c.encode(trailing, forKey: .trailing)
    }
}

extension EditClip: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, sourceURL, isAudioOnly, sourceStart, sourceDuration, speed, timelineStart
        case isMuted, volume, linkGroup, transitionAfter, transitionDuration
        case overlayFraction, overlayAnchor, placement, info, audioAssetDuration, stillImageURL
        case rotationDegrees, opacity, flippedHorizontally, flippedVertically, crop
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 素材路径是唯一必需的字段：没有它这段就不成立。
        self.init(
            id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            sourceURL: try c.decode(URL.self, forKey: .sourceURL),
            isAudioOnly: try c.decodeIfPresent(Bool.self, forKey: .isAudioOnly) ?? false,
            sourceStart: try c.decodeIfPresent(Double.self, forKey: .sourceStart) ?? 0,
            sourceDuration: try c.decodeIfPresent(Double.self, forKey: .sourceDuration) ?? 0,
            speed: try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1,
            timelineStart: try c.decodeIfPresent(Double.self, forKey: .timelineStart) ?? 0,
            isMuted: try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false,
            volume: try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1,
            linkGroup: try c.decodeIfPresent(UUID.self, forKey: .linkGroup),
            transitionAfter: try c.decodeIfPresent(ClipTransition.self, forKey: .transitionAfter) ?? .none,
            transitionDuration: try c.decodeIfPresent(Double.self, forKey: .transitionDuration) ?? 0.5,
            overlayFraction: try c.decodeIfPresent(Double.self, forKey: .overlayFraction) ?? 0.4,
            overlayAnchor: try c.decodeIfPresent(OverlayAnchor.self, forKey: .overlayAnchor) ?? .topTrailing,
            placement: try c.decodeIfPresent(ClipPlacement.self, forKey: .placement),
            rotationDegrees: try c.decodeIfPresent(Double.self, forKey: .rotationDegrees) ?? 0,
            opacity: try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1,
            flippedHorizontally: try c.decodeIfPresent(Bool.self, forKey: .flippedHorizontally) ?? false,
            flippedVertically: try c.decodeIfPresent(Bool.self, forKey: .flippedVertically) ?? false,
            crop: try c.decodeIfPresent(ClipCrop.self, forKey: .crop),
            info: try c.decodeIfPresent(MediaInfo.self, forKey: .info),
            audioAssetDuration: try c.decodeIfPresent(Double.self, forKey: .audioAssetDuration),
            stillImageURL: try c.decodeIfPresent(URL.self, forKey: .stillImageURL)
        )
        // `needsStillConversion` 是导入过程中的临时状态，不存盘：打开工程时
        // 静帧视频是现查缓存现补的（见 VideoEditProjectFile.restoreStillClips）。
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sourceURL, forKey: .sourceURL)
        try c.encode(isAudioOnly, forKey: .isAudioOnly)
        try c.encode(sourceStart, forKey: .sourceStart)
        try c.encode(sourceDuration, forKey: .sourceDuration)
        try c.encode(speed, forKey: .speed)
        try c.encode(timelineStart, forKey: .timelineStart)
        try c.encode(isMuted, forKey: .isMuted)
        try c.encode(volume, forKey: .volume)
        try c.encodeIfPresent(linkGroup, forKey: .linkGroup)
        try c.encode(transitionAfter, forKey: .transitionAfter)
        try c.encode(transitionDuration, forKey: .transitionDuration)
        try c.encode(overlayFraction, forKey: .overlayFraction)
        try c.encode(overlayAnchor, forKey: .overlayAnchor)
        try c.encodeIfPresent(placement, forKey: .placement)
        try c.encode(rotationDegrees, forKey: .rotationDegrees)
        try c.encode(opacity, forKey: .opacity)
        try c.encode(flippedHorizontally, forKey: .flippedHorizontally)
        try c.encode(flippedVertically, forKey: .flippedVertically)
        try c.encodeIfPresent(crop, forKey: .crop)
        try c.encodeIfPresent(info, forKey: .info)
        try c.encodeIfPresent(audioAssetDuration, forKey: .audioAssetDuration)
        try c.encodeIfPresent(stillImageURL, forKey: .stillImageURL)
    }
}

extension EditLane: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, clips, isHidden
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            clips: try c.decodeIfPresent([EditClip].self, forKey: .clips) ?? [],
            isHidden: try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(clips, forKey: .clips)
        try c.encode(isHidden, forKey: .isHidden)
    }
}

extension TimelineState: Codable {
    private enum CodingKeys: String, CodingKey {
        case mainClips, mainHidden, overlayTracks, audioTracks
        case subtitle, subtitleURL, shapes, canvasRatio
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        mainClips = try c.decodeIfPresent([EditClip].self, forKey: .mainClips) ?? []
        mainHidden = try c.decodeIfPresent(Bool.self, forKey: .mainHidden) ?? false
        overlayTracks = try c.decodeIfPresent([EditLane].self, forKey: .overlayTracks) ?? []
        audioTracks = try c.decodeIfPresent([EditLane].self, forKey: .audioTracks) ?? []
        subtitle = try c.decodeIfPresent(SubtitleDocumentModel.self, forKey: .subtitle)
        subtitleURL = try c.decodeIfPresent(URL.self, forKey: .subtitleURL)
        shapes = try c.decodeIfPresent([ShapeAnnotation].self, forKey: .shapes) ?? []
        canvasRatio = try c.decodeIfPresent(CanvasRatio.self, forKey: .canvasRatio) ?? .auto
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mainClips, forKey: .mainClips)
        try c.encode(mainHidden, forKey: .mainHidden)
        try c.encode(overlayTracks, forKey: .overlayTracks)
        try c.encode(audioTracks, forKey: .audioTracks)
        try c.encodeIfPresent(subtitle, forKey: .subtitle)
        try c.encodeIfPresent(subtitleURL, forKey: .subtitleURL)
        try c.encode(shapes, forKey: .shapes)
        try c.encode(canvasRatio, forKey: .canvasRatio)
    }
}

/// 时间线里出现的所有素材路径（含字幕文件）。存盘时给它们各配一份书签。
extension TimelineState {
    var mediaURLs: [URL] {
        var seen = Set<URL>()
        var result: [URL] = []
        func add(_ url: URL?) {
            guard let url, !seen.contains(url) else { return }
            seen.insert(url)
            result.append(url)
        }
        for clip in allClips {
            // 图片段存的是原图，不是生成出来的静帧视频（那个是缓存，能重生成）。
            if let image = clip.stillImageURL {
                add(image)
            } else {
                add(clip.sourceURL)
            }
        }
        add(subtitleURL)
        return result
    }

    /// 把所有指向 `old` 的引用改成 `new`。重新链接素材时用。
    mutating func replaceMedia(_ old: URL, with new: URL) {
        func fix(_ clip: inout EditClip) {
            if clip.stillImageURL == old {
                clip.stillImageURL = new
            } else if clip.sourceURL == old {
                clip.sourceURL = new
            }
        }
        for index in mainClips.indices { fix(&mainClips[index]) }
        for lane in overlayTracks.indices {
            for index in overlayTracks[lane].clips.indices { fix(&overlayTracks[lane].clips[index]) }
        }
        for lane in audioTracks.indices {
            for index in audioTracks[lane].clips.indices { fix(&audioTracks[lane].clips[index]) }
        }
        if subtitleURL == old { subtitleURL = new }
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
