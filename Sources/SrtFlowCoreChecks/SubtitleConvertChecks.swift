import Foundation
import SrtFlowCore

// 把字幕文件转成另一种格式、写到硬盘上（SubtitleConverter.convertFile，批量转换页用的就是它）：扩展名、内容，以及
// **撞名加编号、从不覆盖**（ExportFileName.unoccupied）—— 以前旁边已经有同名文件就直接盖掉，同格式转到源文件夹
// 连源文件都盖（docs/bugfixes/2026-09-27-batch-convert-overwrites-existing-files.md）。

func runSubtitleConvertChecks() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("movie.srt")
        let original = "1\n00:00:01,000 --> 00:00:02,000\nHi\n\n"
        try original.write(to: src, atomically: true, encoding: .utf8)
        let out = try SubtitleConverter.convertFile(at: src, to: .vtt)
        checkEqual(out.pathExtension, "vtt", "convertFile extension")
        check((try String(contentsOf: out, encoding: .utf8)).hasPrefix("WEBVTT"), "convertFile content")

        // 旁边已经有一份用户自己改过的 movie.vtt：不许盖掉，新的叫 movie 2.vtt。
        try "WEBVTT\n\nhand-tuned\n".write(to: out, atomically: true, encoding: .utf8)
        let second = try SubtitleConverter.convertFile(at: src, to: .vtt)
        checkEqual(second.lastPathComponent, "movie 2.vtt", "转换撞名：加编号")
        checkEqual(try String(contentsOf: out, encoding: .utf8), "WEBVTT\n\nhand-tuned\n", "转换撞名：原来那份一个字没动")
        checkEqual((try SubtitleConverter.convertFile(at: src, to: .vtt)).lastPathComponent, "movie 3.vtt", "转换撞名：2 也占了就 3")

        // 转成自己的格式、写回自己的文件夹：源文件不许被盖。
        let same = try SubtitleConverter.convertFile(at: src, to: .srt)
        checkEqual(same.lastPathComponent, "movie 2.srt", "同格式转到源文件夹：另起一个名字")
        checkEqual(try String(contentsOf: src, encoding: .utf8), original, "同格式转到源文件夹：源文件没动")
    } catch {
        check(false, "conversion to disk threw: \(error)")
    }
}
