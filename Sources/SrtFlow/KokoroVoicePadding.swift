import Foundation

// MARK: - Kokoro 读太短的一段会炸：后面垫一句再读，只留这一段自己的（纯值）
//
// 管什么：垫哪一句、这一段垫不垫、读出来算不算炸了。
// 为什么：Kokoro 的 CoreML 模型读很短的输入时输出会炸，到满幅的几十倍甚至几万倍（2026-09-29 实测：am_fenrir「Two.」+39 dB、
// 「Two」+73 dB、「Okay.」+24 dB，zm_yunxi「好。」+43 dB，zf_xiaoxiao「我们开始吧。」+33 dB、「欢迎回到这门课。」+17 dB；
// 换 CPU / GPU / 神经网络引擎都一样，是模型本身的毛病；整句五十个 token 上下都正常）。后面垫一句中性的话凑够长度就稳了：
// 同一批 13 个炸的例子垫完之后，这一段自己的声音峰值全在 −2 到 −9 dB、均方根 −16 到 −26 dB，和正常的说话一样。
// 读完按模型给的每个 token 的时长切回这一段自己的字（KokoroVoiceAssembly，切口不越过垫的那句开口处）。
// 垫完还炸就换另一句再读一次；两句都炸就用峰值最小的那次（AIVoiceLevel 的限幅兜底，不许一下压没整句）。
// 不管什么：怎么读（KokoroPieceReader）、怎么切（KokoroVoiceAssembly）。docs/bugfixes/2026-09-29-kokoro-short-pieces-explode.md

enum KokoroVoicePadding {
    /// 这一段不到这么多 token 就在后面垫一句（整句五十个 token 以下炸过，垫到七十以上）。
    static let minimumTokens = 72
    /// 这一段自己的声音里峰值超过满幅的 2 倍（+6 dB）就算炸了：正常说话的峰值在 −9 到 +2 dB。
    static let explodedPeak: Float = 2

    /// 每种语言两句垫的话：先用第一句，炸了换第二句。拼音文字前面带空格（接在这一段后面读）。
    static let tails: [String: [String]] = [
        "en": [" And that is how it works, one step at a time.", " Here is what we are going to look at next, step by step."],
        "zh": ["我们接下来一步一步地慢慢看。", "这就是今天想和大家分享的内容。"],
        "ja": ["これから一つずつ順番に見ていきましょう。", "今日はこのことについて話していきます。"],
        "es": [" Y así es como funciona, paso a paso.", " Esto es lo que vamos a ver ahora, poco a poco."],
        "fr": [" Et voilà comment ça marche, étape par étape.", " Voici ce que nous allons voir maintenant, pas à pas."],
        "it": [" Ed ecco come funziona, passo dopo passo.", " Ecco cosa vedremo adesso, un passo alla volta."],
        "pt": [" E é assim que funciona, passo a passo.", " Aqui está o que vamos ver agora, passo a passo."],
        "hi": [" और यह इसी तरह काम करता है, एक एक कदम करके।", " अब हम आगे यह देखेंगे, धीरे धीरे।"]
    ]

    /// 读这一段要试的几种垫法（nil = 不垫），按顺序试到不炸为止。够长的先不垫，炸了再垫。
    static func attempts(ownTokens: Int, language: String) -> [String?] {
        let padded = (tails[language] ?? []).map { Optional($0) }
        return ownTokens < minimumTokens ? (padded.isEmpty ? [nil] : padded) : [nil] + padded
    }

    /// 这一段自己的声音炸了没有：峰值超过 `explodedPeak`，或者出了非数字。
    static func exploded(_ samples: ArraySlice<Float>) -> Bool {
        samples.contains { !$0.isFinite || abs($0) > explodedPeak }
    }

    /// 这一段自己的声音有多响（峰值，非数字算无穷大）：几次都炸时挑最小的那次。
    static func peak(_ samples: ArraySlice<Float>) -> Float {
        samples.reduce(0) { $1.isFinite ? max($0, abs($1)) : .infinity }
    }
}
