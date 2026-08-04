import AVFoundation
import Foundation
import SrtFlowCore

struct MediaInfo: Hashable, Sendable {
    var duration: Double
    /// 已经把旋转矩阵算进去的显示尺寸。手机竖拍的视频靠这个才不会算成横的。
    var displaySize: CGSize
    var frameRate: Double
    var videoCodec: String
    var audioCodec: String?
    var hasAudio: Bool
    /// 源音频能不能原样塞进 mp4。AAC / MP3 可以，PCM、AC-3 之类要转 AAC。
    var audioCanCopyToMP4: Bool
    var fileBytes: Int64

    var width: Int { Int(displaySize.width.rounded()) }
    var height: Int { Int(displaySize.height.rounded()) }

    var aspectRatio: Double {
        guard displaySize.height > 0 else { return 16.0 / 9.0 }
        return displaySize.width / displaySize.height
    }

    var resolutionLabel: String { "\(width)×\(height)" }
}

/// 探测结果会随工程存盘（省得每次打开都重探一遍所有素材），所以跟工程里
/// 别的模型一样宽容解码：字段缺了取默认值，不让老工程整份打不开。
extension MediaInfo: Codable {
    private enum CodingKeys: String, CodingKey {
        case duration, displaySize, frameRate, videoCodec, audioCodec
        case hasAudio, audioCanCopyToMP4, fileBytes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        displaySize = try c.decodeIfPresent(CGSize.self, forKey: .displaySize) ?? .zero
        frameRate = try c.decodeIfPresent(Double.self, forKey: .frameRate) ?? 30
        videoCodec = try c.decodeIfPresent(String.self, forKey: .videoCodec) ?? ""
        audioCodec = try c.decodeIfPresent(String.self, forKey: .audioCodec)
        hasAudio = try c.decodeIfPresent(Bool.self, forKey: .hasAudio) ?? false
        audioCanCopyToMP4 = try c.decodeIfPresent(Bool.self, forKey: .audioCanCopyToMP4) ?? false
        fileBytes = try c.decodeIfPresent(Int64.self, forKey: .fileBytes) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(duration, forKey: .duration)
        try c.encode(displaySize, forKey: .displaySize)
        try c.encode(frameRate, forKey: .frameRate)
        try c.encode(videoCodec, forKey: .videoCodec)
        try c.encodeIfPresent(audioCodec, forKey: .audioCodec)
        try c.encode(hasAudio, forKey: .hasAudio)
        try c.encode(audioCanCopyToMP4, forKey: .audioCanCopyToMP4)
        try c.encode(fileBytes, forKey: .fileBytes)
    }
}

enum MediaProbeError: LocalizedError {
    case noVideoTrack
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return L10n("This file has no video track.")
        case .unreadable(let detail):
            return detail
        }
    }
}

/// 读视频的时长、分辨率、帧率和编解码器。
///
/// 主路径走 AVFoundation：不用起子进程，而且旋转过的 iPhone 视频能直接拿到
/// 正确的显示尺寸。AVFoundation 打不开的容器（mkv、avi 之类）再退回去解析
/// `ffmpeg -i` 打在 stderr 上的信息 —— 这样就不必为了 ffprobe 再多带 49MB。
enum MediaProbe {

    static func probe(url: URL, ffmpeg: URL?) async -> Result<MediaInfo, Error> {
        let fileBytes = byteSize(of: url)

        if let info = try? await probeWithAVFoundation(url: url, fileBytes: fileBytes) {
            return .success(info)
        }
        if let ffmpeg, let info = probeWithFFmpeg(url: url, ffmpeg: ffmpeg, fileBytes: fileBytes) {
            return .success(info)
        }
        return .failure(MediaProbeError.unreadable(
            String(
                format: L10n("Could not read video information from %@."),
                url.lastPathComponent
            )
        ))
    }

    static func byteSize(of url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: - AVFoundation

    private static func probeWithAVFoundation(url: URL, fileBytes: Int64) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = videoTracks.first else { throw MediaProbeError.noVideoTrack }

        let duration = try await asset.load(.duration)
        let (naturalSize, transform, nominalFrameRate, formats) = try await track.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions
        )

        // 旋转矩阵作用到尺寸上，再取绝对值，得到实际显示的宽高。
        let transformed = naturalSize.applying(transform)
        let displaySize = CGSize(width: abs(transformed.width), height: abs(transformed.height))

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        var audioCodec: String?
        if let audioTrack = audioTracks.first {
            let audioFormats = try await audioTrack.load(.formatDescriptions)
            audioCodec = audioFormats.first.map { fourCharCode(CMFormatDescriptionGetMediaSubType($0)) }
        }

