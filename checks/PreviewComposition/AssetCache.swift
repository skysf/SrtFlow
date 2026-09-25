import AVFoundation
import Foundation
import SrtFlowCore

// 素材的进程级缓存（Sources/SrtFlow/VideoEditMediaAssetCache.swift）：
// 命中时合成取出来的帧要和不缓存时一样；同一路径换了文件（inode 变了）必须重开、帧跟着变；
// 原地改写（inode 没变，大小 / 修改时间变了）也必须重开。
// 共用 main.swift 里的 check / checkEqual / checkClose / averageBrightness / makeSolidVideo。

/// `white` 是一段全白的测试视频；`root` 是这次自检的临时目录。
func checkAssetCache(white: URL, root: URL) async throws {
    // 拷到自己的路径上：等会儿要在**同一路径**换成别的内容。
    let path = root.appendingPathComponent("cache-probe.mp4")
    try? FileManager.default.removeItem(at: path)
    try FileManager.default.copyItem(at: white, to: path)
    let info = MediaInfo(
        duration: 4, displaySize: CGSize(width: 64, height: 36), frameRate: 10,
        videoCodec: "h264", audioCodec: nil, hasAudio: false, audioCanCopyToMP4: false, fileBytes: 1
    )
    var state = TimelineState()
    state.mainClips = [EditClip(sourceURL: path, sourceDuration: 4, timelineStart: 0, info: info)]

    MediaAssetCache.removeAll()
    let before = MediaAssetCache.creations
    guard let first = await VideoEditCompositionBuilder.build(from: state) else {
        check(false, "素材缓存用例：第一次合成失败"); return
    }
    checkEqual(MediaAssetCache.creations, before + 1, "第一次建合成开一次文件")
    guard let second = await VideoEditCompositionBuilder.build(from: state) else {
        check(false, "素材缓存用例：第二次合成失败"); return
    }
    checkEqual(MediaAssetCache.creations, before + 1, "同一个文件第二次建合成不许重开（缓存命中）")
    for at in [0.5, 2.0, 3.5] {
        let cold = await averageBrightness(first, at: at)
        let warm = await averageBrightness(second, at: at)
        check(cold > 0.9, "缓存用例：第一次合成 \(at)s 处应当全白，实测 \(cold)")
        checkClose(warm, cold, 0.002, "缓存命中的合成 \(at)s 处的帧要和第一次一样")
    }

    // 同一路径换成全黑（删了再拷 = 新 inode）：必须重开，取出来的帧变黑。
    let black = try await makeSolidVideo(white: 0, seconds: 4, name: "cache-black.mp4")
    try FileManager.default.removeItem(at: path)
    try FileManager.default.copyItem(at: black, to: path)
    guard let third = await VideoEditCompositionBuilder.build(from: state) else {
        check(false, "素材缓存用例：换文件之后合成失败"); return
    }
    checkEqual(MediaAssetCache.creations, before + 2, "同一路径换了文件（inode 变了）必须重开")
    let level = await averageBrightness(third, at: 2.0)
    check(level < 0.1, "换成黑视频之后取出来的帧必须是黑的（缓存没按 inode 失效），实测 \(level)")
    _ = await VideoEditCompositionBuilder.build(from: state)
    checkEqual(MediaAssetCache.creations, before + 2, "换过之后再建又该命中，不许再开")

    // 原地改写（`ffmpeg -y` 往同一个输出路径写就是这样：截断重写，inode 不变）：只认 inode 的话
    // 会接着用读过旧文件头的那个 asset —— 必须靠大小 / 修改时间认出来、重开。
    let inodeBefore = inodeNumber(of: path)
    let handle = try FileHandle(forWritingTo: path)
    try handle.truncate(atOffset: 0)
    try handle.write(contentsOf: try Data(contentsOf: white))
    try handle.close()
    check(inodeBefore != nil && inodeNumber(of: path) == inodeBefore,
          "用例本身：原地改写之后 inode 不许变（变了测的就是上面那条路）")
    guard let fourth = await VideoEditCompositionBuilder.build(from: state) else {
        check(false, "素材缓存用例：原地改写之后合成失败"); return
    }
    checkEqual(MediaAssetCache.creations, before + 3, "同一路径原地改写过（inode 没变）也必须重开")
    let rewritten = await averageBrightness(fourth, at: 2.0)
    check(rewritten > 0.9, "原地改写成白视频之后取出来的帧必须是白的，实测 \(rewritten)")
}

private func inodeNumber(of url: URL) -> UInt64? {
    var info = stat()
    return stat(url.path, &info) == 0 ? UInt64(info.st_ino) : nil
}
