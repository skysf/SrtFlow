import Foundation

// MARK: - 滤镜（调色预设）
//
// 产品口径见 docs/architecture/filters.md。四句话概括：
//
// 1. 滤镜是**时间轴上的一段**，不是贴在某个片段上的属性 —— 它染的是自己这段
//    时间里的**全部画面**（主轨 + 上层轨），不染形状/文字/字幕。
// 2. 允许叠加。叠加顺序由 `layer` 决定：**层号小的先作用**，时间线上行的上下
//    顺序就是这个顺序（下面的先作用），和 `docs/architecture/video-tracks.md`
//    那条「行的上下顺序就是叠放次序」同一条原则。
// 3. 一款滤镜就是一张 33³ 的 LUT，由 `FilterRecipe` 的解析式算出来（不是抄来的
//    LUT 文件）。强度是**恒等表与满强度表之间的线性插值**，预览和导出插同一份
//    数据 —— 两条管线不许各算各的，见 `VideoEditFilterLUT.swift`。
// 4. 滤镜段**不算进时间线总长**（`TimelineState.duration` 不看它）：它自己不产生
//    画面，把空白拉长没有意义。形状和文字是算的，因为它们本身就是画面。

/// 一款预设滤镜的配方。
///
/// 全部是解析式（lift / gamma / gain + 饱和 + 对比），不是外部 LUT 文件：
/// 加一款滤镜只是加一行数据，不动任何管线代码，App 体积也不涨。
struct FilterRecipe: Hashable, Sendable {
    /// 暗部抬升/压低。正数抬起暗部（褪色胶片），负数压死黑。
    var liftR = 0.0
    var liftG = 0.0
    var liftB = 0.0
    /// 高光增益。三通道分开给就是色偏 —— 冷调压红抬蓝，暖调反过来。
    var gainR = 1.0
    var gainG = 1.0
    var gainB = 1.0
    /// 中间调。>1 提亮中间调，<1 压暗。
    var gammaR = 1.0
    var gammaG = 1.0
    var gammaB = 1.0
    /// 饱和倍率（1 = 不动，0 = 全灰）。
    var saturation = 1.0
    /// 以 0.5 为轴的对比倍率。
    var contrast = 1.0
}

/// 内置的电影感预设。
///
/// **第一刀只接「冷铁」一款**，其余九款在第二刀按同一份配方补齐 —— 那一刀是
/// 纯数据，不动管线。
enum FilterPreset: String, CaseIterable, Identifiable, Hashable, Sendable {
    case coldIron

    var id: String { rawValue }

    /// 界面上的名字。英文原文进字符串表，中文名在 zh-Hans 表里。
    var title: String {
        switch self {
        case .coldIron: return "Cold Iron"
        }
    }

    var recipe: FilterRecipe {
        switch self {
        // 冷铁：高对比、去饱和、往青绿偏、压死黑。就是「工业废土」那一路。
        case .coldIron:
            return FilterRecipe(
                liftR: -0.015, liftG: 0.0, liftB: 0.012,
                gainR: 0.94, gainG: 1.0, gainB: 1.06,
                gammaR: 1.0, gammaG: 1.0, gammaB: 1.0,
                saturation: 0.72, contrast: 1.18
            )
        }
    }
}

/// 时间轴上的一段滤镜。
struct FilterClip: Identifiable, Hashable, Sendable {
    let id: UUID
    var preset: FilterPreset
    /// 0…1。界面上显示成 0–100。0 = 原片（导出时整条 `lut3d` 直接跳过），
    /// 但**不自动删段** —— 归零是「先关掉看看」，不是「不要了」。
    var strength: Double
    var timelineStart: Double
    var duration: Double
    /// 叠加层号。**0 最先作用**，时间线上它在最下面那一行。
    ///
    /// 层号**进模型**，不像文字那样由重叠关系现算（`TextOverlayStacking`）：
    /// LUT 是不可交换的（先冷铁后褪色 ≠ 先褪色后冷铁），现算的层号会在用户拖动
    /// 别的段时重排，画面跟着变 —— 那是最难解释的一类错。
    var layer: Int

    /// 按 + 或拖卡片落下来的默认时长。
    static let defaultDuration = 3.0
    /// 两端裁切的下限，与形状/文字同一个口径。
    static let minimumDuration = 0.2

    init(
        id: UUID = UUID(),
        preset: FilterPreset,
        strength: Double = 1,
        timelineStart: Double,
        duration: Double = FilterClip.defaultDuration,
        layer: Int = 0
    ) {
        self.id = id
        self.preset = preset
        self.strength = strength
        self.timelineStart = timelineStart
        self.duration = duration
        self.layer = layer
    }