        return MediaInfo(
            duration: duration.seconds.isFinite ? duration.seconds : 0,
            displaySize: displaySize,
            frameRate: Double(nominalFrameRate),
            videoCodec: formats.first.map { fourCharCode(CMFormatDescriptionGetMediaSubType($0)) } ?? "unknown",
            audioCodec: audioCodec.map(normalizedCodecName),
            hasAudio: !audioTracks.isEmpty,
            audioCanCopyToMP4: audioCodec.map(canCopyToMP4) ?? false,
            fileBytes: fileBytes
        )
    }

    private static func fourCharCode(_ code: FourCharCode) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "unknown"
    }

    /// `avc1` → `h264` 之类，统一成大家熟悉的叫法。
    private static func normalizedCodecName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "avc1", "h264": return "h264"
        case "hvc1", "hev1": return "hevc"
        case "aac", "mp4a": return "aac"
        case ".mp3", "mp3": return "mp3"
        case "lpcm", "sowt", "in24", "fl32": return "pcm"
        case "ac-3": return "ac3"
        case "ec-3": return "eac3"
        default: return raw.lowercased()
        }
    }

    /// mp4 只认少数几种音频。别的都得转 AAC，否则 `-c:a copy` 会直接失败。
    private static func canCopyToMP4(_ rawCodec: String) -> Bool {
        ["aac", "mp4a", ".mp3", "mp3"].contains(rawCodec.lowercased())
    }

    // MARK: - 退回解析 ffmpeg -i 的输出

    /// `ffmpeg -i file` 不指定输出时会把流信息打到 stderr 再以非 0 退出。
    /// 这一路专门伺候 AVFoundation 打不开的容器。
    private static func probeWithFFmpeg(url: URL, ffmpeg: URL, fileBytes: Int64) -> MediaInfo? {
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-hide_banner", "-i", url.path]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return parseFFmpegBanner(text, fileBytes: fileBytes)
    }

    /// 解析类似这样的文本：
    /// ```
    ///   Duration: 00:01:23.45, start: 0.000000, bitrate: 5000 kb/s
    ///   Stream #0:0: Video: h264 (High), yuv420p, 1920x1080, 5000 kb/s, 30 fps
    ///   Stream #0:1: Audio: aac (LC), 48000 Hz, stereo, fltp, 128 kb/s
    /// ```
    static func parseFFmpegBanner(_ text: String, fileBytes: Int64) -> MediaInfo? {
        var duration: Double = 0
        var size: CGSize?
        var frameRate: Double = 0
        var videoCodec = "unknown"
        var audioCodec: String?
        var rotation: Double = 0

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("Duration:"),
               let value = firstMatch(in: line, pattern: "Duration: ([0-9:.]+)"),
               let parsed = Timecode.parse(trimFraction(value)) {
                duration = parsed
            }

            if line.contains("Video:"), size == nil {
                if let codec = firstMatch(in: line, pattern: "Video: ([A-Za-z0-9_]+)") {
                    videoCodec = codec
                }
                // 分辨率要挑对：一行里 "1920x1080" 之外还可能有 "[SAR 1:1 DAR 16:9]"。
                if let dimensions = firstMatch(in: line, pattern: "[, ]([0-9]{2,5}x[0-9]{2,5})") {
                    let parts = dimensions.split(separator: "x")
                    if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) {
                        size = CGSize(width: w, height: h)
                    }
                }
                if let fps = firstMatch(in: line, pattern: "([0-9.]+) fps"), let value = Double(fps) {
                    frameRate = value
                }
            }

            if line.contains("Audio:"), audioCodec == nil,
               let codec = firstMatch(in: line, pattern: "Audio: ([A-Za-z0-9_.]+)") {
                audioCodec = codec
            }

            // 竖拍视频的旋转信息单独一行：`rotation of -90.00 degrees`
            if line.contains("rotation of"),
               let value = firstMatch(in: line, pattern: "rotation of (-?[0-9.]+)"),
               let degrees = Double(value) {
                rotation = degrees
            }
        }

        guard var displaySize = size else { return nil }
        // 旋转 90/270 度时宽高要对调，和 AVFoundation 那一路保持一致。
        if abs(rotation.truncatingRemainder(dividingBy: 180)) == 90 {
            displaySize = CGSize(width: displaySize.height, height: displaySize.width)
        }

        return MediaInfo(
            duration: duration,
            displaySize: displaySize,
            frameRate: frameRate,
            videoCodec: normalizedCodecName(videoCodec),
            audioCodec: audioCodec.map(normalizedCodecName),
            hasAudio: audioCodec != nil,
            audioCanCopyToMP4: audioCodec.map(canCopyToMP4) ?? false,
            fileBytes: fileBytes
        )
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// `00:01:23.450000` → `00:01:23.450`，Timecode 只认到毫秒。
    private static func trimFraction(_ value: String) -> String {
        guard let dot = value.lastIndex(of: ".") else { return value }
        let fraction = value[value.index(after: dot)...]
        guard fraction.count > 3 else { return value }
        return String(value[..<dot]) + "." + fraction.prefix(3)
    }
}
