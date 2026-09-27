import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - compress_videos / burn_subtitles / convert_subtitles 的参数（纯值）
//
// 管什么：AI 给的编码参数（quality、fast、resolution、frame_rate）怎么落到 VideoEncodeSettings 上，
// 以及一批文件的输出名（`<名字><后缀>.<扩展名>`，撞了加编号：硬盘上有的、队列里别的条目要写的、
// 这一批前面已经用掉的都算撞）。
// 底子是用户在那一页记住的设置（EncodeQueueMemory 读回来的）；AI 给的只改这几项、只用于这一批。
// 不管什么：排队和跑（EncodeQueue）、任务号和结局（AIEncodeTools）。

enum AIEncodeOptions {
    /// AI 要改的几项。nil = 用页面上记住的。
    struct Overrides: Equatable {
        var quality: String?
        var fast: Bool?
        var resolution: ResolutionLimit?
        var frameRate: FrameRateLimit?
    }

    /// quality 三档在两种编码器上的值：软件编码是 CRF（小 = 好），硬件编码是 1–100 的质量（大 = 好）。
    /// balanced 就是两边的默认值（CRF 23「视觉无损」、硬件 60）。
    static let crf = ["small": 27, "balanced": 23, "high": 19]
    static let hardwareQuality = ["small": 45, "balanced": 60, "high": 75]

    static func parse(_ args: AIToolArguments) throws -> Overrides {
        var overrides = Overrides()
        overrides.quality = try args.choice("quality", from: MCPVocabulary.encodeQualities)
        overrides.fast = try args.bool("fast")
        overrides.resolution = try args.choice("resolution", from: MCPVocabulary.resolutions).map(resolution)
        overrides.frameRate = try args.choice("frame_rate", from: MCPVocabulary.frameRateLimits).map(frameRate)
        return overrides
    }

    static func apply(_ overrides: Overrides, to base: VideoEncodeSettings) -> VideoEncodeSettings {
        var settings = base
        if let fast = overrides.fast { settings.encoder = fast ? .hardware : .softwareCRF }
        if let quality = overrides.quality {
            settings.crf = crf[quality] ?? settings.crf
            settings.hardwareQuality = hardwareQuality[quality] ?? settings.hardwareQuality
        }
        if let resolution = overrides.resolution { settings.resolution = resolution }
        if let frameRate = overrides.frameRate { settings.frameRate = frameRate }
        return settings
    }

    static func resolution(_ name: String) -> ResolutionLimit {
        ResolutionLimit.allCases.first { limit in limit.maxShortSide.map { "\($0)p" } == name } ?? .original
    }

    static func frameRate(_ name: String) -> FrameRateLimit {
        FrameRateLimit.allCases.first { limit in limit.value.map { "\(Int($0))" } == name } ?? .original
    }

    /// 一批文件的输出位置。`taken`：硬盘上已有、或者队列里别的条目要写的。
    static func outputs(
        for inputs: [URL], in folder: URL, suffix: String, pathExtension: String, taken: (URL) -> Bool
    ) -> [URL] {
        var planned: Set<String> = []
        return inputs.map { input in
            let stem = input.deletingPathExtension().lastPathComponent + suffix
            let url = DefaultFolder.unoccupied(in: folder, stem: stem, pathExtension: pathExtension) { candidate in
                taken(candidate) || planned.contains(candidate.standardizedFileURL.path)
            }
            planned.insert(url.standardizedFileURL.path)
            return url
        }
    }

    /// 编码设置写给 AI 看（结果里带着，AI 知道这一批实际用了什么）。
    static func describe(_ settings: VideoEncodeSettings) -> JSONValue {
        var object: [String: JSONValue] = [
            "encoder": .string(settings.encoder == .hardware ? "hardware (fast)" : "H.264 CRF"),
            "quality": .number(Double(settings.encoder == .hardware ? settings.hardwareQuality : settings.crf)),
            "resolution": .string(settings.resolution.maxShortSide.map { "\($0)p" } ?? "original"),
            "frame_rate": .string(settings.frameRate.value.map { "\(Int($0))" } ?? "original")
        ]
        if settings.encoder != .hardware { object["quality_scale"] = "CRF: lower is better, 23 is visually lossless" }
        return .object(object)
    }
}
