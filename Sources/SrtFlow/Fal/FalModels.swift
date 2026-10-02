import Foundation

// MARK: - fal.ai 上用哪个模型、一次要花多少钱（纯值）
//
// 管什么：SrtFlow 认识的 fal 端点（种类、端点号、登记的单价和计费单位）、每种事默认用哪一个、按用量估一次的钱。
// 方案第 14、18、19、42、52 条（docs/plans/2026-09-27-mcp.md）：预设几个好用的、用户能改；花多少钱按**每个预设模型登记的单价**估，
// 不是 fal 的账单；换成没登记单价的模型，每次生成前都先问。
// 2026-09-29 用户定的口径：**视频只用 `minimax/h3-max/` 这个系列，其余各类也只用当前最新的模型，太老的不进预设**
// （docs/architecture/fal-generation.md「预设怎么选」）。
// 不管什么：怎么拼请求（FalInputs）、怎么调 fal（FalClient）、什么时候问用户（FalSpendPolicy）、存哪（FalSettingsStore）。
//
// **价格会变**：下面每条的单价都是 2026-09-29 从那个模型在 fal.ai 上的页面（「Your request will cost …」那句）抄来的，不是从账单算的。
// 换模型或改价的做法：设置里能改端点号和单价（`FalSettingsStore`）；这张表也要跟着更新，并在 docs/architecture/fal-generation.md
// 的价格表里改日期，`scripts/fal-models/refresh.sh` 会重下每个登记端点的接口定义、列出各类最新的模型。

struct FalModel: Codable, Equatable, Identifiable, Sendable {
    /// 生成什么。**声音（旁白）不走 `generate`**：配旁白是 `add_voiceover`，它在有 Key、没超额度时用这里的 `voice` / `voiceClone`。
    enum Kind: String, Codable, CaseIterable, Sendable {
        case image
        case imageToVideo = "image_to_video"
        case textToVideo = "text_to_video"
        case voice
        case voiceClone = "voice_clone"
        case music
        case soundEffect = "sound_effect"

        var unit: Unit {
            switch self {
            case .image: return .image
            case .imageToVideo, .textToVideo: return .videoSecond
            case .voice: return .thousandCharacters
            case .voiceClone, .music: return .audioMinute
            case .soundEffect: return .audioSecond
            }
        }

        /// `generate` 直接收的几种（旁白走 add_voiceover）。
        var isGenerateKind: Bool { self != .voice && self != .voiceClone }

        /// 这一种事最多等多久（超了就替 fal 取消）：图和音效几十秒，音乐几分钟，视频最慢。
        var maxSeconds: Double {
            switch self {
            case .image, .soundEffect, .voice, .voiceClone: return 300
            case .music: return 900
            case .imageToVideo, .textToVideo: return 1_500
            }
        }

        /// 从提交到做完通常要几秒（含排队；generate_media 说明里的「an image takes about 10 s … a video 1–3 minutes」）：
        /// 进度里「通常约几分钟」和 `get_job` 的 `typical_seconds` 用它。
        var typicalSeconds: Double {
            switch self {
            case .image, .voice, .voiceClone: return 10
            case .soundEffect: return 5
            case .music: return 30
            case .imageToVideo, .textToVideo: return 120
            }
        }
    }

    /// 计费的单位。
    enum Unit: String, Codable, Sendable {
        case image
        case videoSecond = "video_second"
        case thousandCharacters = "thousand_characters"
        case audioSecond = "audio_second"
        /// 按成品的分钟数计，**不满一分钟按一分钟**（ElevenLabs Music：「a generation with 30 seconds output will be billed as 1 minute」）。
        case audioMinute = "audio_minute"
    }

    var kind: Kind
    /// fal 的端点号，例如 `minimax/h3-max/text-to-video`。
    var endpoint: String
    var title: String
    /// 每个计费单位多少美元；nil = 不知道（用户改了端点又没填单价）。
    var unitPrice: Double?
    /// 按档位定价（视频的分辨率）：档位名 → 每秒多少美元。带了档位就按档位，没登记的档位退到 `unitPrice`。
    var tierPrices: [String: Double] = [:]

    var id: String { endpoint }

    init(kind: Kind, endpoint: String, title: String, unitPrice: Double?, tierPrices: [String: Double] = [:]) {
        self.kind = kind
        self.endpoint = endpoint
        self.title = title
        self.unitPrice = unitPrice
        self.tierPrices = tierPrices
    }

    /// 存的是用户的设置，读得宽一点：缺的字段走默认，不因为一个字段读不出来就丢掉整份。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        endpoint = try container.decode(String.self, forKey: .endpoint)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? endpoint
        unitPrice = try container.decodeIfPresent(Double.self, forKey: .unitPrice)
        tierPrices = try container.decodeIfPresent([String: Double].self, forKey: .tierPrices) ?? [:]
    }
}

/// 一次生成的用量（估价用）。
struct FalUsage: Equatable, Sendable {
    var images = 1
    /// 成品的时长：视频 / 音乐 / 音效。
    var seconds = 5.0
    var characters = 0
    /// 视频的分辨率档，如 `768P`。
    var tier: String?

