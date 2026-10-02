import CoreGraphics
import Foundation
import SrtFlowMCPKit

// MARK: - 视频 upscale：用哪些 fal 模型、升到多大、每个档位的请求体、估多少钱（纯值）
//
// 管什么：剪辑块「Upscale」的六个档位（四个端点）、目标分辨率怎么换成倍数和输出尺寸、每个档位的请求体、按用量估价。
// 2026-10-02 用户定的档位（docs/plans/2026-10-02-video-upscale.md）：Topaz precision（真人脸）、Topaz generative（重绘细节）、
// FLUX precise / creative、字节 standard / pro；Topaz creative（5 秒要十分半钟）和 Bria（效果一般、只能 2x）不收。
// 估价的规律是 2026-10-02 在南极工程上真跑 19 条、对着 fal 账单明细量出来的（docs/reports/2026-10-02-upscale-smoke-test.md）：
// 字节按输出秒分档收、分毫不差；FLUX 按输出的百万像素·秒线性（每秒价随输出面积走，没有档位台阶）；Topaz 按 unit（$0.01）
// 收、规则没公开 —— 这里按网页的每 10 秒价折成每秒、向上取整到 $0.10（宁多勿少：precision 实收约是它的一半）。
// 不管什么：裁哪一段、上传、排队、下载、落盘（第三刀）；界面（第四刀）；钱花不花（FalSpendPolicy）。

/// 升到哪一档：按**短边**算，和导出的分辨率档位一个口径（docs/architecture/export-settings.md）。
enum FalUpscaleTarget: Int, CaseIterable, Codable, Sendable {
    case p1080 = 1080
    case p1440 = 1440
    case p2160 = 2160

    var shortSide: Int { rawValue }

    /// 给人看的档位名（分辨率的叫法不翻译）。
    var label: String {
        switch self {
        case .p1080: return "1080p"
        case .p1440: return "1440p"
        case .p2160: return "4K"
        }
    }

    /// 源升到这一档要放大几倍（没夹过；每个档位再按模型认的范围夹）。
    func factor(for source: CGSize) -> Double {
        Double(shortSide) / max(1, min(source.width, source.height))
    }

    /// 源的短边已经不比这一档小：没什么可升的。
    func applies(to source: CGSize) -> Bool { factor(for: source) > 1.0001 }
}

/// 一个档位把一个源升到一个目标：倍数（已按模型夹过）和输出尺寸（偶数）。
struct FalUpscalePlan: Equatable, Sendable {
    var factor: Double
    var outputSize: CGSize

    var outputShortSide: Int { Int(min(outputSize.width, outputSize.height).rounded()) }
}

/// 每个档位怎么收钱（规律见文件头）。
enum FalUpscalePricing: Equatable, Sendable {
    /// 按输出秒分档：输出短边 ≤ 1080 用 1080 档，≤ 1440 用 1440（2K）档，再大用 4K 档。
    case perSecond(p1080: Double, p1440: Double, p2160: Double)
    /// 按输出的百万像素·秒线性。
    case perMegapixelSecond(Double)
    /// 网页的「每 10 秒」价折成每秒、向上取整到 `step`：输出短边 ≤ 1080 用 1080 档，再大用 4K 档（Topaz 没有 2K 档）。
    case perTenSeconds(p1080: Double, p2160: Double, step: Double)

    func estimate(seconds: Double, outputSize: CGSize) -> Double {
        let seconds = max(0, seconds)
        let short = min(outputSize.width, outputSize.height)
        switch self {
        case .perSecond(let p1080, let p1440, let p2160):
            let rate = short <= 1080 ? p1080 : (short <= 1440 ? p1440 : p2160)
            return rate * seconds
        case .perMegapixelSecond(let perMegapixelSecond):
            return perMegapixelSecond * (outputSize.width * outputSize.height / 1_000_000) * seconds
        case .perTenSeconds(let p1080, let p2160, let step):
            guard seconds > 0 else { return 0 }
            let raw = (short <= 1080 ? p1080 : p2160) / 10 * seconds
            return max(step, (raw / step - 1e-9).rounded(.up) * step)
        }
    }
}

struct FalUpscaleTier: Equatable, Identifiable, Sendable {
    /// 档位名，也是文件名里的那一截（`Shot_鲸鱼_1920x1080_topaz-precision.mp4`）。
    let id: String
    let endpoint: String
    let title: String
    /// 子模型 / 模式，给人看。
    let detail: String
    let vendor: String
    let pricing: FalUpscalePricing
    /// 模型认的倍数范围。
    let factorRange: ClosedRange<Double>
    /// 输入最长几秒、最大几字节（fal 页面 / 接口定义写明的；nil = 没写）。
    let maxInputSeconds: Double?
    let maxInputBytes: Int?
    /// 从提交到做完通常要几秒（含排队）：2026-10-02 在南极工程上 3–10 秒的片段实测（docs/reports/2026-10-02-upscale-smoke-test.md），
    /// 取每档的中间值。进度里的「通常约几分钟」和面板上的「about N min」都从它算。
    let typicalSeconds: Double
    /// 一次最多等多久（超了替 fal 取消）。视频一律 25 分钟。
    var maxSeconds: Double { 1_500 }

