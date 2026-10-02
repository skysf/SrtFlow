import Foundation

// MARK: - 片段的 upscale 来源记录（纯值）
//
// 管什么：一段画面的素材换成 upscale 出来的文件之后，记着它从哪来、怎么换回去：原片、新文件的 0 秒对应原片的第几秒、档位、
// 原片的探测信息和音频库键、什么时候做的、扣了多少钱。存在 `EditClip.upscale` 上（格式 v29，按需写键）。
// 单独一个文件：做文件的流水线（UpscalePipeline）只需要这个记录，不用拖着整个时间线模型。
// 不管什么：换源怎么平移（VideoEditClipUpscale.swift）、文件怎么做出来（Upscale/）。

/// 这段现在用的素材是 upscale 出来的文件时，记着它从哪来、怎么换回去。**只记画面段的事**：分离出来的音频留在原片上。
struct ClipUpscaleRecord: Hashable, Codable, Sendable {
    /// 新文件两头可以比用到的范围短一帧（FLUX 会多一帧或少一帧，Topaz 的声音裁到画面长度）：短这么点由合成 / 导出各自
    /// 夹到素材末尾，不动段的时间线长度。换源（ClipSourceSwap）、算范围（UpscaleRange）、整文件判定（UpscalePipeline）都用它。
    static let frameSlack = 1.0 / 24

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
