import CryptoKit
import Foundation

/// 把静态图片变成一段静帧循环视频，好让它走和视频完全一样的剪辑管线。
///
/// 生成的片段 60 秒（图片段够用了），放进缓存目录按内容指纹复用 ——
/// 同一张图第二次拖进来不再转。
enum StillImageClipFactory {

    struct ConversionError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// 静帧段的总长度，也是图片段最长能拖到的时长。
    static let stillDuration = 60.0

    /// 已经转过就直接给（同步、零开销）。撤销后修补占位块时用。
    static func cachedStillVideo(for image: URL) -> URL? {
        guard let directory = try? cacheDirectory() else { return nil }
        let output = directory.appendingPathComponent("\(cacheKey(for: image))-v2.mp4")
        return FileManager.default.fileExists(atPath: output.path) ? output : nil
    }

    static func stillVideo(for image: URL, ffmpeg: URL) async throws -> URL {
        let directory = try cacheDirectory()
        // 文件名带参数版本：编码参数变了旧缓存就作废。
        let output = directory.appendingPathComponent("\(cacheKey(for: image))-v2.mp4")
        if FileManager.default.fileExists(atPath: output.path) { return output }

        // 大图先收到 1080p 级别：静帧不需要 4K，编得快、拖得动。
        // 宽高都得是偶数，yuv420p 的要求。
        let filter = "scale=trunc(min(iw\\,1920)/2)*2:trunc(min(ih\\,1080)/2)*2:force_original_aspect_ratio=decrease,pad=ceil(iw/2)*2:ceil(ih/2)*2"
        // 2fps 就够了：画面是死的，预览和导出都会重新对齐帧率。
        // 60s × 2fps = 120 帧，拖进来几乎立等可取 —— 30fps 那版要等好几秒。
        let arguments = [
            "-hide_banner", "-nostdin", "-y", "-loglevel", "error",
            "-loop", "1",
            "-i", image.path,
            "-t", String(Int(stillDuration)),
            "-r", "2",
            "-vf", filter,
            "-c:v", "libx264", "-preset", "ultrafast", "-tune", "stillimage", "-crf", "18",
            "-pix_fmt", "yuv420p",
            "-an",
            output.path
        ]

        try await run(ffmpeg: ffmpeg, arguments: arguments, imageName: image.lastPathComponent)
        return output
    }

    private static func cacheDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("SrtFlow/StillClips", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 路径 + 修改时间 + 大小的指纹。图换了内容，指纹就变，不会用到旧缓存。
    private static func cacheKey(for url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let fingerprint = "\(url.path)|\(modified)|\(size)"
        let digest = Insecure.MD5.hash(data: Data(fingerprint.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func run(ffmpeg: URL, arguments: [String], imageName: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = ffmpeg
                process.arguments = arguments
                let errorPipe = Pipe()
                process.standardError = errorPipe
                process.standardOutput = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let detail = String(data: errorData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    continuation.resume(throwing: ConversionError(
                        message: String(
                            format: L10n("Could not use %@ as a clip."),
                            imageName
                        ) + (detail.isEmpty ? "" : "\n\(detail.suffix(300))")
                    ))
                }
            }
        }
    }
}
