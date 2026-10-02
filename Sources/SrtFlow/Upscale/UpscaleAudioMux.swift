import Foundation

// MARK: - 把原片那一段声音封进 upscale 出来的文件
//
// 管什么：fal 回来的文件声音不可信（2026-10-02 实测：只有 FLUX 原样复制，Topaz 裁到画面长度、字节重采样、Bria 重编码且短 0.1 秒），
// 所以一律丢掉它的声音，用 App 自带的 ffmpeg 把原片 `[start, end)` 那一段声音封回去：画面流原样复制（HEVC 要点名 `hvc1`，
// 不然 AVFoundation 不认），声音从原片精确裁出来、重编成 AAC 256k（流复制只能在 AAC 帧边界上切，会差 ±20 ms）。
// 原片没有声音就什么都不做。参数是纯值（自检对着看），跑 ffmpeg 的那一步在下面。
// 不管什么：画面怎么来的（UpscalePipeline）、ffmpeg 在哪（MediaToolchain）。

enum UpscaleAudioMux {
    /// ffmpeg 的参数：`upscaled` 的画面 + `original` 的 `[start, start + duration)` 声音 → `output`。
    static func arguments(upscaled: URL, original: URL, start: Double, duration: Double, videoCodec: String, output: URL) -> [String] {
        var arguments = [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-i", upscaled.path,
            // 输入前的 -ss 精确到采样（解码后裁），不是流复制的帧边界。
            "-ss", String(format: "%.6f", max(0, start)), "-t", String(format: "%.6f", max(0, duration)), "-i", original.path,
            "-map", "0:v:0", "-map", "1:a:0",
            "-c:v", "copy",
        ]
        if videoCodec.lowercased().hasPrefix("hev") || videoCodec.lowercased().hasPrefix("hvc") {
            arguments += ["-tag:v", "hvc1"]
        }
        arguments += ["-c:a", "aac", "-b:a", "256k", "-shortest", "-movflags", "+faststart", output.path]
        return arguments
    }

    /// 真跑一遍。`MediaInfo.hasAudio` 为假时调用方不该来这里。
    static func mux(
        ffmpeg: URL, upscaled: URL, original: URL, start: Double, duration: Double, videoCodec: String, output: URL
    ) async throws {
        try? FileManager.default.removeItem(at: output)
        let process = FFmpegProcess()
        try await process.run(
            executable: ffmpeg,
            arguments: arguments(upscaled: upscaled, original: original, start: start, duration: duration, videoCodec: videoCodec, output: output),
            workingDirectory: nil
        )
    }
}
