import Foundation

/// 编码档位。两档都输出 H.264/mp4，保证微信、B 站、YouTube 与老设备都能播。
public enum VideoEncoder: String, CaseIterable, Codable, Sendable {
    /// libx264 + CRF 恒定质量。压缩比最好，纯 CPU；M 系列多核跑 preset slow
    /// 处理 1080p 通常有 2–4 倍实时速度。
    case softwareCRF
    /// h264_videotoolbox，直接用 M 系列的硬件编码器。约 10 倍实时、几乎不耗电，
    /// 同体积下画质略逊于 x264 slow。
    case hardware

    public var displayName: String {
        switch self {
        case .softwareCRF: return "H.264 CRF (best size)"
        case .hardware: return "Hardware (fastest)"
        }
    }

    public var isHardware: Bool { self == .hardware }
}

/// libx264 的 preset：越慢越省体积，画质不变。
public enum EncodePreset: String, CaseIterable, Codable, Sendable {
    case veryfast, faster, fast, medium, slow, slower, veryslow

    public var displayName: String {
        switch self {
        case .veryfast: return "veryfast"
        case .faster: return "faster"
        case .fast: return "fast"
        case .medium: return "medium"
        case .slow: return "slow"
        case .slower: return "slower"
        case .veryslow: return "veryslow"
        }
    }
}

/// 分辨率上限。只做下调，源本身更小时保持原样。
public enum ResolutionLimit: String, CaseIterable, Codable, Sendable {
    case original, uhd2160, qhd1440, fhd1080, hd720, sd480

    public var maxHeight: Int? {
        switch self {
        case .original: return nil
        case .uhd2160: return 2160
        case .qhd1440: return 1440
        case .fhd1080: return 1080
        case .hd720: return 720
        case .sd480: return 480
        }
    }

    public var displayName: String {
        switch self {
        case .original: return "Original"
        case .uhd2160: return "2160p"
        case .qhd1440: return "1440p"
        case .fhd1080: return "1080p"
        case .hd720: return "720p"
        case .sd480: return "480p"
        }
    }
}

/// 帧率上限。同样只做下调。
public enum FrameRateLimit: String, CaseIterable, Codable, Sendable {
    case original, fps60, fps30, fps24

    public var value: Double? {
        switch self {
        case .original: return nil
        case .fps60: return 60
        case .fps30: return 30
        case .fps24: return 24
        }
    }

    public var displayName: String {
        switch self {
        case .original: return "Original"
        case .fps60: return "60 fps"
        case .fps30: return "30 fps"
        case .fps24: return "24 fps"
        }
    }
}

/// 音频处理。默认直接复制，音轨占体积小，重压没必要还掉音质。
public struct AudioHandling: Codable, Hashable, Sendable {
    public enum Mode: String, CaseIterable, Codable, Sendable {
        case copy, aac

        public var displayName: String {
            switch self {
            case .copy: return "Copy (original quality)"
            case .aac: return "Re-encode AAC"
            }
        }
    }

    public var mode: Mode
    public var kbps: Int

    public static let availableBitrates = [96, 128, 192, 256, 320]

    public init(mode: Mode = .copy, kbps: Int = 192) {
        self.mode = mode
        self.kbps = kbps
    }

    public static let copy = AudioHandling(mode: .copy)
}

public struct VideoEncodeSettings: Codable, Hashable, Sendable {
    public var encoder: VideoEncoder
    /// 恒定质量因子。23 是公认的「视觉无损」平衡点，越大体积越小。
    public var crf: Int
    public var preset: EncodePreset
    /// h264_videotoolbox 的质量（1–100，越高越好越大）。60 大致对应 crf 23。
    public var hardwareQuality: Int
    public var resolution: ResolutionLimit
    public var frameRate: FrameRateLimit
    public var audio: AudioHandling
    /// -movflags +faststart：把索引挪到文件头，网页里能边下边播。
    public var fastStart: Bool
    /// 剥掉源文件里的无用元数据（相机信息、章节等）。
    public var stripMetadata: Bool

    public static let crfRange = 16...30
    public static let hardwareQualityRange = 30...90

    public init(
        encoder: VideoEncoder = .softwareCRF,
        crf: Int = 23,
        preset: EncodePreset = .slow,
        hardwareQuality: Int = 60,
        resolution: ResolutionLimit = .original,
        frameRate: FrameRateLimit = .original,
        audio: AudioHandling = .copy,
        fastStart: Bool = true,
        stripMetadata: Bool = false
    ) {
        self.encoder = encoder
        self.crf = crf
        self.preset = preset
        self.hardwareQuality = hardwareQuality
        self.resolution = resolution
        self.frameRate = frameRate
        self.audio = audio
        self.fastStart = fastStart
        self.stripMetadata = stripMetadata
    }

    public static let `default` = VideoEncodeSettings()

    /// 对 CRF 值的口语化描述，给界面上的滑杆做提示。
    public var crfDescription: String {
        switch crf {
        case ..<19: return "Near-lossless, larger file"
        case 19...21: return "High quality"
        case 22...24: return "Visually lossless (recommended)"
        case 25...26: return "Smaller file, slight quality loss"
        default: return "Smallest file, visible quality loss"
        }
    }
}
