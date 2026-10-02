import Foundation

// MARK: - 片段的 upscale 来源与换源（纯值）
//
// 管什么：一段画面的素材换成 upscale 出来的文件之后，怎么记它从哪来（`ClipUpscaleRecord`）、换源时源时间怎么整体平移
//（`ClipSourceSwap`：关键帧、标记、音量曲线都锚在源时间上，而新文件的 0 秒不是原片的 0 秒）、换回原片怎么逆回去，
// 以及 `TimelineState` 上「哪些段用了这个文件」「一起换 / 一起换回」。方案 docs/plans/2026-10-02-video-upscale.md，
// 长期约束 docs/architecture/video-edit-project-file.md「四之五、换成 upscale 文件的段」。
// 不管什么：文件怎么做出来（裁范围 / 上传 / 排队 / 下载 / 封回原声，第三刀）、界面（第四刀）、撤销（VideoEditProject.perform）、
// 原片挪了去哪找（重链接的书签：原片进素材表，VideoEditMediaReferences）。

/// 这段现在用的素材是 upscale 出来的文件时，记着它从哪来、怎么换回去。**只记画面段的事**：分离出来的音频留在原片上。
struct ClipUpscaleRecord: Hashable, Codable, Sendable {
    /// 原片。换回去用；也进素材表配书签，原片改名、挪了照样找得到。
    var originalURL: URL
    /// 新文件的 0 秒 = 原片的第几秒（裁出来送上去的范围的起点，含余料）。做了整个文件就是 0。
    var sourceOffset: Double
    /// 档位名（`FalUpscaleTiers` 的 id），也是文件名里的那一截。
    var tier: String
    /// 原片的探测信息：换回去时直接用，不用重探。
    var originalInfo: MediaInfo?
    /// 原片是音频库素材的话，它的键（换回去时还回去；换源之后不能留在段上，不然重链接会按键把 upscale 文件换回库里的原片）。
    var originalRemoteKey: String?
    var madeAt: Date
    /// fal 实际扣的钱（查到了就记）。
    var costUSD: Double?

    init(
        originalURL: URL, sourceOffset: Double, tier: String, originalInfo: MediaInfo? = nil, originalRemoteKey: String? = nil,
        madeAt: Date = Date(), costUSD: Double? = nil
    ) {
        self.originalURL = originalURL
        self.sourceOffset = sourceOffset
        self.tier = tier
        self.originalInfo = originalInfo
        self.originalRemoteKey = originalRemoteKey
        self.madeAt = madeAt
        self.costUSD = costUSD
    }

    private enum CodingKeys: String, CodingKey {
        case originalURL, sourceOffset, tier, originalInfo, originalRemoteKey, madeAt, costUSD
    }

    /// 读得宽：只有原片路径是必需的，其余缺了走默认（同工程文件里别的字段）。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        originalURL = try c.decode(URL.self, forKey: .originalURL)
        sourceOffset = try c.decodeIfPresent(Double.self, forKey: .sourceOffset) ?? 0
        tier = try c.decodeIfPresent(String.self, forKey: .tier) ?? ""
        originalInfo = try c.decodeIfPresent(MediaInfo.self, forKey: .originalInfo)
        originalRemoteKey = try c.decodeIfPresent(String.self, forKey: .originalRemoteKey)
        madeAt = try c.decodeIfPresent(Date.self, forKey: .madeAt) ?? Date(timeIntervalSince1970: 0)
        costUSD = try c.decodeIfPresent(Double.self, forKey: .costUSD)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(originalURL, forKey: .originalURL)
        try c.encode(sourceOffset, forKey: .sourceOffset)
        try c.encode(tier, forKey: .tier)
        try c.encodeIfPresent(originalInfo, forKey: .originalInfo)
        try c.encodeIfPresent(originalRemoteKey, forKey: .originalRemoteKey)
        try c.encode(madeAt, forKey: .madeAt)
        try c.encodeIfPresent(costUSD, forKey: .costUSD)
    }
}

/// 把一段的素材换成另一个文件（或换回原片），源时间整体平移。
enum ClipSourceSwap {
    /// 换过去的那个文件：路径、探测信息、来源记录（`sourceOffset` 永远相对**原片**算，不管这段此刻用的是原片还是上一次的 upscale 文件）。
    struct Replacement: Equatable, Sendable {
        var url: URL
        var info: MediaInfo
        var record: ClipUpscaleRecord
    }

