import Foundation
import SrtFlowCore

// MARK: - 转场

/// 主轨相邻两段之间的转场。
///
/// 全部按「重叠 d 秒」来算：前一段的尾巴和后一段的开头叠在一起渐变/推移/擦除。
/// 这样预览（AVFoundation 斜坡）和导出（ffmpeg xfade）的时间账完全一致。
/// 预览侧三族的合成模型见 docs/architecture/preview-free-transform.md。
///
/// 方向语义与 xfade 实测对齐（2026-08-23 纯色实测）：名字里的方向 = 画面内容
/// / 擦除边的运动方向。pushLeft/wipeLeft 后段从**右**边进来，以此类推。
enum ClipTransition: String, CaseIterable, Identifiable, Hashable, Sendable {
    case none
    case crossFade
    case blackFade
    case whiteFade
    case pushLeft
    case pushRight
    case pushUp
    case pushDown
    case wipeLeft
    case wipeRight
    case wipeUp
    case wipeDown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .blackFade: return "Black fade"
        case .crossFade: return "Cross dissolve"
        case .whiteFade: return "White fade"
        case .pushLeft: return "Push left"
        case .pushRight: return "Push right"
        case .pushUp: return "Push up"
        case .pushDown: return "Push down"
        case .wipeLeft: return "Wipe left"
        case .wipeRight: return "Wipe right"
        case .wipeUp: return "Wipe up"
        case .wipeDown: return "Wipe down"
        }
    }

    /// ffmpeg `xfade` 滤镜里对应的名字。
    var xfadeName: String? {
        switch self {
        case .none: return nil
        case .blackFade: return "fadeblack"
        case .crossFade: return "fade"
        case .whiteFade: return "fadewhite"
        case .pushLeft: return "slideleft"
        case .pushRight: return "slideright"
        case .pushUp: return "slideup"
        case .pushDown: return "slidedown"
        case .wipeLeft: return "wipeleft"
        case .wipeRight: return "wiperight"
        case .wipeUp: return "wipeup"
        case .wipeDown: return "wipedown"
        }
    }

    /// 三族：淡变（透明度）、推移（平移）、擦除（裁切窗口）。选择器分组
    /// 和预览合成的路径分派都以它为准。
    enum Family {
        case fade, push, wipe
    }

    var family: Family {
        switch self {
        case .none, .crossFade, .blackFade, .whiteFade: return .fade
        case .pushLeft, .pushRight, .pushUp, .pushDown: return .push
        case .wipeLeft, .wipeRight, .wipeUp, .wipeDown: return .wipe
        }
    }

    /// 推移的内容运动方向 / 擦除边的运动方向（单位向量，视频坐标 y 向下）。
    /// 淡变族没有方向。
    var motion: (dx: CGFloat, dy: CGFloat)? {
        switch self {
        case .pushLeft, .wipeLeft: return (-1, 0)
        case .pushRight, .wipeRight: return (1, 0)
        case .pushUp, .wipeUp: return (0, -1)
        case .pushDown, .wipeDown: return (0, 1)
        case .none, .crossFade, .blackFade, .whiteFade: return nil
        }
    }

    /// 擦除到进度 p 时，**出场段**还占着的画布区（进场段从对面那条边露出来）。
    func wipeRemainingRect(progress: Double, canvas: CGSize) -> CGRect {
        let p = min(max(progress, 0), 1)
        guard let motion else { return CGRect(origin: .zero, size: canvas) }
        if motion.dx < 0 {
            return CGRect(x: 0, y: 0, width: canvas.width * (1 - p), height: canvas.height)
        } else if motion.dx > 0 {
            return CGRect(x: canvas.width * p, y: 0, width: canvas.width * (1 - p), height: canvas.height)
        } else if motion.dy < 0 {
            return CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height * (1 - p))
        } else {
            return CGRect(x: 0, y: canvas.height * p, width: canvas.width, height: canvas.height * (1 - p))
        }
    }
}

// MARK: - 自由变换

