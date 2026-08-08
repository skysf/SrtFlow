import CoreGraphics
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

    /// **照片**路径的缩放上限：静帧不需要 4K，编得快、拖得动。
    ///
    /// 定格帧只在**真的超过这个上限时**才走 `nativeResolution: true` —— 它的尺寸
    /// 天然被源视频约束住，再缩一道只会让 Retina 录屏的定格糊掉一格。
    static let photoMaxWidth = 1920.0
    static let photoMaxHeight = 1080.0

    /// 这个尺寸需要走原生政策吗。
    ///
    /// **这是两条政策之间唯一的判据，所有地方都必须用它**，理由是它对
    /// 「源尺寸」和「产物尺寸」给出同一个答案，于是政策可以从工程文件里存着的
    /// `info.displaySize` 反推出来（缓存被系统清掉后要按原政策重转，
    /// 见 `VideoEditProjectIO.refreshStillClips`）：
    ///
    /// - 超过上限 → 走原生 → 产物尺寸 = 源尺寸，仍然超过上限 ✓
    /// - 不超过上限 → 走照片政策，而 `force_original_aspect_ratio=decrease`
    ///   只会缩小不会放大，所以产物 = 源，仍然不超过上限 ✓
    ///
    /// 也就是说尺寸没过线时两条政策产出完全一样，那就统一用照片政策，
    /// 免得同一张图在两个缓存文件之间来回横跳。
    static func needsNativeResolution(for size: CGSize?) -> Bool {
        guard let size else { return false }
        // 留 1px 余量：偶数宽高的 pad 可能让尺寸差一格。
        return size.width > photoMaxWidth + 1 || size.height > photoMaxHeight + 1
    }

    /// 已经转过就直接给（同步、零开销）。撤销后修补占位块时用。
    ///
    /// **必须显式说明是哪条政策**。以前这里「两条都查、原生优先」，同一张 PNG
    /// 既被当定格素材又被用户当普通图片拖进来时会串线：两个缓存都在就都拿原生，
    /// 只剩照片缓存就把定格段悄悄降成 1080p。
    static func cachedStillVideo(for image: URL, nativeResolution: Bool) -> URL? {
        guard let output = cacheFileURL(for: image, nativeResolution: nativeResolution) else { return nil }
        return FileManager.default.fileExists(atPath: output.path) ? output : nil
    }

    /// 这张图这条政策的缓存**应该**在哪（不管在不在）。
    ///
    /// 单独开一个口子是给自检用的：命中路由要真造两份缓存文件才测得出来，
    /// 而指纹公式不该在测试里抄一遍（抄了就会在公式改动时静默假绿）。
    static func cacheFileURL(for image: URL, nativeResolution: Bool) -> URL? {
        guard let directory = try? cacheDirectory() else { return nil }
        return directory.appendingPathComponent(
            fileName(key: cacheKey(for: image), nativeResolution: nativeResolution)
        )
    }

    static func stillVideo(for image: URL, ffmpeg: URL, nativeResolution: Bool = false) async throws -> URL {
        let directory = try cacheDirectory()
        let output = directory.appendingPathComponent(
            fileName(key: cacheKey(for: image), nativeResolution: nativeResolution)
        )
        if FileManager.default.fileExists(atPath: output.path) { return output }

        // 宽高都得是偶数，yuv420p 的要求。
        let evenSize = "pad=ceil(iw/2)*2:ceil(ih/2)*2"
        let filter = nativeResolution
            ? evenSize
            : "scale=trunc(min(iw\\,\(Int(photoMaxWidth)))/2)*2:trunc(min(ih\\,\(Int(photoMaxHeight)))/2)*2:force_original_aspect_ratio=decrease,\(evenSize)"

        // 先写临时文件、成功后原子改名。直接写最终路径的话，转码被中断（切工程、
        // 退出 App、磁盘满）会留下一个**永远命中**的半成品 mp4 —— 之后这张图
        // 每次都解析到那段坏视频，还没有任何线索。
        let temporary = directory.appendingPathComponent("partial-\(UUID().uuidString).mp4")

        // 输入帧率必须**显式跟着输出帧率走**：`-loop 1` 的 image2 demuxer 默认
        // 25fps，不写 `-framerate` 的话 ffmpeg 要把这张图解码 25×60=1500 次，
        // 再丢到只剩 120 帧输出 —— 4K 图实测 19.4s，加上这一个参数变 2.2s。
        // （换硬件编码器只有 20.5s，瓶颈根本不在编码。）
        //
        // 2fps 就够了：画面是死的，预览和导出都会重新对齐帧率。
        let arguments = [
            "-hide_banner", "-nostdin", "-y", "-loglevel", "error",
            "-loop", "1",
            "-framerate", "2",
            "-i", image.path,
            "-t", String(Int(stillDuration)),
            "-r", "2",
            "-vf", filter,
            "-c:v", "libx264", "-preset", "ultrafast", "-tune", "stillimage", "-crf", "18",
            "-pix_fmt", "yuv420p",
            "-an",
            temporary.path
        ]

        do {
            try await run(ffmpeg: ffmpeg, arguments: arguments, imageName: image.lastPathComponent)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }

        // 直接搬，不做「先查存在再搬」—— 那之间有 TOCTOU：同一张图的两个并发
        // 转换可能同时通过检查，后搬的那个会白白报错，哪怕缓存其实已经好了。
        // 搬失败就看目标在不在：在，说明别人先到了，用他的（自己的临时文件扔掉）。
        do {
            try FileManager.default.moveItem(at: temporary, to: output)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            guard FileManager.default.fileExists(atPath: output.path) else { throw error }
        }
        return output
    }

    /// 缓存文件名。带参数版本号：编码参数变了旧缓存就作废。
    /// 两种分辨率政策分开存，互不覆盖。
    ///
    /// 照片这条从 `-v2` 升到 `-v3` 不是因为编码参数变了（`-framerate` 不改输出），
    /// 而是要作废**升级前可能留下的半成品**：那时候是直接往最终路径写、只用
    /// `fileExists` 判命中，转码被中断就会留下一个永远命中的坏文件。
    private static func fileName(key: String, nativeResolution: Bool) -> String {
        nativeResolution ? "\(key)-native-v1.mp4" : "\(key)-v3.mp4"
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
