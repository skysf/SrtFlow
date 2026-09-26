import Foundation

// 停顿后面第一个词，识别器把前面的静音也算进了它的开头 —— 估它真正开口在哪（2026-09-26）。
//
// 用户实测：「At the bottom of the world」字幕比声音早 0.9 秒出来；「That's not what I wanted to hear」
// 的「That's」整个没了。拿 ffmpeg silencedetect 对照南极工程的音频：**停顿被识别器并进了相邻的词** ——
// 句号后面的长停顿并进**下一个词的开头**（「At」识别成 1.68–2.94，声音 2.83 才有；「That's」识别成
// 0.56–1.76，声音 1.61 才有 —— 片段从 1.56 切开，拿整段算的中点 1.16 落在片段外面，整个词判给了别处）；
// 句末那个词后面的停顿并进**它自己的结尾**（「box.」识别成 30.00–30.90，声音 30.35 就停了）。
// 案例：docs/bugfixes/2026-09-26-pause-stretches-next-word.md。
//
// 管什么：一个素材的词流里，每个词的「开口时间」（显示用）和「说话中点」（判归哪段素材用）：
// - 只估被拉长的词（比宽松词长还长；宽松词长按字母数 / 字数给，故意偏长）；
// - 停顿在哪边看标点：前面是句号问号（或者它是列表第一个词）= 重停顿，逗号类 = 轻停顿；
//   它自己（或紧跟的纯标点词）收句 = 后面重停顿。前面重 → 说话在词尾那一截：开口 = 词尾 − 宽松词长
//   （字幕宁可早一两百毫秒，不能晚），中点看词尾那一截；后面重 → 说话在开头那一截，中点看开头那一截；
//   一样重不估。两边都没标点、长得离谱（比宽松词长多 0.5 秒）的，按停顿在前面算（实测句中如此）。
// 不管什么：识别器原样的时间照旧进缓存，只在分段时估。

public enum SubtitleSpeechOnset {

    public struct Estimate: Hashable, Sendable {
        /// 显示用的开口时间（素材源时间）。
        public var onset: Double
        /// 判归哪段素材用的说话中点。
        public var center: Double

        public init(onset: Double, center: Double) {
            self.onset = onset
            self.center = center
        }
    }

    /// 一个素材的词流（按开始时间排好）里每个词的估计。
    public static func estimate(_ words: [TimedWord]) -> [Estimate] {
        words.indices.map { index in
            let word = words[index]
            let plain = Estimate(onset: word.start, center: (word.start + word.end) / 2)
            let duration = word.end - word.start
            guard let display = displayAllowance(word.text), let core = coreAllowance(word.text),
                  duration > display else { return plain }
            switch pauseSide(index, in: words, extreme: duration > display + 0.5) {
            case .before: return Estimate(onset: word.end - display, center: word.end - core / 2)
            case .after: return Estimate(onset: word.start, center: word.start + core / 2)
            case .unknown: return plain
            }
        }
    }

    enum PauseSide { case before, after, unknown }

    /// 被拉长的这个词，停顿在它前面还是后面。
    static func pauseSide(_ index: Int, in words: [TimedWord], extreme: Bool) -> PauseSide {
        let before = pauseWeight(before: index, in: words)
        let after = pauseWeight(after: index, in: words)
        if before > after { return .before }
        if after > before { return .after }
        return before == 0 && extreme ? .before : .unknown
    }

    /// 前面的停顿有多重：列表第一个词、前一个词收句 = 2；前一个词带逗号类、中间空了 ≥ 0.15 秒 = 1。
    static func pauseWeight(before index: Int, in words: [TimedWord]) -> Int {
        guard index > 0 else { return 2 }
        let previous = words[index - 1]
        if SubtitleBreaks.endsSentence(previous.text) { return 2 }
        if SubtitleBreaks.endsClause(previous.text) || words[index].start - previous.end >= 0.15 { return 1 }
        return 0
    }

    /// 后面的停顿有多重：它自己（或紧跟的纯标点词，中文转写的「 ，」）收句 = 2，逗号类 / 后面空了 ≥ 0.15 秒 = 1。
    static func pauseWeight(after index: Int, in words: [TimedWord]) -> Int {
        var text = words[index].text
        let next = index + 1 < words.count ? words[index + 1] : nil
        if let next, letterCounts(next.text) == (0, 0) { text += next.text }
        if SubtitleBreaks.endsSentence(text) { return 2 }
        if SubtitleBreaks.endsClause(text) { return 1 }
        if let next, next.start - words[index].end >= 0.15 { return 1 }
        return 0
    }

    /// 宽松的词长（秒，显示用，偏长）：0.2 + 每个字母 0.06；中日韩每个字 0.15。没有字（纯标点）就不估。
    static func displayAllowance(_ text: String) -> Double? {
        let (latin, full) = letterCounts(text)
        guard latin + full > 0 else { return nil }
        return 0.2 + 0.06 * Double(latin) + 0.15 * Double(full)
    }

    /// 更紧的词长（秒，判归属用）：0.1 + 每个字母 0.03；中日韩每个字 0.08。
    static func coreAllowance(_ text: String) -> Double? {
        let (latin, full) = letterCounts(text)
        guard latin + full > 0 else { return nil }
        return 0.1 + 0.03 * Double(latin) + 0.08 * Double(full)
    }

    /// 字母数字（半角）和中日韩的字各几个；标点、撇号、空格不算。
    private static func letterCounts(_ text: String) -> (latin: Int, full: Int) {
        var latin = 0
        var full = 0
        for scalar in text.unicodeScalars {
            if SubtitleLineMeasure.isFullWidth(scalar) {
                if CharacterSet.letters.contains(scalar) { full += 1 }
            } else if CharacterSet.alphanumerics.contains(scalar) {
                latin += 1
            }
        }
        return (latin, full)
    }
}
