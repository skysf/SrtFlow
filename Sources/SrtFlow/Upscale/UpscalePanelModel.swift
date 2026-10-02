import Foundation

// MARK: - Upscale 面板背后的数（从工程算出来，纯值）
//
// 管什么：点开面板的那一段用的原片是谁、这个原片在工程里被哪些画面段用到（换算到原片时间）、三种范围各送几秒、
// 每个档位在当前范围 × 目标下的估价和输出尺寸、文件会叫什么名、画布的短边（默认目标按它选）、「另一处更长」的提示。
// 面板（UpscalePanel）只做显示和回调；点「开始」时这里把 `UpscaleRequest` 拼好。
// 不管什么：界面；钱花不花（面板本身就是确认，UpscaleJob 直接记账）。

struct UpscaleTierRow: Identifiable, Equatable {
    var id: String { tier.id }
    let tier: FalUpscaleTier
    /// 估价（按当前范围的秒数和夹过的输出尺寸）。
    let estimate: Double
    /// 夹过倍数之后真正会出的尺寸（FLUX 最小 1.5 倍、Topaz 最多 4 倍，和目标不一定一样）。
    let outputSize: CGSize
    /// 能不能用：输入超过模型的时长 / 大小上限就不能。
    let unavailableReason: String?
}

struct UpscalePanelModel {
    let clipID: UUID
    let clipName: String
    let originalURL: URL
    let originalInfo: MediaInfo
    /// 这个原片在工程里的全部用处（原片时间轴上）。
    let uses: [UpscaleUse]
    /// 画布的短边（默认目标按它选）。
    let canvasShortSide: Int
    let fallbackFolders: [URL]

    /// 从工程里算。音频段、图片段、没探测信息的段没有面板（返回 nil）。
    @MainActor
    init?(project: VideoEditProject, clipID: UUID) {
        guard let clip = project.state.allClips.first(where: { $0.id == clipID }), !clip.isAudioOnly, !clip.isStillImage else { return nil }
        let original = clip.upscale?.originalURL ?? clip.sourceURL
        guard let info = clip.upscale?.originalInfo ?? clip.info else { return nil }
        self.clipID = clipID
        clipName = clip.name
        originalURL = original
        originalInfo = info
        uses = project.state.clipIDs(usingPicture: original).compactMap { id in
            guard let user = project.state.allClips.first(where: { $0.id == id }) else { return nil }
            return UpscaleUse(clipID: id, start: ClipSourceSwap.originalStart(of: user), duration: user.sourceDuration)
        }
        let canvas = VideoEditCompositionBuilder.renderSize(for: project.state)
        canvasShortSide = Int(min(canvas.width, canvas.height).rounded())
        var fallbacks: [URL] = []
        if let home = project.documentURL?.deletingLastPathComponent() { fallbacks.append(home) }
        if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first { fallbacks.append(downloads) }
        fallbackFolders = fallbacks
    }

    /// 点开的这一段用了多久（面板上「This clip uses …」）。
    var thisUse: UpscaleUse? { uses.first { $0.clipID == clipID } }

    /// 工程里另一处用得更长：提示并默认选最长的那处。
    var longerElsewhere: UpscaleUse? { UpscaleRange.longerUseElsewhere(thisClip: clipID, uses: uses) }

    /// 默认选哪种范围：别处用得更长就选最长的那处，否则这一段。
    var defaultChoice: UpscaleRangeChoice { longerElsewhere == nil ? .thisClip : .longestUse }

    /// 默认目标：画布的短边够得上哪一档就选哪一档（源比它小才有意义），都够不上就 1080p。
    var defaultTarget: FalUpscaleTarget {
        let fitting = FalUpscaleTarget.allCases.filter { $0.shortSide <= canvasShortSide && $0.applies(to: originalInfo.displaySize) }
        return fitting.last ?? .p1080
    }

    /// 哪些目标对这个源有意义（源的短边已经不比它小的灰掉）。
    func targetApplies(_ target: FalUpscaleTarget) -> Bool { target.applies(to: originalInfo.displaySize) }

    func range(for choice: UpscaleRangeChoice) -> UpscaleRange {
        UpscaleRange.make(choice, thisClip: clipID, uses: uses, fileDuration: originalInfo.duration, frameRate: originalInfo.frameRate)
    }

    func rows(choice: UpscaleRangeChoice, target: FalUpscaleTarget) -> [UpscaleTierRow] {
        let range = range(for: choice)
        return FalUpscaleTiers.all.map { tier in
            let plan = tier.plan(source: originalInfo.displaySize, target: target)
            var reason: String?
            if let limit = tier.maxInputSeconds, range.duration > limit + 0.001 {
                reason = String(format: L10n("Clips up to %d s only"), Int(limit))
            } else if let bytes = tier.maxInputBytes, UpscalePipeline.uploadsWholeFile(request(choice: choice, target: target, tier: tier)),
                      originalInfo.fileBytes > bytes {
                reason = String(format: L10n("Files up to %d MB only"), bytes / 1_000_000)
            }
            return UpscaleTierRow(tier: tier, estimate: tier.estimate(seconds: range.duration, plan: plan), outputSize: plan.outputSize, unavailableReason: reason)
        }
    }

    func request(choice: UpscaleRangeChoice, target: FalUpscaleTarget, tier: FalUpscaleTier) -> UpscaleRequest {
        UpscaleRequest(originalURL: originalURL, originalInfo: originalInfo, range: range(for: choice), tier: tier, target: target, fallbackFolders: fallbackFolders)
    }

    /// 文件会叫什么（撞名的编号真写的时候才加）。
    func fileName(target: FalUpscaleTarget, tier: FalUpscaleTier) -> String {
        UpscaleOutputName.stem(original: originalURL, outputSize: tier.plan(source: originalInfo.displaySize, target: target).outputSize, tier: tier.id) + ".mp4"
    }

    /// 每个档位一句话（本地化键）。大约几分钟从 `FalUpscaleTier.typicalSeconds` 算（`FalJobProgress.minutes`），和进度里的
    /// 「通常约几分钟」同一个数。
    static func blurb(for tierID: String) -> String {
        switch tierID {
        case "topaz-precision": return "Faithful. Best for real faces."
        case "topaz-generative": return "Re-draws detail: fur, leaves, water."
        case "flux-precise": return "Faithful. Clips up to 20 s."
        case "flux-creative": return "Adds detail. Clips up to 20 s."
        case "bytedance-standard": return "Cheapest. Preset for AI footage."
        case "bytedance-pro": return "Large-model restoration, 10 times the price."
        default: return ""
        }
    }

    /// 价格按哪一天的 fal 页面（面板上标出来）。
    static let priceDate = "2026-10-02"
}
