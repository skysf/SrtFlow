import Foundation

// MARK: - 工具清单：一份，两边用
//
// 管什么：SrtFlow 给 AI 的每一个工具叫什么、干什么、收什么参数（JSON Schema）。
// 小程序回 `tools/list` 读它，App 分派 `tools/call` 也按 `MCPToolName` 走 —— 两边的
// switch 都是穷举的，**加一个工具漏了哪一边，编译器当场报错**，不需要另写守卫。
// 不管什么：工具真正怎么做（App 里的 AI*Tools.swift）。
//
// 说明文字用英文写（模型读英文最准）；AI 回用户时用用户的语言。每条说明写清三件事：
// 做什么、不传的参数怎么办、什么时候会反过来问用户（needs_confirmation）。
// 各组工具的文字在 MCPProjectTools / MCPTimelineTools / MCPSenseTools / MCPMediaTools / MCPFileTools /
// MCPSubtitleExportTools / MCPEncodeTools / MCPSmartEditTools / MCPRecipeTools 里。

/// 全部工具的名字。**顺序就是 `tools/list` 的顺序**（2026-07-28 版协议要求清单顺序稳定）。
public enum MCPToolName: String, CaseIterable, Sendable {
    case getStatus = "get_status"
    case setView = "set_view"
    case openFolder = "open_folder"
    case readDocument = "read_document"
    case recipes = "recipes"
    case saveRecipe = "save_recipe"
    case manageFiles = "manage_files"
    case openProject = "open_project"
    case newProject = "new_project"
    case saveProject = "save_project"
    case getTimeline = "get_timeline"
    case look = "look"
    case listen = "listen"
    case transcribe = "transcribe"
    case findAudio = "find_audio"
    case addVoiceover = "add_voiceover"
    case generateMedia = "generate_media"
    case addClips = "add_clips"
    case editClip = "edit_clip"
    case setKeyframes = "set_keyframes"
    case setTrack = "set_track"
    case splitClip = "split_clip"
    case freezeFrame = "freeze_frame"
    case cutSpeech = "cut_speech"
    case cutToBeat = "cut_to_beat"
    case deleteItems = "delete_items"
    case duplicateItems = "duplicate_items"
    case setTransition = "set_transition"
    case setText = "set_text"
    case setShape = "set_shape"
    case setFilter = "set_filter"
    case setCanvas = "set_canvas"
    case generateSubtitles = "generate_subtitles"
    case translateSubtitles = "translate_subtitles"
    case getSubtitles = "get_subtitles"
    case editSubtitles = "edit_subtitles"
    case exportVideo = "export_video"
    case compressVideos = "compress_videos"
    case burnSubtitles = "burn_subtitles"
    case convertSubtitles = "convert_subtitles"
    case getJob = "get_job"
    case cancelJob = "cancel_job"
    case undo = "undo"
    case seek = "seek"

    public var definition: MCPToolDefinition {
        switch self {
        case .getStatus, .setView, .openFolder, .openProject, .newProject, .saveProject, .undo, .seek:
            return MCPProjectTools.definition(for: self)
        case .getTimeline, .addClips, .editClip, .setKeyframes, .setTrack, .splitClip, .freezeFrame, .deleteItems,
             .duplicateItems,
             .setTransition,
             .setText, .setShape, .setFilter, .setCanvas:
            return MCPTimelineTools.definition(for: self)
        case .look, .listen:
            return MCPSenseTools.definition(for: self)
        case .findAudio, .addVoiceover:
            return MCPMediaTools.definition(for: self)
        case .generateMedia:
            return MCPGenerationTools.definition(for: self)
        case .recipes, .saveRecipe:
            return MCPRecipeTools.definition(for: self)
        case .transcribe, .cutSpeech, .cutToBeat:
            return MCPSmartEditTools.definition(for: self)
        case .compressVideos, .burnSubtitles, .convertSubtitles:
            return MCPEncodeTools.definition(for: self)
        case .readDocument, .manageFiles:
            return MCPFileTools.definition(for: self)
        case .generateSubtitles, .translateSubtitles, .getSubtitles, .editSubtitles,
             .exportVideo, .getJob, .cancelJob:
            return MCPSubtitleExportTools.definition(for: self)
        }
    }

    /// 这个工具要哪个提供方配好了才列出来（nil = 一直列）。方案第 36 条：谁都没配就不列出来。
    public var provider: MCPProvider? {
        switch self {
        case .generateMedia: return .fal
        default: return nil
        }
    }

