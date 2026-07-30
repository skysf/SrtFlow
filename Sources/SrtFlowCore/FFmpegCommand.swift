import Foundation

/// 一次 ffmpeg 调用的完整描述。刻意做成纯数据 + 纯函数，好在自检里断言参数，
/// 不用真的跑一遍编码。
public struct FFmpegCommand: Hashable, Sendable {

    /// 烧制字幕所需的两个路径。
    ///
    /// 这里存的是**相对工作目录的文件名**，不是绝对路径：ffmpeg 的滤镜图里，
    /// 路径中的 `:` `'` `\` `[` `]` `,` 都要层层转义，非常容易出错。做法是给每个
    /// 任务建一个临时目录，把 ASS 和字体放进去，再把进程的工作目录设成它，
    /// 滤镜里只写简单的相对名，彻底绕开转义问题。
    public struct BurnIn: Hashable, Sendable {
        public var assFileName: String
        public var fontsDirName: String

        public init(assFileName: String = "subtitle.ass", fontsDirName: String = "fonts") {
            self.assFileName = assFileName
            self.fontsDirName = fontsDirName
        }
    }

    public enum Mode: Hashable, Sendable {
        /// 正常编码出一个视频文件。
        case encode
        /// 只在指定时间点导出一帧图片，用于所见即所得的样式预览。
        case stillFrame(atSeconds: Double)
    }

    public var inputPath: String
    public var outputPath: String
    public var settings: VideoEncodeSettings
    public var mode: Mode
    public var burnIn: BurnIn?
    /// 额外挂一条可开关的软字幕轨（mov_text）。给的是字幕文件绝对路径。
    public var softSubtitlePath: String?
    public var hasAudio: Bool
    /// 源音频能否直接 copy 进 mp4（AAC / MP3 可以，PCM、AC-3 之类不行）。
    public var audioCanCopy: Bool
    /// 用 VideoToolbox 做硬件解码。失败时调用方会去掉这项重试一次。
    public var useHardwareDecode: Bool
    public var sourceHeight: Int?
    public var sourceFrameRate: Double?
    public var metadataTitle: String?

    public init(
        inputPath: String,
        outputPath: String,
        settings: VideoEncodeSettings = .default,
        mode: Mode = .encode,
        burnIn: BurnIn? = nil,
        softSubtitlePath: String? = nil,
        hasAudio: Bool = true,
        audioCanCopy: Bool = true,
        useHardwareDecode: Bool = true,
        sourceHeight: Int? = nil,
        sourceFrameRate: Double? = nil,
        metadataTitle: String? = nil
    ) {
        self.inputPath = inputPath
        self.outputPath = outputPath
        self.settings = settings
        self.mode = mode
        self.burnIn = burnIn
        self.softSubtitlePath = softSubtitlePath
        self.hasAudio = hasAudio
        self.audioCanCopy = audioCanCopy
        self.useHardwareDecode = useHardwareDecode
        self.sourceHeight = sourceHeight
        self.sourceFrameRate = sourceFrameRate
        self.metadataTitle = metadataTitle
    }

    public var isStillFrame: Bool {
        if case .stillFrame = mode { return true }
        return false
    }
}

public enum FFmpegArgumentBuilder {

    /// 滤镜链的顺序有讲究：先降帧、再缩放，**最后**才叠字幕。
    /// 字幕放在缩放之后渲染，文字是按输出分辨率直接画出来的，不会被重采样糊掉。
    public static func filterChain(for command: FFmpegCommand) -> String? {
        var filters: [String] = []

        if let target = command.settings.frameRate.value {
            // 只降不升：源本来就是 24fps 时选 30fps 不该去插帧。
            if let source = command.sourceFrameRate, source <= target + 0.01 {
                // 不加 fps 滤镜
            } else {
                filters.append("fps=\(formatNumber(target))")
            }
        }

        if let maxHeight = command.settings.resolution.maxHeight,
           let sourceHeight = command.sourceHeight,
           sourceHeight > maxHeight {
            // -2 让宽度按比例走且保持偶数，yuv420p 要求宽高都是偶数。
            filters.append("scale=-2:\(maxHeight)")
        }

        if let burnIn = command.burnIn {
            filters.append("subtitles=filename=\(burnIn.assFileName):fontsdir=\(burnIn.fontsDirName)")
        }

        return filters.isEmpty ? nil : filters.joined(separator: ",")
    }

