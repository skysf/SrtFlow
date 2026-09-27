import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// 压缩 / 烧录 / 转字幕格式（AIEncodeOptions）：什么都不给就是页面上记住的那套；AI 给的只改那几项（预设、声音照旧）；
// 三档画质在两种编码器上各是多少；fast 换编码器；分辨率、帧率上限；乱填报错。输出名 <名字><后缀>.<扩展名>：硬盘上有的、
// 同一批前面用掉的都加编号。转字幕格式读出来的内容（SubtitleConverter.convertedContents，GBK 也对）。
// 编法见 scripts/check-mcp.sh。

func runEncodeChecks() {
    checkEncodeOverrides()
    checkEncodeOutputs()
    checkSubtitleConversion()
}

private func checkEncodeOverrides() {
    var remembered = VideoEncodeSettings.default
    remembered.preset = .veryslow
    remembered.crf = 21
    remembered.audio = AudioHandling(mode: .aac, kbps: 128)
    checkEqual(AIEncodeOptions.apply(AIEncodeOptions.Overrides(), to: remembered), remembered,
               "no options: the settings the user keeps on the page, as they are")

    let small = (try? AIEncodeOptions.parse(args(["quality": "small", "resolution": "720p", "frame_rate": "30"])))
        .map { AIEncodeOptions.apply($0, to: remembered) }
    checkEqual(small?.crf, 27, "small = CRF 27")
    checkEqual(small?.resolution, .hd720, "720p caps the short side at 720")
    checkEqual(small?.frameRate, .fps30, "30 fps")
    checkEqual(small?.preset, .veryslow, "the preset the user keeps is untouched")
    checkEqual(small?.audio, AudioHandling(mode: .aac, kbps: 128), "and so is the audio")

    let hardware = (try? AIEncodeOptions.parse(args(["fast": true, "quality": "high"])))
        .map { AIEncodeOptions.apply($0, to: remembered) }
    checkEqual(hardware?.encoder, .hardware, "fast = the hardware encoder")
    checkEqual(hardware?.hardwareQuality, 75, "high on the hardware encoder is 75 (higher is better there)")
    checkEqual(hardware?.crf, 19, "and the CRF follows, in case the user switches back")
    let back = (try? AIEncodeOptions.parse(args(["fast": false]))).map { AIEncodeOptions.apply($0, to: hardware ?? remembered) }
    checkEqual(back?.encoder, .softwareCRF, "fast=false goes back to the CRF encoder")
    checkEqual((try? AIEncodeOptions.parse(args(["resolution": "original"])))?.resolution, .original, "original lifts the cap")
    checkThrows("an unknown quality is refused") { _ = try AIEncodeOptions.parse(args(["quality": "ultra"])) }
    checkThrows("an unknown frame rate is refused") { _ = try AIEncodeOptions.parse(args(["frame_rate": "25"])) }
    checkEqual(AIEncodeOptions.describe(.default)["quality"]?.doubleValue, 23, "the result reports the CRF it used")
}

private func checkEncodeOutputs() {
    let folder = URL(fileURLWithPath: "/tmp/SrtFlow/Exports", isDirectory: true)
    let inputs = ["/a/clip.mov", "/b/clip.mp4", "/a/other.mkv"].map { URL(fileURLWithPath: $0) }
    let taken: Set<String> = ["/tmp/SrtFlow/Exports/clip_compressed.mp4"]
    let outputs = AIEncodeOptions.outputs(for: inputs, in: folder, suffix: "_compressed", pathExtension: "mp4") {
        taken.contains($0.path)
    }
    checkEqual(outputs.map(\.lastPathComponent), ["clip_compressed 2.mp4", "clip_compressed 3.mp4", "other_compressed.mp4"],
               "taken on disk → 2; the same name again in this batch → 3; never the same output twice")
    let subtitles = AIEncodeOptions.outputs(for: [URL(fileURLWithPath: "/a/talk.srt")], in: folder, suffix: "", pathExtension: "vtt") { _ in
        false
    }
    checkEqual(subtitles.map(\.lastPathComponent), ["talk.vtt"], "a converted subtitle file keeps its name")
}

private func checkSubtitleConversion() {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("srtflow-encode-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("talk.srt")
    let gbk = String.Encoding(rawValue: 0x8000_0421)
    try? "1\n00:00:01,000 --> 00:00:02,500\n南极探险\n".data(using: gbk)?.write(to: url)
    let vtt = try? SubtitleConverter.convertedContents(of: url, to: .vtt)
    check(vtt?.hasPrefix("WEBVTT") == true, "converted to WebVTT")
    check(vtt?.contains("南极探险") == true, "a GBK file converts with its Chinese intact")
    check(vtt?.contains("00:00:01.000 --> 00:00:02.500") == true, "times in WebVTT form")
    checkThrows("a file that is not subtitles is refused") {
        _ = try SubtitleConverter.convertedContents(of: folder.appendingPathComponent("clip.mp4"), to: .srt)
    }
}
