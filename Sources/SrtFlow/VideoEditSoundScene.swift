import Foundation

// MARK: - 声音场景：把一段声音放进「喇叭 / 室内 / 室外」
//
// 2026-09-24 用户要的：选中有声音的段，能让它听起来像从喇叭里出来、像在房间、浴室、大厅、
// 室外、森林、山谷里，并且能调应用之后的参数。拍过的板见 docs/plans/2026-09-24-sound-scenes.md，
// 长期约束见 docs/architecture/sound-scenes.md。
//
// 这个文件只管**模型**：九种场景、每种的两个旋钮叫什么、默认值、夹紧、存盘。
// 声音怎么算在 VideoEditSoundSceneDSP.swift（macOS 自带的音频单元），怎么接进合成音轨在
// VideoEditSoundSceneTrack.swift。

/// 段上的声音场景。`EditClip.soundScene == nil` 就是没有。
struct SoundScene: Hashable, Sendable {
    var kind: SoundSceneKind
    /// 强度：0 = 原声，1 = 完全是场景里的声音。
    var amount: Double
    /// 场景自己的两个旋钮，都是 0…1。叫什么、换算成什么参数，每种场景自己定
    /// （`SoundSceneKind.controls`）：扩音器的「失真」和浴室的「空间大小」是两回事。
    var first: Double
    var second: Double

    init(kind: SoundSceneKind, amount: Double, first: Double, second: Double) {
        self.kind = kind
        self.amount = amount
        self.first = first
        self.second = second
    }

    /// 新选一种场景：强度和两个旋钮都是它的默认值。
    init(kind: SoundSceneKind) {
        let defaults = kind.defaults
        self.init(kind: kind, amount: defaults.amount, first: defaults.first, second: defaults.second)
    }

    /// 换成另一种场景：**强度留着**（用户调的是「要多少」），两个旋钮回到新场景的默认值 ——
    /// 它们在不同场景里是不同的东西，原样搬过去没有意义。
    func switching(to kind: SoundSceneKind) -> SoundScene {
        guard kind != self.kind else { return self }
        var next = SoundScene(kind: kind)
        next.amount = amount
        return next
    }

    /// 三个数都在默认值上（检查器的「恢复默认」据此置灰）。
    var isDefault: Bool {
        let defaults = kind.defaults
        return abs(amount - defaults.amount) < 0.0005
            && abs(first - defaults.first) < 0.0005
            && abs(second - defaults.second) < 0.0005
    }

    /// 读盘、写入都走它：NaN、越界一律夹回 0…1（NaN 回默认值）。
    var sanitized: SoundScene {
        let defaults = kind.defaults
        return SoundScene(
            kind: kind,
            amount: Self.unit(amount, fallback: defaults.amount),
            first: Self.unit(first, fallback: defaults.first),
            second: Self.unit(second, fallback: defaults.second)
        )
    }

    private static func unit(_ value: Double, fallback: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : fallback
    }
}

/// 检查器下拉菜单里的三组。
enum SoundSceneGroup: String, CaseIterable, Sendable {
    case speaker, indoor, outdoor

    var title: String {
        switch self {
        case .speaker: return "Speaker"
        case .indoor: return "Indoor"
        case .outdoor: return "Outdoor"
        }
    }

    /// 块上那枚小图标（表示这段挂了场景）。
    var symbol: String {
        switch self {
        case .speaker: return "megaphone.fill"
        case .indoor: return "house.fill"
        case .outdoor: return "tree.fill"
        }
    }

    var kinds: [SoundSceneKind] { SoundSceneKind.allCases.filter { $0.group == self } }
}

/// 一个旋钮叫什么。
enum SoundSceneControl: Sendable {
    case distortion, quality, size, distance

    var title: String {
        switch self {
        case .distortion: return "Distortion"
        case .quality: return "Tone"
        case .size: return "Room size"
        case .distance: return "Distance"
        }
    }
}

enum SoundSceneKind: String, CaseIterable, Sendable {
    case telephone, megaphone, radio
    case room, bathroom, hall
    case outdoor, forest, valley