    public static func arguments(for command: FFmpegCommand) -> [String] {
        var args: [String] = ["-hide_banner", "-nostdin", "-y"]

        // 只把错误打到 stderr，进度单独走 stdout，两边互不干扰、都好解析。
        args += ["-loglevel", "error"]
        if !command.isStillFrame {
            args += ["-progress", "pipe:1"]
        }

        if command.useHardwareDecode {
            // M 系列的硬件解码器负责吃进来的这一路，CPU 全留给 x264。
            args += ["-hwaccel", "videotoolbox"]
        }

        if case .stillFrame(let seconds) = command.mode {
            // -ss 放在 -i 之前是快速定位；但它会把输出时间戳归零，
            // 于是 subtitles 滤镜以为当前是第 0 秒，什么都不画。
            // -copyts 保留原始时间戳，字幕才会出现在该出现的位置。
            args += ["-ss", formatNumber(max(0, seconds)), "-copyts"]
        }

        args += ["-i", command.inputPath]

        let attachesSoftSubtitles = !command.isStillFrame && command.softSubtitlePath != nil
        if let softPath = command.softSubtitlePath, attachesSoftSubtitles {
            args += ["-i", softPath]
        }

        if let chain = filterChain(for: command) {
            args += ["-vf", chain]
        }

        if command.isStillFrame {
            args += ["-frames:v", "1", "-an", "-sn"]
            args.append(command.outputPath)
            return args
        }

        args += ["-map", "0:v:0"]
        if command.hasAudio {
            // 结尾的 ? 让没有音轨的源也能正常跑，而不是直接报错退出。
            args += ["-map", "0:a:0?"]
        }
        if attachesSoftSubtitles {
            args += ["-map", "1:s:0?"]
        }

        switch command.settings.encoder {
        case .softwareCRF:
            args += [
                "-c:v", "libx264",
                "-crf", String(command.settings.crf),
                "-preset", command.settings.preset.rawValue,
                // 保证 8bit 4:2:0：源是 10bit 时 x264 会跟着输出 10bit，
                // 那种文件很多播放器和微信都放不了。
                "-pix_fmt", "yuv420p"
            ]
        case .hardware:
            args += [
                "-c:v", "h264_videotoolbox",
                "-q:v", String(command.settings.hardwareQuality),
                // 空间自适应量化：把码率往视觉上更重要的区域挪。
                "-spatial_aq", "1",
                "-pix_fmt", "yuv420p"
            ]
        }

        if command.hasAudio {
            if command.settings.audio.mode == .copy && command.audioCanCopy {
                args += ["-c:a", "copy"]
            } else {
                args += ["-c:a", "aac", "-b:a", "\(command.settings.audio.kbps)k"]
            }
        }

        if attachesSoftSubtitles {
            args += ["-c:s", "mov_text"]
        }

        if command.settings.stripMetadata {
            args += ["-map_metadata", "-1"]
        }
        if let title = command.metadataTitle, !title.isEmpty {
            args += ["-metadata", "title=\(title)"]
        }
        if command.settings.fastStart {
            args += ["-movflags", "+faststart"]
        }

        args.append(command.outputPath)
        return args
    }

    /// `30.0` → `"30"`，`23.976` → `"23.976"`。避免参数里出现 `30.0` 这种写法。
    static func formatNumber(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(value))
        }
        return String(format: "%g", value)
    }
}
