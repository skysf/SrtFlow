import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 工具：生成素材（generate_media，方案第六块）
//
// 管什么：把 AI 传来的参数读成一次生成（图 / 视频 / 音乐 / 音效，`FalRequest`）、认模型、估价、造请求体，然后**回任务号**
// （一次生成要几秒到几分钟，客户端对一次调用大多只等一分钟；方案第 5 条：长任务先返回任务号，停止按钮能取消）；真正的活在
// `FalGenerationRun` 里跑。成品放在用户的 `SrtFlow/生成` 文件夹（点名的文件夹 → 工程的家 → 下载，没有「影片」，撞名加编号）。
// 不管什么：调 fal（FalClient）、花钱的把关和横幅上的提问（FalGenerationRun）、配旁白（AIVoiceoverTool 用 fal 的声音那一路）。
//
// 不改工程：放上时间线是 add_clips 的事（一个工具一件事，撤销也各是各的）。所以这里不进撤销分组、不算这一轮的改动。

@MainActor
enum FalGenerateTool {
    static func generate(_ args: AIToolArguments, _ project: VideoEditProject) async throws -> AIToolResult {
        let store = FalSettingsStore.shared
        // 小程序没配 Key 就不列这个工具，但客户端可能缓存着旧清单：这里再认一次。
        guard store.hasKey else { throw AIToolError(FalError.noKey.message) }
        guard let kindName = try args.choice("kind", from: MCPVocabulary.generationKinds), let kind = FalModel.Kind(rawValue: kindName) else {
            throw AIToolError("kind is required: \(MCPVocabulary.generationKinds.joined(separator: ", ")).")
        }
        var notes: [String] = []
        var request = FalRequest(kind: kind, prompt: try args.requiredString("prompt"))
        request.seconds = try args.double("duration")
        request.resolution = try args.choice("resolution", from: MCPVocabulary.videoResolutions)
        request.instrumental = try args.bool("instrumental") ?? true
        request.options = try options(args)

        // 画幅：图和文生视频默认跟画布；图生视频跟着那张图，给了也没用。
        let wantsShape = kind == .image || kind == .textToVideo
        request.aspectRatio = try args.choice("aspect_ratio", from: MCPVocabulary.generationAspects)
        if wantsShape, request.aspectRatio == nil {
            let size = project.renderSize
            request.aspectRatio = FalInputs.nearestAspect(to: size.width / max(size.height, 1), in: FalInputs.h3MaxTextAspects)
        } else if !wantsShape, request.aspectRatio != nil {
            notes.append("aspect_ratio was ignored: \(kind == .imageToVideo ? "image_to_video keeps the picture's shape" : "it only applies to images and text_to_video").")
            request.aspectRatio = nil
        }
        if kind == .imageToVideo {
            let picture = try firstFrameFile(args)
            // 图会发给 fal.ai：点名的文件夹以外的先问一次用户（同读别处的文件）。
            if let ask = try AIWorkspace.shared.confirmReading([picture], verb: "send to fal.ai", args: args, project: project) { return ask }
            do {
                request.imageURL = try FalPayloads.imageDataURI(picture)
            } catch let error as FalInputError {
                throw AIToolError(error.message)
            }
        } else if args.has("image") {
            throw AIToolError("image is only used by image_to_video.")
        }
        if request.resolution != nil, kind != .textToVideo, kind != .imageToVideo { notes.append("resolution was ignored: it only applies to video.") }

        let model = try resolveModel(args, kind: kind)
        let body: JSONValue
        do {
            body = try FalInputs.body(request, dialect: FalDialect(endpoint: model.endpoint))
        } catch let error as FalInputError {
            throw AIToolError(error.message)
        }
        let usage = FalInputs.usage(for: request)
        let estimate = model.estimate(usage)

        let folder = AIWorkspace.shared.outputFolder(.generated, project: project)
        let stem = ExportFileName.stem(
            from: try args.string("name").map { AIVoiceoverPlacement.fileStem($0) } ?? AIVoiceoverPlacement.fileStem(request.prompt),
            droppingExtension: "", fallback: fallbackStem(kind)
        )
        let run = FalGenerationRun(
            request: request, model: model, body: body, estimate: estimate, usage: usage, folder: folder, stem: stem, project: project
        )
        let job = run.start()
        var result: [String: JSONValue] = [
            "status": "started", "job_id": .string(job.id), "kind": .string(kind.rawValue), "model": .string(model.title),
            "endpoint": .string(model.endpoint),
            "price_known": .bool(estimate != nil),
            "daily_limit_usd": .number(store.dailyLimit),
            "spent_today_usd": money(store.spentToday()),
            "next_step": .string(nextStep(kind, estimate: estimate))
        ]
        if let estimate { result["estimated_cost_usd"] = money(estimate) }
        if !notes.isEmpty { result["notes"] = .array(notes.map { .string($0) }) }
        return .ok(.object(result))
    }

    /// 给 get_status 的一段：配了 fal 才有。AI 看了就知道有这个工具、今天还剩多少额度、每种事默认用哪个模型。
    static func statusJSON() -> JSONValue? {
        let store = FalSettingsStore.shared
        guard store.hasKey else { return nil }
        var models: [String: JSONValue] = [:]
        for kind in FalModel.Kind.allCases { models[kind.rawValue] = .string(store.model(for: kind).endpoint) }
        return .object([
            "provider": "fal.ai", "daily_limit_usd": .number(store.dailyLimit), "spent_today_usd": money(store.spentToday()),
            "models": .object(models)
        ])
    }

    // MARK: 参数

    private static func options(_ args: AIToolArguments) throws -> [String: JSONValue] {
        guard let raw = args.raw["options"], !raw.isNull else { return [:] }
        guard case .object(let object) = raw else { throw AIToolError("options must be a JSON object.") }
        return object
    }

    private static func firstFrameFile(_ args: AIToolArguments) throws -> URL {
        guard let path = try args.string("image"), !path.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw AIToolError("image is required for image_to_video: the picture file to start from.")
        }
        let url = AIWorkspace.shared.resolve(path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw AIToolError("There is no picture at \(path).") }
        return url
    }