/// 画面段在输出画布上的自由摆放：中心和宽高都是相对画布的 0…1 归一化值。
///
/// `nil`（不设）表示默认布局 —— 等比铺满居中（所有视频轨同一份账）。
/// 一旦用户在预览里拖过缩放框，
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
    /// 声音的渐入/渐出时长，单位是**时间线秒**（变速之后）。0 = 关。
    /// 生效值要走 `audioFades` 夹紧，规则见 VideoEditAudioFade.swift。
    var fadeInDuration: Double
    var fadeOutDuration: Double
    /// 同组的剪辑（分离出的音频）在「链接」开着时一起移动、分割、删除。
    var linkGroup: UUID?

    /// 这段和**下一段**之间的转场，只对主轨有意义。
    var transitionAfter: ClipTransition
    var transitionDuration: Double

    /// 画面的渐入/渐出时长，单位是**时间线秒**（变速之后）。0 = 关。
    /// 生效值要走 `videoFades` 夹紧，规则见 VideoEditVideoFade.swift。
    var videoFadeInDuration: Double
    var videoFadeOutDuration: Double

    /// 用户在预览里摆过的自由位置/尺寸；nil = 默认布局（等比铺满居中）。
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
    /// 关键帧动画（位置/缩放/旋转/不透明度）；nil = 无。类型与取值见
    /// VideoEditAnimation.swift。
    var animation: ClipAnimation?
    /// 预设的入场 / 出场动画（Inspector 的 Animation 区）。**时长不在这里**，
    /// 它和画面渐变共用 `videoFadeInDuration/OutDuration`；类型与仲裁见
    /// VideoEditClipAnimation.swift，逐帧求值见 VideoEditClipAnimator.swift。
    ///
    /// 不进 `init`（同 `markers`）：绝大多数段没设动画，摊进按成员构造器只会让
    /// 每个调用点都要多写一行。
    var presetAnimation: ClipPresetAnimation = .default

    /// 用户打在这段素材上的标记。锚在源时间上，只影响编辑期的显示，不进合成
    /// 和导出。类型与读写见 VideoEditClipMarker.swift。
    var markers: [ClipMarker] = []

    /// 这一段**单独**隐藏（快捷键 V）。画面和声音都不进预览、不进成片 —— 与整轨
    /// 隐藏同一个心智，只是单位从一条轨变成一段素材。
    ///
    /// 隐藏的段在时间线上**仍然可选、可拖、可裁**（只是灰显 + 一枚斜杠眼睛）。
    /// 整轨隐藏那边是「灰显且不可编辑」，这里刻意不同：按完 V 就再也点不中它的话，
    /// 用户只能靠撤销把它找回来。
    ///
    /// 与 `EditLane.isHidden` / `mainHidden` **互不覆盖**：轨隐藏了，段上的这个
    /// 标记原样留着；轨放出来，之前单独藏起来的段还是藏着。
    ///
    /// 不进 `init`（同 `markers` / `presetAnimation`）：绝大多数段没隐藏，摊进
    /// 按成员构造器只会让每个调用点都多写一行。合同见
    /// docs/architecture/clip-visibility.md。
    var isHidden = false

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
        fadeInDuration: Double = 0,
        fadeOutDuration: Double = 0,
        linkGroup: UUID? = nil,
        transitionAfter: ClipTransition = .none,
        transitionDuration: Double = 0.5,
        videoFadeInDuration: Double = 0,
        videoFadeOutDuration: Double = 0,
        placement: ClipPlacement? = nil,
        rotationDegrees: Double = 0,
        opacity: Double = 1,
        flippedHorizontally: Bool = false,
        flippedVertically: Bool = false,
        crop: ClipCrop? = nil,
        animation: ClipAnimation? = nil,
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
        self.fadeInDuration = fadeInDuration
        self.fadeOutDuration = fadeOutDuration
        self.linkGroup = linkGroup
        self.transitionAfter = transitionAfter
        self.transitionDuration = transitionDuration
        self.videoFadeInDuration = videoFadeInDuration
        self.videoFadeOutDuration = videoFadeOutDuration
        self.placement = placement
        self.rotationDegrees = rotationDegrees
        self.opacity = opacity
        self.flippedHorizontally = flippedHorizontally
        self.flippedVertically = flippedVertically
        self.crop = crop
        self.animation = animation
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
    ///
    /// 画面渐变也算：它要在 rgba 上做 alpha 斜坡，只有变换链那条路会先
    /// `format=rgba`，轻量路径挂不上 `fade`（见 VideoEditVideoFade.swift）。
    ///
    /// **预设入/出场动画不必单列**：要逐帧的效果一律走预渲染，根本到不了这条
    /// 判据；而它的时长就是 `videoFade*`，`hasVideoFade` 已经把它覆盖住了。
    var hasVisualTransform: Bool {
        placement != nil || abs(rotationDegrees) > 0.01 || opacity < 0.999
            || flippedHorizontally || flippedVertically || !(crop?.isEmpty ?? true)
            || isAnimated || hasVideoFade
    }

    /// 这段的画面把整个画布**盖满且完全不透明**吗。
    ///
    /// 叠化的「后段垫底、前段淡出」路径只有在接缝两侧都满足这个条件时才逐像素
    /// 精确等于 xfade dissolve —— 判定条件必须是它，不能拿 `hasVisualTransform`
    /// 凑数：仅翻转（甚至放大出画布的摆放）照样满幅不透明，走近似路径纯属
    /// 误伤（白闪变暗）。旋转保守地一律当不满幅；带关键帧动画或预设入/出场
    /// 动画的段同样保守走近似路径（逐时刻判定不值得）。
    func coversCanvasOpaquely(canvas: CGSize) -> Bool {
        guard opacity >= 0.999, abs(rotationDegrees) <= 0.01, !isAnimated,
              !hasVideoFade, !needsPerFrameAnimation else { return false }
        let frame = resolvedPlacement(canvas: canvas).frame(in: canvas)
        return frame.minX <= 0.5 && frame.minY <= 0.5
            && frame.maxX >= canvas.width - 0.5 && frame.maxY >= canvas.height - 0.5
    }

    /// 裁切后的源画面尺寸（显示方向）。默认摆放框按它算宽高比。
    var croppedDisplaySize: CGSize? {
        guard let display = info?.displaySize, display.width > 0, display.height > 0 else { return nil }
        guard let crop, !crop.isEmpty else { return display }
        return crop.rect(in: display).size
    }

    /// 此刻实际生效的画面摆放：用户摆过的优先；没摆过按默认布局换算。
    /// 预览里的选中框和拖动起点都从这里取，跟合成/导出的默认摆法一致。
    func resolvedPlacement(canvas: CGSize) -> ClipPlacement {
        placement ?? defaultPlacement(canvas: canvas)
    }

    /// 默认布局：等比铺满画布、居中，**不分轨道**。
    ///
    /// 上层视频轨和主轨走完全同一份账（2026-09-17 起）—— 上层轨不再是「画中画」，
    /// 它就是另一条对等的视频轨，内容一样铺满画面。等比是 contain：比例对不上
    /// 的素材两侧留空，**留空处不画黑**，露出的是下面那一层（主轨的下面是画布
    /// 黑底，上层轨的下面是主轨画面）—— 这来自 overlay 合成本身，不要额外补
    /// `pad`，补了就会把下层遮死。
    ///
    /// 裁切过的段按**裁后的宽高比**摆（裁成 1:1 就显示成正方形）。
    /// Inspector 的 Scale/Position 以它为 100%/原点基准。
    func defaultPlacement(canvas: CGSize) -> ClipPlacement {
        guard let display = croppedDisplaySize,
              canvas.width > 0, canvas.height > 0 else {
            return ClipPlacement(centerX: 0.5, centerY: 0.5, width: 1, height: 1)
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

/// 一条上层视频轨或音频轨：有身份（行的增删不串号）、可整轨隐藏、有自己的颜色。
struct EditLane: Identifiable, Hashable, Sendable {
    let id: UUID
    var clips: [EditClip]
    /// 隐藏的轨：灰显不可编辑，预览和导出都当它不存在。
    var isHidden: Bool
    /// 这条轨在时间线上的颜色号（见 TrackPalette）。
    ///
    /// nil = 还没补号：新 append 出来的轨、以及 2026-09-17 之前存的老工程。
    /// `assignMissingTrackColors()` 会在读盘和每次状态提交后补上，补过就不再动
    /// —— 颜色必须绑轨道身份，绑行号的话删掉中间一条轨会让下面所有轨换色。
    var colorIndex: Int?

    init(id: UUID = UUID(), clips: [EditClip] = [], isHidden: Bool = false, colorIndex: Int? = nil) {
        self.id = id
        self.clips = clips
        self.isHidden = isHidden
        self.colorIndex = colorIndex
    }
}

/// 一份完整的时间线。撤销/重做就是整个换掉它，所以全部是值类型。
struct TimelineState: Hashable, Sendable {
    /// 主视频轨。数组顺序就是时间顺序；磁吸开着时位置由 `packMain` 排。
    var mainClips: [EditClip] = []
    /// 主轨的整轨隐藏（预览成黑场，导出跳过）。
    var mainHidden = false
    /// 上层视频轨（可以有多条，叠放顺序：靠后的画在上面）。
    /// 与主轨**对等** —— 内容一样铺满画面，只有叠放次序的差别。
    var overlayTracks: [EditLane] = []
    /// 音频轨（背景音乐、分离出的人声等）。
    var audioTracks: [EditLane] = []

    var subtitle: SubtitleDocumentModel?
    /// **原文**字幕轨的眼睛（与 mainHidden 同语义：预览不渲染、导出不烧录；
    /// 独立字幕文件导出不受影响 —— 那是对数据的显式操作，不是可见性）。
    var subtitleHidden = false
    /// **译文**字幕轨的眼睛。一个语言一条轨，各自一只眼睛：
    /// 两只都开=双语、只开一只=那一条、都关=不显示（也不烧录）。
    /// 译文轨不存在时这个值没有意义（UI 也不渲染那一行）。
    ///
    /// v7 字段：它决定成片里有没有译文，旧版丢掉它会改变导出画面。
    /// 读 v6 及更早的工程时**回退成 true** —— 那些版本的默认预览/烧录是
    /// 「只有原文」，升级不该把谁的成片悄悄变成双语（迁移在
    /// `VideoEditProjectIO.load`）。
    var translationHidden = false
    /// 工程级字幕布局覆盖（预览拖框的产物，SrtFlowCore/SubtitleLayout）。
    /// nil = 全局烧录样式原样；预览和烧录共用同一份。
    var subtitleLayout: SubtitleLayout?
    var subtitleURL: URL?
    /// 原文字幕的伴随状态（译文轨/cueMeta/生成参数）。原文永远在 `subtitle`；
    /// 这是 v4-only 字段（见 VideoEditFormatVersion.swift 的登记清单）。
    var subtitleCompanion: SubtitleCompanion?
    /// 画面上的形状标注。
    var shapes: [ShapeAnnotation] = []
    /// 画面上的文字标注。数组顺序就是叠放次序（靠后的画在上面）。
    /// 整体压在形状之上、字幕之下，见 docs/architecture/text-overlays.md。
    var textOverlays: [TextOverlay] = []
    /// 时间轴上的调色段。作用于自己那段时间里的**全部画面**（主轨 + 上层轨），
    /// 不染形状/文字/字幕。叠加顺序由 `FilterClip.layer` 决定，
    /// 见 docs/architecture/filters.md。
    /// 这是 v17-only 字段（见 VideoEditFormatVersion.swift 的登记清单）。
    var filters: [FilterClip] = []
    /// 输出画面比例（预览和导出共用）。
    var canvasRatio: CanvasRatio = .auto
    /// 工程帧率：预览合成、两条导出管线、预渲染、关键帧容差的唯一事实来源。
    /// 这是 v5-only 字段（见 VideoEditFormatVersion.swift 的登记清单）。
    var frameRate: ProjectFrameRate = .fallback

    var isEmpty: Bool {
        mainClips.isEmpty && overlayTracks.allSatisfy(\.clips.isEmpty)
            && audioTracks.allSatisfy(\.clips.isEmpty) && subtitle == nil && shapes.isEmpty
            && textOverlays.isEmpty && filters.isEmpty
    }

    /// 整条时间线的长度：所有轨里最晚结束的那一刻。
    var duration: Double {
        var end = mainClips.map(\.timelineEnd).max() ?? 0
        for lane in overlayTracks { end = max(end, lane.clips.map(\.timelineEnd).max() ?? 0) }
        for lane in audioTracks { end = max(end, lane.clips.map(\.timelineEnd).max() ?? 0) }
        for shape in shapes { end = max(end, shape.timelineEnd) }
        for text in textOverlays { end = max(end, text.timelineEnd) }
        // **滤镜段不算**（产品口径，2026-09-21 拍板）：形状和文字自己就是画面，
        // 拖到末尾之后理应把成片拉长；滤镜只是调色，染一段空白没有意义，
        // 把工程撑长反而会凭空多出一截黑场。
        return end
    }

    mutating func updateShape(_ id: UUID, _ change: (inout ShapeAnnotation) -> Void) {
        guard let index = shapes.firstIndex(where: { $0.id == id }) else { return }
        change(&shapes[index])
        // 正方形永远保持正方形。
        if shapes[index].kind == .square { shapes[index].height = shapes[index].width }
    }

    mutating func updateTextOverlay(_ id: UUID, _ change: (inout TextOverlay) -> Void) {
        guard let index = textOverlays.firstIndex(where: { $0.id == id }) else { return }
        change(&textOverlays[index])
        // 收口放在这里而不是各个调用点：画面拖拽、检查器、就地编辑三条路
        // 都要落到同一份夹紧上，分开写迟早分叉。
        textOverlays[index].clampToValidRange()
    }

    // MARK: 主轨排列

    /// 磁吸：主轨各段首尾相接，有转场的地方按转场时长叠进去。
    mutating func packMain() {
        for (index, start) in Self.packedStarts(mainClips).enumerated() {
            mainClips[index].timelineStart = start
        }
    }

    /// 这组块首尾相接（转场按 xfade 的收紧规则叠掉）后各自的起点。
    ///
    /// **磁吸排列和拖动中的主轨插入指示线共用这一份**。指示线必须在「插入之后的
    /// 最终数组」上调它 —— 插进来的短块会改变相邻关系，能叠掉的量跟着变
    /// （45% 是按**两边**任一段收紧的），拿插入前的数组算出来的缝会说谎。
    static func packedStarts(_ clips: [EditClip]) -> [Double] {
        var starts: [Double] = []
        starts.reserveCapacity(clips.count)
        var cursor = 0.0
        for index in clips.indices {
            starts.append(cursor)
            cursor += clips[index].timelineDuration - transitionOverlap(in: clips, afterIndex: index)
        }
        return starts
    }

    /// 第 index 段和下一段之间实际叠掉的时长。
    ///
    /// xfade 要求叠的部分不能超过两边任何一段，这里再收紧到 45%，
    /// 免得一段短素材被两头的转场吃光。
    func transitionOverlap(afterMainIndex index: Int) -> Double {
        Self.transitionOverlap(in: mainClips, afterIndex: index)
    }

    /// 同上，但对任意一组「排成主轨」的块算 —— 拖动中的插入位置预览
    /// （`TimelineSnap.mainInsertion`）要在**去掉被拖块**的数组上重算一遍游标。
    /// 公式只有这一份：预览和 `packMain` 用同一个，才不会指示线在这、落点在那。
    static func transitionOverlap(in clips: [EditClip], afterIndex index: Int) -> Double {
        guard index >= 0, index + 1 < clips.count else { return 0 }
        let clip = clips[index]
        guard clip.transitionAfter != .none else { return 0 }
        return min(
            clip.transitionDuration,
            clip.timelineDuration * 0.45,
            clips[index + 1].timelineDuration * 0.45
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

    /// 清掉空出来的上层视频轨/音频轨，别让界面上留一排空槽。
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
    /// 只选了上层轨不选主轨时，把最下面那条上层轨升为主轨 —— 「导出单个视频」
    /// 拿到的就是完整画面而不是黑底小窗。所以**升轨的段必须丢掉自由摆放
    /// （placement）**：那是相对完整画面摆的，画面本身都不在这次导出里。
    /// 没升轨的上层轨保持原样（含摆放），所见即所得。
    func selectionForExport(ids: Set<UUID>) -> TimelineState {
        // 起点按**真的会导出的**段算。把隐藏的段算进来的话，藏在最前面的那一段
        // 会把整条子时间线往后推，成片开头多出一截黑场。
        let picked = ClipVisibility.visible(allClips.filter { ids.contains($0.id) })
        guard let earliest = picked.map(\.timelineStart).min() else {
            // 选中的全是隐藏的段：给一份空的时间线，让导出当场报「先加一段素材」。
            // 这里**不能 return self** —— 那会把整条时间线导出去，而用户点的是
            // 「只导出选中的」（同 needsStillConversion 那条：宁可拦下来说清楚，
            // 也不要「导出成功」但内容不是他要的）。
            var empty = TimelineState()
            empty.canvasRatio = canvasRatio
            empty.frameRate = frameRate
            return empty
        }

        func shifted(_ clip: EditClip) -> EditClip {
            var copy = clip
            copy.timelineStart -= earliest
            copy.transitionAfter = .none
            return copy
        }

        // 隐藏的段（单段的 V，和整轨的眼睛）一律不进这份子时间线：所见即所得，
        // 「只导出选中的」不该把用户明明藏起来的东西导出去。
        var sub = TimelineState()
        sub.mainClips = ClipVisibility.visible(mainClips.filter { ids.contains($0.id) }).map(shifted)
        for lane in overlayTracks where !lane.isHidden {
            let clips = ClipVisibility.visible(lane.clips.filter { ids.contains($0.id) }).map(shifted)
            if !clips.isEmpty { sub.overlayTracks.append(EditLane(clips: clips)) }
        }
        for lane in audioTracks where !lane.isHidden {
            let clips = ClipVisibility.visible(lane.clips.filter { ids.contains($0.id) }).map(shifted)
            if !clips.isEmpty { sub.audioTracks.append(EditLane(clips: clips)) }
        }
        if sub.mainClips.isEmpty, !sub.overlayTracks.isEmpty {
            sub.mainClips = sub.overlayTracks.removeFirst().clips.map { clip in
                var promoted = clip
                // 摆放/旋转/透明度和它们的动画都是相对完整画面的，画面不在
                // 这次导出里，丢掉；裁切和翻转是内容本身的属性，保留。
                promoted.placement = nil
                promoted.rotationDegrees = 0
                promoted.opacity = 1
                promoted.animation = nil
                return promoted
            }
        }
        // 滤镜跟着**画面**走，不要求用户额外选中它：它挂在时间范围上而不是挂在
        // 某个片段上，「只导出选中的」当然该带着这段画面的调色一起走。
        //
        // 两种映射，判据就是下面那句 `packMain()` 跑不跑：
        //
        // - **会拼紧凑时逐段映射**：选的段被拼拢之后，原来在第 3 段上的那截调色
        //   得跟着第 3 段挪到新位置。按时间平移是错的 —— 选了不连续的几段时，
        //   画面拼拢了、滤镜还站在原来的时刻，整个错位（2026-09-21 修）。
        //   一段滤镜可能因此裂成几截（跨了几段选中的画面），落在**没被选中的**
        //   那些时间上的部分直接丢掉：那段画面本来就不在这次导出里。
        // - **不拼紧凑时按原样平移**：那时片段保持相对位置，空隙也照样保留
        //   （上层轨可能正好在那儿有画面），所以不能按「主轨段」切。
        let willPack = sub.overlayTracks.isEmpty && sub.audioTracks.isEmpty
        if willPack, !sub.mainClips.isEmpty {
            // 拼紧凑之后每一段落在哪。和下面那句 `packMain()` 同一个函数，
            // 所以画面挪到哪儿、调色就挪到哪儿。
            let packedStarts = Self.packedStarts(sub.mainClips)
            var pieces: [FilterClip] = []
            for filter in filters {
                // 这一段滤镜刚刚落下的最后一截：紧挨着就续上去，别裂成一堆碎块。
                var openPiece: Int?
                for (index, clip) in sub.mainClips.enumerated() {
                    // `shifted` 把起点减去了 earliest，加回来才是原时间线上的位置。
                    let originalStart = clip.timelineStart + earliest
                    let originalEnd = originalStart + clip.timelineDuration
                    let low = max(filter.timelineStart, originalStart)
                    let high = min(filter.timelineEnd, originalEnd)
                    guard high - low > 0.001 else { openPiece = nil; continue }
                    let mappedStart = packedStarts[index] + (low - originalStart)
                    if let open = openPiece,
                       abs(pieces[open].timelineEnd - mappedStart) < 0.001 {
                        pieces[open].duration += high - low
                    } else {
                        pieces.append(FilterClip(
                            preset: filter.preset, strength: filter.strength,
                            timelineStart: mappedStart, duration: high - low,
                            layer: filter.layer
                        ))
                        openPiece = pieces.count - 1
                    }
                }
            }
            sub.filters = pieces
        } else {
            let windowStart = earliest
            let windowEnd = picked.map(\.timelineEnd).max() ?? earliest
            sub.filters = filters.compactMap { filter in
                let start = max(filter.timelineStart, windowStart)
                let end = min(filter.timelineEnd, windowEnd)
                guard end - start > 0.0005 else { return nil }
                var copy = filter
                copy.timelineStart = start - earliest
                copy.duration = end - start
                return copy
            }
        }
        // 整层都被切没了就把层号收拢，别在子时间线里留空层。
        sub.compactFilterLayers()
        sub.canvasRatio = canvasRatio
        // 帧率必须跟着走：漏了这一行，选段导出会退回默认 24，与工程规格不符。
        sub.frameRate = frameRate
        // 只挑了主轨内容时拼紧凑（多选导出＝顺序拼接）；带着上层轨/音频时保持相对位置。
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
        case placement, info, audioAssetDuration, stillImageURL
        case videoFadeInDuration, videoFadeOutDuration
        case rotationDegrees, opacity, flippedHorizontally, flippedVertically, crop, animation
        case presetAnimation
        case markers
        case fadeInDuration, fadeOutDuration
        case isHidden
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
            fadeInDuration: try c.decodeIfPresent(Double.self, forKey: .fadeInDuration) ?? 0,
            fadeOutDuration: try c.decodeIfPresent(Double.self, forKey: .fadeOutDuration) ?? 0,
            linkGroup: try c.decodeIfPresent(UUID.self, forKey: .linkGroup),
            transitionAfter: try c.decodeIfPresent(ClipTransition.self, forKey: .transitionAfter) ?? .none,
            transitionDuration: try c.decodeIfPresent(Double.self, forKey: .transitionDuration) ?? 0.5,
            videoFadeInDuration: try c.decodeIfPresent(Double.self, forKey: .videoFadeInDuration) ?? 0,
            videoFadeOutDuration: try c.decodeIfPresent(Double.self, forKey: .videoFadeOutDuration) ?? 0,
            placement: try c.decodeIfPresent(ClipPlacement.self, forKey: .placement),
            rotationDegrees: try c.decodeIfPresent(Double.self, forKey: .rotationDegrees) ?? 0,
            opacity: try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1,
            flippedHorizontally: try c.decodeIfPresent(Bool.self, forKey: .flippedHorizontally) ?? false,
            flippedVertically: try c.decodeIfPresent(Bool.self, forKey: .flippedVertically) ?? false,
            crop: try c.decodeIfPresent(ClipCrop.self, forKey: .crop),
            animation: try c.decodeIfPresent(ClipAnimation.self, forKey: .animation),
            info: try c.decodeIfPresent(MediaInfo.self, forKey: .info),
            audioAssetDuration: try c.decodeIfPresent(Double.self, forKey: .audioAssetDuration),
            stillImageURL: try c.decodeIfPresent(URL.self, forKey: .stillImageURL)
        )
        // `needsStillConversion` 是导入过程中的临时状态，不存盘：打开工程时
        // 静帧视频是现查缓存现补的（见 VideoEditProjectFile.restoreStillClips）。
        markers = try c.decodeIfPresent([ClipMarker].self, forKey: .markers) ?? []
        // 缺键 = 没隐藏。老工程（v15 及更早）根本没有这个概念，回退 false
        // 就是它们当时的渲染结果 —— 升级不改变谁已经做好的片子。
        isHidden = try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        // v14 及更早：画面渐变只有时长、没有"效果"这个概念。合并成一个槽之后，
        // 这些段就是 In/Out = Fade —— 不认回来的话，老工程一打开，调好的淡入淡出
        // 会因为 `kind == .none` 当场失效（不变量见 `ClipPresetAnimation.isEmpty`）。
        if let stored = try c.decodeIfPresent(ClipPresetAnimation.self, forKey: .presetAnimation) {
            presetAnimation = stored
        } else {
            presetAnimation = ClipPresetAnimation(
                entrance: videoFadeInDuration > 0 ? .fade : .none,
                exit: videoFadeOutDuration > 0 ? .fade : .none,
                intensity: ClipPresetAnimation.default.intensity
            )
        }
        presetAnimation.clampToValidRange()
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
        // 没设渐变的段不写这两个键：绝大多数段是 0，写出来只会把工程文件撑大。
        // 缺键按 0 解码，跟「关」完全同义，所以按需写是安全的。
        if fadeInDuration > 0 { try c.encode(fadeInDuration, forKey: .fadeInDuration) }
        if fadeOutDuration > 0 { try c.encode(fadeOutDuration, forKey: .fadeOutDuration) }
        // 同声音渐变：没隐藏的段不写这个键（绝大多数段都是），缺键按 false
        // 解码，与「没隐藏」完全同义。写了它的工程才算 v16 数据。
        if isHidden { try c.encode(isHidden, forKey: .isHidden) }
        try c.encodeIfPresent(linkGroup, forKey: .linkGroup)
        try c.encode(transitionAfter, forKey: .transitionAfter)
        try c.encode(transitionDuration, forKey: .transitionDuration)
        // 同声音渐变：没设的段不写键，缺键按 0 解码，与「关」完全同义。
        if videoFadeInDuration > 0 { try c.encode(videoFadeInDuration, forKey: .videoFadeInDuration) }
        if videoFadeOutDuration > 0 { try c.encode(videoFadeOutDuration, forKey: .videoFadeOutDuration) }
        try c.encodeIfPresent(placement, forKey: .placement)
        try c.encode(rotationDegrees, forKey: .rotationDegrees)
        try c.encode(opacity, forKey: .opacity)
        try c.encode(flippedHorizontally, forKey: .flippedHorizontally)
        try c.encode(flippedVertically, forKey: .flippedVertically)
        try c.encodeIfPresent(crop, forKey: .crop)
        try c.encodeIfPresent(isAnimated ? animation : nil, forKey: .animation)
        try c.encodeIfPresent(info, forKey: .info)
        try c.encodeIfPresent(audioAssetDuration, forKey: .audioAssetDuration)
        try c.encodeIfPresent(stillImageURL, forKey: .stillImageURL)
        // 没有标记的段不写这个键：绝大多数工程一枚标记都没有，键写出来只是把
        // 每段的 JSON 撑大一行。
        if !markers.isEmpty { try c.encode(markers, forKey: .markers) }
        // 没设入/出场效果的段不写这个键（判据是 `isEmpty`，与格式版本闸门
        // `requiresFormatVersion15` 同源）：强度是跟着效果走的，没效果时它的值
        // 不影响任何一帧画面，写出来只会把每段的 JSON 撑大一行。
        if !presetAnimation.isEmpty { try c.encode(presetAnimation, forKey: .presetAnimation) }
    }
}

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

extension EditLane: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, clips, isHidden, colorIndex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            clips: try c.decodeIfPresent([EditClip].self, forKey: .clips) ?? [],
            isHidden: try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false,
            colorIndex: try c.decodeIfPresent(Int.self, forKey: .colorIndex)
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(clips, forKey: .clips)
        try c.encode(isHidden, forKey: .isHidden)
        try c.encodeIfPresent(colorIndex, forKey: .colorIndex)
    }
}

extension TimelineState: Codable {
    private enum CodingKeys: String, CodingKey {
        case mainClips, mainHidden, overlayTracks, audioTracks
        case subtitle, subtitleHidden, translationHidden
        case subtitleLayout, subtitleURL, subtitleCompanion, shapes, textOverlays, canvasRatio
        case frameRate, filters
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        mainClips = try c.decodeIfPresent([EditClip].self, forKey: .mainClips) ?? []
        mainHidden = try c.decodeIfPresent(Bool.self, forKey: .mainHidden) ?? false
        overlayTracks = try c.decodeIfPresent([EditLane].self, forKey: .overlayTracks) ?? []
        audioTracks = try c.decodeIfPresent([EditLane].self, forKey: .audioTracks) ?? []
        subtitle = try c.decodeIfPresent(SubtitleDocumentModel.self, forKey: .subtitle)
        subtitleHidden = try c.decodeIfPresent(Bool.self, forKey: .subtitleHidden) ?? false
        translationHidden = try c.decodeIfPresent(Bool.self, forKey: .translationHidden) ?? false
        subtitleLayout = try c.decodeIfPresent(SubtitleLayout.self, forKey: .subtitleLayout)
        subtitleURL = try c.decodeIfPresent(URL.self, forKey: .subtitleURL)
        subtitleCompanion = try c.decodeIfPresent(SubtitleCompanion.self, forKey: .subtitleCompanion)
        shapes = try c.decodeIfPresent([ShapeAnnotation].self, forKey: .shapes) ?? []
        // v11 起才有。缺键 = 这个工程没有文字，不是出错。
        textOverlays = try c.decodeIfPresent([TextOverlay].self, forKey: .textOverlays) ?? []
        // v17 起才有。缺键 = 这个工程没有调色段，不是出错。
        filters = try c.decodeIfPresent([FilterClip].self, forKey: .filters) ?? []
        canvasRatio = try c.decodeIfPresent(CanvasRatio.self, forKey: .canvasRatio) ?? .auto
        // v1–v4 没有这个字段，缺失即回退 24（与 ProjectFrameRate.fallback 一致）。
        frameRate = try c.decodeIfPresent(ProjectFrameRate.self, forKey: .frameRate) ?? .fallback
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mainClips, forKey: .mainClips)
        try c.encode(mainHidden, forKey: .mainHidden)
        try c.encode(overlayTracks, forKey: .overlayTracks)
        try c.encode(audioTracks, forKey: .audioTracks)
        try c.encodeIfPresent(subtitle, forKey: .subtitle)
        try c.encode(subtitleHidden, forKey: .subtitleHidden)
        try c.encode(translationHidden, forKey: .translationHidden)
        try c.encodeIfPresent(subtitleLayout, forKey: .subtitleLayout)
        try c.encodeIfPresent(subtitleURL, forKey: .subtitleURL)
        // 空 companion 不落盘：否则一个从未用过新功能的工程也会被抬进 v4。
        if subtitleCompanion?.hasPersistentData == true {
            try c.encodeIfPresent(subtitleCompanion, forKey: .subtitleCompanion)
        }
        try c.encode(shapes, forKey: .shapes)
        // 空数组不落盘：一个从没用过文字的工程不该因此被抬进 v11
        //（判据见 VideoEditFormatVersion.swift 的登记清单）。
        if !textOverlays.isEmpty { try c.encode(textOverlays, forKey: .textOverlays) }
        // 同上：没用过滤镜的工程不该被抬进 v17，旧版照样能开。
        if !filters.isEmpty { try c.encode(filters, forKey: .filters) }
        try c.encode(canvasRatio, forKey: .canvasRatio)
        // **无条件**写帧率：旧版把帧率硬编码成 30，省略这个键会让默认 24 的
        // 工程在旧版里按 30 渲染（见 VideoEditFormatVersion 的说明）。
        try c.encode(frameRate, forKey: .frameRate)
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

/// 轨道的身份：主轨、第几条上层视频轨、第几条音频轨。
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