    /// 读一段话大约要几秒：**往长了估**（中文一秒约 4 个字，英文一秒约 15 个字符，取慢的那个），估价宁多勿少。
    static func speechSeconds(characters: Int) -> Double { Double(max(characters, 0)) / 4 }
}

extension FalModel {
    /// 这一档每个单位的单价。
    func price(forTier tier: String?) -> Double? {
        if let tier, let tiered = tierPrices[tier] { return tiered }
        return unitPrice
    }

    /// 这一次估计花多少美元；单价没登记就是 nil（要先问用户）。
    func estimate(_ usage: FalUsage) -> Double? {
        guard let price = price(forTier: usage.tier) else { return nil }
        switch kind.unit {
        case .image:
            return price * Double(max(1, usage.images))
        case .videoSecond, .audioSecond:
            return price * max(usage.seconds, 0)
        case .thousandCharacters:
            return price * Double(max(usage.characters, 0)) / 1000
        case .audioMinute:
            return price * (max(usage.seconds, 1) / 60).rounded(.up)
        }
    }
}

enum FalModels {
    /// SrtFlow 认识、登记过单价的端点。
    /// 选的是 2026-09-29 fal 目录里每一类**最新**的（`scripts/fal-models/refresh.sh` 按上架日期排）；视频按用户的话只用 `minimax/h3-max/` 系列。
    static let known: [FalModel] = [
        // 2026-09-23 上架。$0.027 / 张（flat）。
        FalModel(kind: .image, endpoint: "bytedance/seedream/v5/flash/text-to-image", title: "Seedream 5.0 Flash", unitPrice: 0.027),
        // 2026-08-23 上架。按分辨率每秒计价；下面是**正式价**（上线促销价是它的一半，2026-09-30 结束）：估价用高的，宁多勿少。
        FalModel(kind: .textToVideo, endpoint: "minimax/h3-max/text-to-video", title: "MiniMax H3 Max", unitPrice: 0.08,
                 tierPrices: FalModels.h3MaxTierPrices),
        FalModel(kind: .imageToVideo, endpoint: "minimax/h3-max/image-to-video", title: "MiniMax H3 Max", unitPrice: 0.08,
                 tierPrices: FalModels.h3MaxTierPrices),
        // 2026-09-28 上架。$0.08 / 千字符。
        FalModel(kind: .voice, endpoint: "elevenlabs/tts/eleven-v4", title: "Eleven v4", unitPrice: 0.08),
        // 2026-06-16 上架，一次读一句、按参考音频克隆音色。$0.01 / 成品分钟。
        FalModel(kind: .voiceClone, endpoint: "fal-ai/zonos2", title: "Zonos2 (clones a voice from a sample)", unitPrice: 0.01),
        // 2026-09-14 上架。$0.6 / 成品分钟，不满一分钟按一分钟。
        FalModel(kind: .music, endpoint: "elevenlabs/music/v2.5", title: "Eleven Music v2.5", unitPrice: 0.6),
        // 2026-07-20 上架。$0.0018 / 成品秒。
        FalModel(kind: .soundEffect, endpoint: "sonilo/v1.1/text-to-sound-effects", title: "Sonilo Sound Effects 1.1", unitPrice: 0.0018)
    ]

    static let h3MaxTierPrices: [String: Double] = ["480P": 0.05, "768P": 0.08, "1080P": 0.16]

    /// 每种事默认用哪一个（方案第 19 条）。
    static let defaults: [FalModel.Kind: String] = Dictionary(uniqueKeysWithValues: known.map { ($0.kind, $0.endpoint) })

    static func known(_ endpoint: String) -> FalModel? {
        known.first { $0.endpoint.caseInsensitiveCompare(endpoint) == .orderedSame }
    }

    /// 这一种事此刻用的模型：用户在设置里改过的优先，其次默认表。
    static func preset(for kind: FalModel.Kind, overrides: [FalModel.Kind: FalModel] = [:]) -> FalModel {
        if let override = overrides[kind] { return override }
        return known.first { $0.kind == kind }!
    }

    /// 按端点号认一个模型：登记过的 → 用户设置里这一种事改成的那个 → 没登记（单价 nil，生成前要问）。
    static func resolve(endpoint: String, kind: FalModel.Kind, overrides: [FalModel.Kind: FalModel] = [:]) -> FalModel {
        let trimmed = endpoint.trimmingCharacters(in: .whitespaces)
        if let registered = known(trimmed), registered.kind == kind { return registered }
        if let custom = overrides[kind], custom.endpoint.caseInsensitiveCompare(trimmed) == .orderedSame { return custom }
        return FalModel(kind: kind, endpoint: trimmed, title: trimmed, unitPrice: nil)
    }

    /// 端点号写得对不对（fal 的端点是 `owner/name[/…]`，只含字母数字和 `-_./`）。
    static func isValidEndpoint(_ endpoint: String) -> Bool {
        let trimmed = endpoint.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("/"), !trimmed.hasPrefix("/"), !trimmed.hasSuffix("/"), !trimmed.contains("..") else { return false }
        return trimmed.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_./".contains($0)) }
    }
}
