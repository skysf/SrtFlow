import Foundation

// MARK: - 配音的每一句放在哪一刻（纯值）
//
// 管什么：add_voiceover 的一批旁白，没给 start 的那一句接在上一句后面（留 `gap`）；第一句没给就放在播放头。以及每一句的文件叫什么。
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

    /// 文件名取这句的开头 24 个字，标点换成空格、多个空格并成一个（「在地球的最南端 冰山沉默地漂在海上」，不带句号逗号；
    /// 2026-09-28 冒烟看到的「……漂在海上。.m4a」）。撞名加编号在调用方（ExportFileName.unoccupied）。
    static func fileStem(_ text: String) -> String {
        let cleaned = String(text.prefix(24).map { ($0.isPunctuation || $0.isSymbol) && !"'’".contains($0) ? " " : $0 })
        return cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