    /// 点名的模型：登记过的、用户在设置里改成的，或者没登记的（价格不明，每次都问）。
    private static func resolveModel(_ args: AIToolArguments, kind: FalModel.Kind) throws -> FalModel {
        let store = FalSettingsStore.shared
        guard let named = try args.string("model")?.trimmingCharacters(in: .whitespaces), !named.isEmpty else { return store.model(for: kind) }
        guard FalModels.isValidEndpoint(named) else {
            throw AIToolError("model must be a fal.ai endpoint id like owner/model-name (got \(named)).")
        }
        return FalModels.resolve(endpoint: named, kind: kind, overrides: store.overriddenModels)
    }

    // MARK: 结果里的话

    private static func fallbackStem(_ kind: FalModel.Kind) -> String {
        switch kind {
        case .image: return "Image"
        case .imageToVideo, .textToVideo: return "Video"
        case .music: return "Music"
        case .soundEffect: return "Sound effect"
        case .voice, .voiceClone: return "Voice"
        }
    }

    private static func nextStep(_ kind: FalModel.Kind, estimate: Double?) -> String {
        let wait: String
        switch kind {
        case .image: wait = "an image takes about 10 seconds"
        case .soundEffect: wait = "a sound effect takes about 5 seconds"
        case .music: wait = "music takes about 30 seconds"
        default: wait = "a video takes 1 to 3 minutes"
        }
        let cost = estimate.map { "It will cost about \(FalMoney.text($0)); tell the user. " } ?? "SrtFlow does not know this model's price and will ask the user first. "
        return cost + "Wait with get_job (\(wait)); if the job shows waiting_for_user, tell the user what it says. "
            + "When it is done, put the file on the timeline with add_clips" + (kind == .music || kind == .soundEffect ? " (track new_audio)." : ".")
    }

    /// 钱数（美元）保留四位小数：音效一秒 0.0018。
    static func money(_ usd: Double) -> JSONValue { .number((usd * 10_000).rounded() / 10_000) }
}