    /// 把源升到目标：倍数按模型的范围夹，输出尺寸取偶数。
    func plan(source: CGSize, target: FalUpscaleTarget) -> FalUpscalePlan {
        let factor = min(max(target.factor(for: source), factorRange.lowerBound), factorRange.upperBound)
        func even(_ value: Double) -> Double { max(2, (value / 2).rounded() * 2) }
        return FalUpscalePlan(factor: factor, outputSize: CGSize(width: even(source.width * factor), height: even(source.height * factor)))
    }

    func estimate(seconds: Double, plan: FalUpscalePlan) -> Double {
        pricing.estimate(seconds: seconds, outputSize: plan.outputSize)
    }

    /// 给 fal 的请求体。字段名和取值都从接口定义快照来（checks/Fal/schemas/，自检逐条对着验）。
    func body(videoURL: String, plan: FalUpscalePlan, sourceFrameRate: Double) -> JSONValue {
        let factor = JSONValue.number((plan.factor * 1_000_000).rounded() / 1_000_000)
        switch id {
        case "topaz-precision":
            return ["video_url": .string(videoURL), "model": "Proteus", "upscale_factor": factor]
        case "topaz-generative":
            return ["video_url": .string(videoURL), "model": "Starlight Precise 2.6", "upscale_factor": factor]
        case "flux-precise", "flux-creative":
            // creativity 默认是 1（创意）：要忠实必须显式传 0。
            return ["video_url": .string(videoURL), "creativity": id == "flux-precise" ? 0 : 1, "upscale_factor": factor]
        case "bytedance-standard", "bytedance-pro":
            // target_fps 默认 30：源不是 30 fps 不传就会插帧；接口只认 24–120。
            let fps = min(120, max(24, sourceFrameRate.rounded()))
            return [
                "video_url": .string(videoURL), "enhancement_tier": id == "bytedance-pro" ? "pro" : "standard",
                "enhancement_preset": "aigc", "fidelity": "high", "scale_ratio": factor, "target_fps": .number(fps)
            ]
        default:
            return ["video_url": .string(videoURL), "upscale_factor": factor]
        }
    }
}

enum FalUpscaleTiers {
    /// 2026-10-02 定的六个档位；价格是当天 fal 页面和账单明细的口径。改档位 / 改价要同步 docs/architecture/fal-generation.md 第十二节。
    static let all: [FalUpscaleTier] = [
        FalUpscaleTier(
            id: "topaz-precision", endpoint: "topaz/upscale/video/precision", title: "Topaz precision", detail: "Proteus", vendor: "Topaz Labs",
            pricing: .perTenSeconds(p1080: 0.20, p2160: 0.60, step: 0.10), factorRange: 1...4, maxInputSeconds: 300, maxInputBytes: nil,
            typicalSeconds: 70
        ),
        FalUpscaleTier(
            id: "topaz-generative", endpoint: "topaz/upscale/video/generative", title: "Topaz generative", detail: "Starlight Precise 2.6",
            vendor: "Topaz Labs", pricing: .perTenSeconds(p1080: 1.20, p2160: 2.60, step: 0.10), factorRange: 1...4, maxInputSeconds: 300,
            maxInputBytes: nil, typicalSeconds: 190
        ),
        FalUpscaleTier(
            id: "flux-precise", endpoint: "blackforestlabs/flux-video-upscale", title: "FLUX video upscale", detail: "precise",
            vendor: "Black Forest Labs", pricing: .perMegapixelSecond(0.0715), factorRange: 1.5...3, maxInputSeconds: 20, maxInputBytes: 50_000_000,
            typicalSeconds: 120
        ),
        FalUpscaleTier(
            id: "flux-creative", endpoint: "blackforestlabs/flux-video-upscale", title: "FLUX video upscale", detail: "creative",
            vendor: "Black Forest Labs", pricing: .perMegapixelSecond(0.1001), factorRange: 1.5...3, maxInputSeconds: 20, maxInputBytes: 50_000_000,
            typicalSeconds: 200
        ),
        FalUpscaleTier(
            id: "bytedance-standard", endpoint: "fal-ai/bytedance-upscaler/upscale/video", title: "ByteDance upscaler", detail: "standard",
            vendor: "ByteDance", pricing: .perSecond(p1080: 0.0072, p1440: 0.0144, p2160: 0.0288), factorRange: 1.1...10, maxInputSeconds: nil,
            maxInputBytes: nil, typicalSeconds: 140
        ),
        FalUpscaleTier(
            id: "bytedance-pro", endpoint: "fal-ai/bytedance-upscaler/upscale/video", title: "ByteDance upscaler", detail: "pro",
            vendor: "ByteDance", pricing: .perSecond(p1080: 0.072, p1440: 0.144, p2160: 0.288), factorRange: 1.1...10, maxInputSeconds: nil,
            maxInputBytes: nil, typicalSeconds: 320
        )
    ]

    static var endpoints: [String] {
        var seen: [String] = []
        for tier in all where !seen.contains(tier.endpoint) { seen.append(tier.endpoint) }
        return seen
    }

    static func tier(_ id: String) -> FalUpscaleTier? { all.first { $0.id == id } }
}
