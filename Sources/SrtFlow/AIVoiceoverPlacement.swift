import Foundation

// MARK: - 配音的每一句放在哪一刻（纯值）
//
// 管什么：add_voiceover 的一批旁白，没给 start 的那一句接在上一句后面（留 `gap`）；第一句没给就放在播放头。
// 给了 start 的照给的放（撞上了由 add_clips 那一套往上抬一轨，`AITimelineEdits.place`）。
// 不管什么：合成、放上时间线（AIVoiceoverTool）。

enum AIVoiceoverPlacement {
    /// 两句之间默认留多少秒。
    static let gap = 0.3

    static func starts(given: [Double?], durations: [Double], playhead: Double) -> [Double] {
        var result: [Double] = []
        for (index, start) in given.enumerated() {
            let previousEnd = index > 0 ? result[index - 1] + durations[index - 1] : nil
            result.append(start ?? previousEnd.map { $0 + gap } ?? playhead)
        }
        return result
    }
}