    /// 新文件两头可以比这段用到的范围短一帧（FLUX 会多一帧或少一帧，Topaz 的声音裁到画面长度）：
    /// 短这么点由合成 / 导出各自夹到素材末尾，不动段的时间线长度。
    static let slack = 1.0 / 24

    /// 这段此刻用到的范围，换算到原片的时间轴上。
    static func originalStart(of clip: EditClip) -> Double {
        clip.sourceStart + (clip.upscale?.sourceOffset ?? 0)
    }

    /// 新文件盖不盖得住这段用到的范围（差一帧以内算盖住）。
    static func fits(_ clip: EditClip, _ replacement: Replacement) -> Bool {
        guard !clip.isAudioOnly, clip.stillImageURL == nil else { return false }
        let newStart = originalStart(of: clip) - replacement.record.sourceOffset
        return newStart >= -slack && newStart + clip.sourceDuration <= replacement.info.duration + slack
    }

    /// 换源。盖不住的不换（返回 false，段原样不动）。
    @discardableResult
    static func apply(_ replacement: Replacement, to clip: inout EditClip) -> Bool {
        guard fits(clip, replacement) else { return false }
        let existing = clip.upscale
        var record = replacement.record
        // 原片的身份只记第一次的：在 upscale 过的段上再 upscale，输入仍是原片。
        record.originalURL = existing?.originalURL ?? clip.sourceURL
        record.originalInfo = existing?.originalInfo ?? clip.info
        record.originalRemoteKey = existing?.originalRemoteKey ?? clip.remoteKey
        let newStart = originalStart(of: clip) - replacement.record.sourceOffset
        shift(&clip, by: newStart - clip.sourceStart)
        clip.sourceURL = replacement.url
        clip.info = replacement.info
        clip.remoteKey = nil
        clip.upscale = record
        return true
    }

    /// 换回原片。没换过的返回 false。
    @discardableResult
    static func revert(_ clip: inout EditClip) -> Bool {
        guard let record = clip.upscale else { return false }
        shift(&clip, by: record.sourceOffset)
        clip.sourceURL = record.originalURL
        clip.info = record.originalInfo
        clip.remoteKey = record.originalRemoteKey
        clip.upscale = nil
        return true
    }

    /// 源时间整体平移：入点、关键帧、标记、音量曲线一起挪，时间线上的位置和长度不动。
    /// 入点不许小于 0（新文件比用到的范围晚起步不到一帧时，画面晚一帧起步，长度照旧）。
    private static func shift(_ clip: inout EditClip, by delta: Double) {
        guard delta != 0 else { return }
        clip.sourceStart = max(0, clip.sourceStart + delta)
        clip.animation = clip.animation?.stretched(from: 0...1, to: delta...(delta + 1))
        clip.volumeCurve = clip.volumeCurve.stretched(from: 0...1, to: delta...(delta + 1))
        for index in clip.markers.indices { clip.markers[index].sourceTime += delta }
    }
}

extension TimelineState {
    /// 当前工程里用这个文件（原片）的画面段：此刻直接用着它的，和已经换成它的 upscale 文件的。分离出来的音频不算。
    func clipIDs(usingPicture url: URL) -> [UUID] {
        allClips.filter { clip in
            !clip.isAudioOnly && clip.stillImageURL == nil && (clip.sourceURL == url || clip.upscale?.originalURL == url)
        }.map(\.id)
    }

    /// 这些段一起换源；范围被新文件盖住的才换。返回换了的。
    @discardableResult
    mutating func applyUpscale(_ replacement: ClipSourceSwap.Replacement, to ids: [UUID]) -> [UUID] {
        var done: [UUID] = []
        for id in ids {
            update(id) { clip in
                if ClipSourceSwap.apply(replacement, to: &clip) { done.append(id) }
            }
        }
        return done
    }

    /// 这些段换回原片。返回换了的。
    @discardableResult
    mutating func revertUpscale(_ ids: [UUID]) -> [UUID] {
        var done: [UUID] = []
        for id in ids {
            update(id) { clip in
                if ClipSourceSwap.revert(&clip) { done.append(id) }
            }
        }
        return done
    }
}