    var timelineEnd: Double { timelineStart + duration }

    func contains(time: Double) -> Bool {
        time >= timelineStart && time < timelineEnd
    }

    /// 与另一段在时间上是否有交叠。容差 1ms：首尾紧挨着的两段不算重叠
    ///（同 `TextOverlayStacking` 的容差口径）。
    func overlaps(start: Double, end: Double) -> Bool {
        timelineStart < end - 0.001 && start < timelineEnd - 0.001
    }

    var displayName: String { L10n(preset.title) }
}

extension FilterClip: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, preset, strength, timelineStart, duration, layer
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        // 认不得的预设名（未来版本存的、手改坏的）回落到第一款，而不是整份
        // 工程解码失败 —— 同 `LenientCodableEnum` 的宽容口径。
        preset = try c.decodeIfPresent(FilterPreset.self, forKey: .preset) ?? .coldIron
        strength = try c.decodeIfPresent(Double.self, forKey: .strength) ?? 1
        timelineStart = try c.decodeIfPresent(Double.self, forKey: .timelineStart) ?? 0
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? FilterClip.defaultDuration
        layer = try c.decodeIfPresent(Int.self, forKey: .layer) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(preset, forKey: .preset)
        try c.encode(strength, forKey: .strength)
        try c.encode(timelineStart, forKey: .timelineStart)
        try c.encode(duration, forKey: .duration)
        try c.encode(layer, forKey: .layer)
    }
}

extension FilterPreset: LenientCodableEnum {
    static var decodingFallback: FilterPreset { .coldIron }
}

// MARK: - 时间线上的滤镜

extension TimelineState {

    /// 生效顺序：层号从小到大（下面的行先作用），同层按起点。
    ///
    /// **预览的 CI 链和导出的 lut3d 链都必须按这一份顺序**，各排各的就是
    /// 「预览一个味道、成片另一个味道」。
    var orderedFilters: [FilterClip] {
        filters.sorted {
            ($0.layer, $0.timelineStart, $0.id.uuidString)
                < ($1.layer, $1.timelineStart, $1.id.uuidString)
        }
    }

    /// 此刻生效的滤镜，按生效顺序。
    func activeFilters(at time: Double) -> [FilterClip] {
        orderedFilters.filter { $0.contains(time: time) }
    }

    /// 时间线上要给滤镜留几行。没有滤镜时是 0（那些行整个不出现）。
    var filterLayerCount: Int {
        (filters.map(\.layer).max().map { $0 + 1 }) ?? 0
    }

    func filters(onLayer layer: Int) -> [FilterClip] {
        filters.filter { $0.layer == layer }
    }

    /// `[start, end)` 这段时间内**空着的最低层**。全被占了就返回新的一层。
    ///
    /// 「按 +」和「拖卡片」都从这里要层号：叠加合法之后，落点不再有「撞车」，
    /// 只有「往上摞一层」。
    func lowestFreeFilterLayer(start: Double, end: Double, ignoring ignored: UUID? = nil) -> Int {
        var layer = 0
        while true {
            let occupied = filters.contains {
                $0.layer == layer && $0.id != ignored && $0.overlaps(start: start, end: end)
            }
            if !occupied { return layer }
            layer += 1
        }
    }

    mutating func updateFilter(_ id: UUID, _ change: (inout FilterClip) -> Void) {
        guard let index = filters.firstIndex(where: { $0.id == id }) else { return }
        change(&filters[index])
        filters[index].timelineStart = max(0, filters[index].timelineStart)
        filters[index].duration = max(FilterClip.minimumDuration, filters[index].duration)
        filters[index].strength = min(max(filters[index].strength, 0), 1)
    }

    /// 删段之后把空出来的层号收拢。
    ///
    /// **相对顺序不变，所以画面不跳** —— 这正是层号可以收拢的理由：收拢只改
    /// 编号，不改谁先谁后。不收拢的话删掉最下面一层会留一条空行杵在那儿。
    mutating func compactFilterLayers() {
        let used = Set(filters.map(\.layer)).sorted()
        guard used.last.map({ $0 + 1 }) != used.count else { return }
        var remap: [Int: Int] = [:]
        for (newLayer, old) in used.enumerated() { remap[old] = newLayer }
        for index in filters.indices {
            filters[index].layer = remap[filters[index].layer] ?? 0
        }
    }
}