    /// 配了这些提供方时该列出来的工具，顺序不变。
    public static func listed(providers: Set<MCPProvider>) -> [MCPToolName] {
        allCases.filter { tool in tool.provider.map(providers.contains) ?? true }
    }

    /// `tools/list` 的 `tools` 数组（配了这些提供方时）。
    public static func listJSON(providers: Set<MCPProvider>) -> JSONValue {
        .array(listed(providers: providers).map(\.definition.json))
    }

    /// 全部工具（每个提供方都配好的样子）：自检和说明总长度的守卫看的是这一份，不是某个用户此刻看到的。
    public static var listJSON: JSONValue { listJSON(providers: Set(MCPProvider.allCases)) }
}

/// 一个工具的说明书。
public struct MCPToolDefinition: Sendable {
    public var name: MCPToolName
    public var title: String
    public var description: String
    public var inputSchema: JSONValue
    /// 只读：不改工程、不写文件（客户端据此决定要不要每次都问用户）。
    public var readOnly: Bool
    /// 会删掉东西（时间线上的、撤销掉的、进废纸篓的文件；删文件时 SrtFlow 自己还会走 needs_confirmation）。
    /// SrtFlow 从不覆盖文件（撞名加编号），所以只是「写新文件」的工具不算。
    public var destructive: Bool
    /// 会连到外面的服务、花用户的钱（生成类：fal.ai）。其余工具都在这台 Mac 上做。
    public var openWorld: Bool

    public init(
        _ name: MCPToolName, title: String, description: String,
        input: JSONValue = MCPSchema.object([:]), readOnly: Bool = false, destructive: Bool = false, openWorld: Bool = false
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = input
        self.readOnly = readOnly
        self.destructive = destructive
        self.openWorld = openWorld
    }

    public var json: JSONValue {
        [
            "name": .string(name.rawValue),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": [
                "title": .string(title),
                "readOnlyHint": .bool(readOnly),
                "destructiveHint": .bool(destructive),
                "idempotentHint": .bool(readOnly),
                // 全在这台 Mac 上做；上网的只有 SrtFlow 自己的音乐库（一份固定的清单，不是开放的网络）
                // 和生成类的工具（fal.ai：用户自己的账号、要花钱）。
                "openWorldHint": .bool(openWorld)
            ]
        ]
    }
}

/// 写 JSON Schema 的几个小积木。只放清单里真用到的几种。
public enum MCPSchema {
    public static func object(
        _ properties: [String: JSONValue], required: [String] = [], description: String? = nil
    ) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "object", "properties": .object(properties)]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        if let description { schema["description"] = .string(description) }
        return .object(schema)
    }

    public static func string(_ description: String, oneOf values: [String]? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "string", "description": .string(description)]
        if let values { schema["enum"] = .array(values.map { .string($0) }) }
        return .object(schema)
    }

    public static func number(_ description: String, minimum: Double? = nil, maximum: Double? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "number", "description": .string(description)]
        if let minimum { schema["minimum"] = .number(minimum) }
        if let maximum { schema["maximum"] = .number(maximum) }
        return .object(schema)
    }

    public static func integer(_ description: String, minimum: Int? = nil, maximum: Int? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "integer", "description": .string(description)]
        if let minimum { schema["minimum"] = .number(Double(minimum)) }
        if let maximum { schema["maximum"] = .number(Double(maximum)) }
        return .object(schema)
    }

    public static func boolean(_ description: String) -> JSONValue {
        ["type": "boolean", "description": .string(description)]
    }

    public static func array(of items: JSONValue, _ description: String, minItems: Int? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "array", "items": items, "description": .string(description)]
        if let minItems { schema["minItems"] = .number(Double(minItems)) }
        return .object(schema)
    }

    /// 几个工具都收的「确认令牌」：只有用户在对话里点头之后，才把上一次结果里给的那个令牌带回来。
    public static let confirmToken = string("The confirm_token of a needs_confirmation result, only after the user agreed.")

    /// 轨道名：V1 是主视频轨，V2、V3… 是叠在上面的视频轨，A1、A2… 是音频轨。
    public static let trackDescription =
        "V1 is the main video track, V2, V3… video tracks above it, A1, A2… audio tracks; new_video / new_audio opens a new one."
}
