import Foundation

// 轨道的身份和「剪辑在哪条轨的第几个」。2026-09-30 从 VideoEditModels.swift 搬出来（那个文件是登记过的
// 老超标文件，只许降不许涨；给时间线加标尺标记那一次腾的地方）。纯值，没有逻辑。

/// 轨道的身份：主轨、第几条上层视频轨、第几条音频轨。
enum TrackSlot: Hashable, Sendable {
    case main
    case overlay(Int)
    case audio(Int)

    var isMain: Bool { if case .main = self { return true }; return false }
    var isAudio: Bool { if case .audio = self { return true }; return false }
}

struct ClipLocation: Hashable, Sendable {
    var track: TrackSlot
    var clipIndex: Int
}
