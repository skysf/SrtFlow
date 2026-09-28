import Foundation

// MARK: - 配音的角色（纯值）
//
// 管什么：配方卡里写的是角色，不是某个具体的声音（方案第 16、43、49 条）。每个角色：语言、性别、语气、用哪个 Kokoro 音色
// （2026-09-28 用户听样音挑的），以及退到 macOS 声音时音调高一点还是原样。另外几样和 Kokoro 音色名有关的小规则：
// 哪些语言它能读、每种语言默认用哪个音色、音色名的第一个字母是哪种语言。
// 不管什么：这一次到底用哪个声音（AIVoiceChoice）。

struct AIVoiceRole: Equatable {
    enum Style: String { case lively, warm, plain, british }

    var name: String
    /// zh / en。
    var language: String
    var gender: AIVoiceChoice.Voice.Gender
    var style: Style
    /// 装了本机模型时用它。
    var kokoroVoice: String
    /// 退到 macOS 声音时的音调（AVSpeechUtterance.pitchMultiplier）：活泼的略高。
    var pitch: Double

    /// 全部角色。**顺序和名字要和小程序的词表一样**（MCPVocabulary.voiceRoles，check-mcp 对账）。
    /// 中文男声用男青年 yunxi、英文男声不用 michael（用户 2026-09-28 听样音定的）。
    static let all: [AIVoiceRole] = [
        AIVoiceRole(name: "zh_female_lively", language: "zh", gender: .female, style: .lively, kokoroVoice: "zf_xiaoyi", pitch: 1.08),
        AIVoiceRole(name: "zh_female_warm", language: "zh", gender: .female, style: .warm, kokoroVoice: "zf_xiaoxiao", pitch: 1.0),
        AIVoiceRole(name: "zh_male", language: "zh", gender: .male, style: .plain, kokoroVoice: "zm_yunxi", pitch: 1.0),
        AIVoiceRole(name: "en_female_lively", language: "en", gender: .female, style: .lively, kokoroVoice: "af_bella", pitch: 1.08),
        AIVoiceRole(name: "en_female_warm", language: "en", gender: .female, style: .warm, kokoroVoice: "af_heart", pitch: 1.0),
        AIVoiceRole(name: "en_male", language: "en", gender: .male, style: .plain, kokoroVoice: "am_fenrir", pitch: 1.0),
        AIVoiceRole(name: "en_female_british", language: "en", gender: .female, style: .british, kokoroVoice: "bf_emma", pitch: 1.0),
        AIVoiceRole(name: "en_male_british", language: "en", gender: .male, style: .british, kokoroVoice: "bm_george", pitch: 1.0)
    ]

    static func named(_ name: String) -> AIVoiceRole? {
        all.first { $0.name == name.lowercased() }
    }

    static var names: String { all.map(\.name).joined(separator: ", ") }

    /// 没点名时：按文字的语言用温和女声。
    static func fallback(forLanguage language: String) -> AIVoiceRole? {
        all.first { $0.language == language && $0.style == .warm }
    }

    /// 退到 macOS 声音时优先的地区（英式角色找英国的声音）。
    var preferredRegion: String {
        switch (language, style) {
        case ("en", .british): return "en-GB"
        case ("en", _): return "en-US"
        case ("zh", _): return "zh-CN"
        default: return language
        }
    }

    // MARK: Kokoro 的音色

    /// 下载多大（清单读到之前说给用户听；R2 上那一份 v1 是 333 MB）。
    static let kokoroDownloadSize = "333 MB"

    /// Kokoro 能读的语言（2026-09-28 探针：一份模型管这 8 种；韩语、德语等读出来是乱的，用 macOS 的声音）。
    static let kokoroLanguages: Set<String> = ["zh", "en", "ja", "es", "fr", "it", "pt", "hi"]

    /// 没点名、又不是中英文时，每种语言默认用哪个 Kokoro 音色。
    static func defaultKokoroVoice(forLanguage language: String) -> String? {
        if let role = fallback(forLanguage: language) { return role.kokoroVoice }
        return ["ja": "jf_alpha", "es": "ef_dora", "fr": "ff_siwis", "it": "if_sara", "pt": "pf_dora", "hi": "hf_alpha"][language]
    }

    /// 看起来是 Kokoro 的音色名（`af_heart`、`zm_yunxi`：一个语言字母 + f / m + 下划线 + 名字）。
    static func isKokoroName(_ name: String) -> Bool {
        let parts = name.lowercased().split(separator: "_", maxSplits: 1)
        guard parts.count == 2, parts[0].count == 2, let first = parts[0].first, let second = parts[0].last else { return false }
        return languageByPrefix[first] != nil && (second == "f" || second == "m") && parts[1].allSatisfy(\.isLetter)
    }

    /// 音色是哪种语言的（名字的第一个字母）。
    static func kokoroLanguage(ofVoice name: String) -> String? {
        name.lowercased().first.flatMap { languageByPrefix[$0] }
    }

    private static let languageByPrefix: [Character: String] = [
        "a": "en", "b": "en", "z": "zh", "j": "ja", "e": "es", "f": "fr", "i": "it", "p": "pt", "h": "hi"
    ]
}