    var group: SoundSceneGroup {
        switch self {
        case .telephone, .megaphone, .radio: return .speaker
        case .room, .bathroom, .hall: return .indoor
        case .outdoor, .forest, .valley: return .outdoor
        }
    }

    var title: String {
        switch self {
        case .telephone: return "Telephone"
        case .megaphone: return "Megaphone"
        case .radio: return "Radio"
        case .room: return "Room"
        case .bathroom: return "Bathroom"
        case .hall: return "Hall"
        case .outdoor: return "Open air"
        case .forest: return "Forest"
        case .valley: return "Valley echo"
        }
    }

    /// 两个旋钮：喇叭类是「失真」「音质」，空间类是「空间大小」「距离」。
    var controls: (first: SoundSceneControl, second: SoundSceneControl) {
        group == .speaker ? (.distortion, .quality) : (.size, .distance)
    }

    /// 选中时的默认值（强度, 第一个旋钮, 第二个旋钮）。
    var defaults: (amount: Double, first: Double, second: Double) {
        switch self {
        case .telephone: return (1, 0.3, 0.5)
        case .megaphone: return (1, 0.5, 0.5)
        case .radio: return (1, 0.25, 0.5)
        case .room: return (1, 0.4, 0.4)
        case .bathroom, .outdoor: return (1, 0.5, 0.4)
        case .hall, .forest, .valley: return (1, 0.5, 0.5)
        }
    }
}

// MARK: - 编辑（检查器单选、框选批量都走这三个；只动有声音的段）

extension TimelineState {
    /// 有没有哪一段挂了场景（格式版本 v20 的判据）。
    var hasSoundScenes: Bool { allClips.contains { $0.soundScene != nil } }

    /// 给一组段套上 / 换掉 / 去掉场景（nil = 去掉）。换成另一种场景时强度留着、两个旋钮回到
    /// 新场景的默认值（`SoundScene.switching`）。没有声音的段跳过（界面上它们也没有这一块）。
    mutating func setSoundSceneKind(_ kind: SoundSceneKind?, for ids: [UUID]) {
        for id in ids {
            update(id) { clip in
                guard clip.hasAudio else { return }
                guard let kind else {
                    clip.soundScene = nil
                    return
                }
                clip.soundScene = clip.soundScene?.switching(to: kind) ?? SoundScene(kind: kind)
            }
        }
    }

    /// 改一组段场景里的一个数（强度或两个旋钮之一）。没挂场景的段跳过。
    mutating func setSoundSceneValue(
        _ keyPath: WritableKeyPath<SoundScene, Double>, to value: Double, for ids: [UUID]
    ) {
        for id in ids {
            update(id) { clip in
                guard var scene = clip.soundScene else { return }
                scene[keyPath: keyPath] = value
                clip.soundScene = scene.sanitized
            }
        }
    }

    /// 「重置」：场景不变，三个数回到这种场景的默认值。
    mutating func resetSoundScene(for ids: [UUID]) {
        for id in ids {
            update(id) { clip in
                guard let kind = clip.soundScene?.kind else { return }
                clip.soundScene = SoundScene(kind: kind)
            }
        }
    }
}

// MARK: - 存盘（v20，按需写键；判据与 `requiresFormatVersion20` 同源）

extension SoundScene: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, amount, first, second
    }

    /// 不认识的场景（更新的版本加的）**整个不认**：`EditClip` 那边用 `try?` 读，读不出来就是
    /// 没有场景 —— 比退回成随便哪一种场景诚实（同音频库清单「单条坏数据跳过」的口径）。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode(String.self, forKey: .kind)
        guard let kind = SoundSceneKind(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "Unknown sound scene \(raw)"
            )
        }
        let defaults = kind.defaults
        self = SoundScene(
            kind: kind,
            amount: try c.decodeIfPresent(Double.self, forKey: .amount) ?? defaults.amount,
            first: try c.decodeIfPresent(Double.self, forKey: .first) ?? defaults.first,
            second: try c.decodeIfPresent(Double.self, forKey: .second) ?? defaults.second
        ).sanitized
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind.rawValue, forKey: .kind)
        try c.encode(amount, forKey: .amount)
        try c.encode(first, forKey: .first)
        try c.encode(second, forKey: .second)
    }
}
