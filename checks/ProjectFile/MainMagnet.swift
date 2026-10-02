import Foundation
import SrtFlowCore

// 第 42 组：磁吸跟着工程走（`TimelineState.mainMagnet`，2026-10-02 用户拍板，同剪映每个草稿各记各的）。
// 存进工程文件、按需写键（磁吸关着的工程存一轮 diff 是空的）；老工程缺键读作关 —— 打开工程永远不改工程，
// 也不会因为这台机器上次拨开过磁吸，就在第一次编辑时把用户留的缝合上
//（docs/bugfixes/2026-10-02-magnet-closes-v1-gaps-on-any-edit.md）。编法见 scripts/check-project-file.sh。

func checkMainMagnet(root: URL) throws {
    let media = root.appendingPathComponent("magnet/a.mp4")
    makeFile(media)
    var state = TimelineState()
    state.mainClips = [
        EditClip(sourceURL: media, sourceDuration: 10, timelineStart: 0),
        EditClip(sourceURL: media, sourceDuration: 5, timelineStart: 12),   // 磁吸关着时留的缝
    ]
    let path = root.appendingPathComponent("magnet/p.srtflowproj")

    // ---- 关着：不写键，读回来是关、缝还在 ----
    try VideoEditProjectIO.save(state, to: path)
    let offRaw = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
    check((offRaw?["timeline"] as? [String: Any])?["mainMagnet"] == nil, "磁吸关着不写 mainMagnet 键（按需写键）")
    let off = try VideoEditProjectIO.load(from: path).timeline
    checkEqual(off.mainMagnet, false, "缺键读作关（老工程都没有这个键）")
    checkEqual(off.mainClips.map(\.timelineStart), [0, 12], "打开不排 V1：缝还在")

    // ---- 开着：写键、往返不丢；打开照样不排（排是编辑的事） ----
    state.mainMagnet = true
    try VideoEditProjectIO.save(state, to: path)
    let onRaw = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
    checkEqual((onRaw?["timeline"] as? [String: Any])?["mainMagnet"] as? Bool, true, "磁吸开着写 mainMagnet: true")
    let on = try VideoEditProjectIO.load(from: path).timeline
    checkEqual(on.mainMagnet, true, "往返不丢磁吸")
    checkEqual(on.mainClips.map(\.timelineStart), [0, 12], "打开时也不排（文件里写的是什么就是什么）")

    // ---- 老工程（2026-10-02 之前存的，没有这个键）：读作关，不管这台机器上次拨的是什么 ----
    var legacy = onRaw ?? [:]
    var legacyTimeline = legacy["timeline"] as? [String: Any] ?? [:]
    legacyTimeline.removeValue(forKey: "mainMagnet")
    legacy["timeline"] = legacyTimeline
    let legacyPath = root.appendingPathComponent("magnet/legacy.srtflowproj")
    try JSONSerialization.data(withJSONObject: legacy).write(to: legacyPath)
    checkEqual(try VideoEditProjectIO.load(from: legacyPath).timeline.mainMagnet, false, "老工程缺键读作关（磁吸关着时留的缝不会在第一次编辑时被合上）")
}
