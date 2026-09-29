import Foundation

// MARK: - 配音用哪个声音（纯值）
//
// 管什么：这一次配音用 SrtFlow 自己的声音（本机的 Kokoro，方案第 48 条）还是这台 Mac 的系统声音，用哪一个。
// - 装了 Kokoro、这种语言它能读：用它 —— 点名的 Kokoro 音色、角色对应的音色（AIVoiceRole），或者这种语言默认的那个。
// - 没装、或者它读不了这种语言：用系统声音，同语言同性别里高级 > 增强 > 默认（英式角色找英国的声音），没有这个性别就退到
//   另一个并说一声；只有默认质量时说去哪下载更好的；Kokoro 能读这种语言却没下载时，告诉 AI「SrtFlow 自己的声音好得多，
//   可以直接下载」（第 50 条：让 AI 知道）。
// - 点名一个 Kokoro 音色但还没下载：报错，叫 AI 先下载。点名系统声音的名字：就用它。
// 不管什么：怎么合成（KokoroVoiceSpeech / AISpeechSynthesis）、放上时间线（AIVoiceoverTool）。
//
// 系统声音里不用的：Eloquence 那一族（Eddy、Flo、Reed…，机器人味）、老的「speech.synthesis.voice」那一族（Fred、Ralph…）、
// 新奇声音和「个人声音」（要单独授权，第 43 条不做）。

struct AIVoiceChoice: Equatable {
    /// 一个装在这台 Mac 上的系统声音（从 AVSpeechSynthesisVoice 抄出来的几样，好测）。
    struct Voice: Equatable {
        enum Gender { case female, male, unspecified }

        var identifier: String
        var name: String
        /// BCP-47，如 zh-CN、en-US。
        var language: String
        var gender: Gender
        /// 1 默认、2 增强、3 高级。
        var quality: Int
        var isNovelty = false
        var isPersonal = false

        var qualityName: String { quality >= 3 ? "Premium" : quality == 2 ? "Enhanced" : "basic" }
    }

    enum Engine: Equatable {
        /// SrtFlow 自己的声音（Kokoro）：音色名、按哪种语言读。
        case kokoro(voice: String, language: String)
        /// 这台 Mac 的系统声音。
        case system(Voice)
    }

    var engine: Engine
    /// 只对系统声音有用。
    var pitch: Double = 1
    /// 要告诉用户的话（没下载 SrtFlow 的声音、退到了另一个性别、只有默认质量）；没有就是 nil。
    var note: String?

    var name: String {
        switch engine {
        case .kokoro(let voice, _): return voice
        case .system(let voice): return voice.name
        }
    }

    var qualityName: String {
        switch engine {
        case .kokoro: return "SrtFlow voice"
        case .system(let voice): return voice.qualityName
        }
    }

    /// - Parameters:
    ///   - requested: 角色名、Kokoro 音色名、系统声音的名字；nil = 按文字的语言挑。
    ///   - kokoroVoices: 装好的 Kokoro 音色；nil = 没下载。
    static func choose(_ requested: String?, textLanguage: String, kokoroVoices: [String]?,
                       installed: [Voice]) throws -> AIVoiceChoice {
        if let requested, AIVoiceRole.named(requested) == nil, AIVoiceRole.isKokoroName(requested) {
            return try kokoroByName(requested.lowercased(), textLanguage: textLanguage, installed: kokoroVoices)
        }
        let role = requested.flatMap(AIVoiceRole.named)
        if let requested, role == nil {
            return try systemByName(requested, installed: installed)
        }
        let language = role?.language ?? textLanguage
        if let kokoroVoices, AIVoiceRole.kokoroLanguages.contains(language),
           let voice = role?.kokoroVoice ?? AIVoiceRole.defaultKokoroVoice(forLanguage: language), kokoroVoices.contains(voice) {
            return AIVoiceChoice(engine: .kokoro(voice: voice, language: language))
        }
        var choice = try system(role: role, language: language, installed: installed)
        if kokoroVoices == nil, AIVoiceRole.kokoroLanguages.contains(language) {
            choice.note = [kokoroHint, choice.note].compactMap { $0 }.joined(separator: " ")
        }
        return choice
    }

    /// 没下载 SrtFlow 的声音时给 AI 的那一句（第 50 条）。
    static let kokoroHint = "SrtFlow's own voices sound much better than this Mac's voices, but they are not downloaded: "
        + "call add_voiceover with download_voices=true to download them (about \(AIVoiceRole.kokoroDownloadSize)) and tell the user."

    private static func kokoroByName(_ voice: String, textLanguage: String, installed: [String]?) throws -> AIVoiceChoice {
        guard let installed else {
            throw AIToolError("\(voice) is one of SrtFlow's own voices, which are not downloaded yet. Call add_voiceover with "
                + "download_voices=true first and tell the user.")
        }
        guard installed.contains(voice) else {
            throw AIToolError("SrtFlow has no voice called \(voice). Its voices: \(installed.joined(separator: ", ")).")
        }
        // 按文字的语言读（Kokoro 能读的话）；读不了就按音色自己的语言。
        let language = AIVoiceRole.kokoroLanguages.contains(textLanguage)
            ? textLanguage : AIVoiceRole.kokoroLanguage(ofVoice: voice) ?? "en"
        return AIVoiceChoice(engine: .kokoro(voice: voice, language: language))
    }

    private static func systemByName(_ requested: String, installed: [Voice]) throws -> AIVoiceChoice {
        let wanted = requested.lowercased()
        guard let voice = installed.filter(isUsable).first(where: {
            $0.name.lowercased() == wanted || $0.identifier.lowercased() == wanted
        }) else {
            throw AIToolError("There is no voice called \(requested). Use a role (\(AIVoiceRole.names)), one of SrtFlow's "
                + "voices (such as af_heart or zf_xiaoxiao), or the name of a voice installed on this Mac.")
        }
        return AIVoiceChoice(engine: .system(voice), note: qualityNote(voice))
    }

    /// 按角色（或语言）挑一个系统声音。
    private static func system(role: AIVoiceRole?, language: String, installed: [Voice]) throws -> AIVoiceChoice {
        let region = role?.preferredRegion ?? language
        let sameLanguage = installed.filter(isUsable).filter { baseLanguage($0.language) == language }
            .sorted { comesFirst($0, $1, preferredRegion: region) }
        guard !sameLanguage.isEmpty else {
            throw AIToolError("No \(languageName(language)) voice is installed on this Mac. \(downloadHint(language))")
        }
        let gender = role?.gender ?? .female
        let sameGender = sameLanguage.filter { $0.gender == gender }
        // 两个女声角色（活泼、温和）有两个女声时各用一个：活泼用排第一的，温和用排第二的。
        let pool = sameGender.isEmpty ? sameLanguage : sameGender
        let index = gender == .female && (role?.style ?? .warm) == .warm && pool.count > 1 ? 1 : 0
        let voice = pool[index]
        var notes: [String] = []
        if sameGender.isEmpty {
            let wanted = gender == .male ? "male" : "female"
            notes.append("No \(wanted) \(languageName(language)) voice is installed on this Mac, so \(voice.name) was used. \(downloadHint(language))")
        } else if let note = qualityNote(voice) {
            notes.append(note)
        }
        return AIVoiceChoice(engine: .system(voice), pitch: role?.pitch ?? 1, note: notes.isEmpty ? nil : notes.joined(separator: " "))
    }

    // MARK: 系统声音的小规则

    /// 语速倍数 → `AVSpeechUtterance.rate`。两者**不是线性的**：2026-09-28 实测（婷婷、Samantha 一样，和声音无关）
    /// rate 0.5 = 正常，0.55 已经快了 1.29 倍，0.3 只慢到 0.77 倍，中间还有几个平台（系统内部按档位走）。
    /// 表是（实际倍数, rate），按倍数线性插值反查；超出两头就夹住。
    static let measuredRates: [(speed: Double, rate: Double)] = [
        (0.50, 0.0), (0.59, 0.10), (0.72, 0.20), (0.77, 0.25), (0.83, 0.35), (0.91, 0.40), (1.00, 0.50),
        (1.04, 0.51), (1.08, 0.52), (1.18, 0.53), (1.23, 0.54), (1.29, 0.55), (1.43, 0.575), (1.59, 0.60),
        (1.83, 0.65), (2.10, 0.70)
    ]

    static func utteranceRate(forSpeed speed: Double) -> Double {
        let table = measuredRates
        guard let first = table.first, let last = table.last else { return 0.5 }
        if speed <= first.speed { return first.rate }
        if speed >= last.speed { return last.rate }
        for (lower, upper) in zip(table, table.dropFirst()) where speed <= upper.speed {
            let fraction = (speed - lower.speed) / (upper.speed - lower.speed)
            return lower.rate + (upper.rate - lower.rate) * fraction
        }
        return last.rate
    }

    static func isUsable(_ voice: Voice) -> Bool {
        !voice.isNovelty && !voice.isPersonal
            && !voice.identifier.contains(".eloquence.")
            && !voice.identifier.hasPrefix("com.apple.speech.synthesis.voice.")
    }

    /// 排序：质量高的在前；同质量里角色要的地区（大陆普通话 / 美式或英式英语）在前；再按 identifier（每次挑的都一样）。
    private static func comesFirst(_ a: Voice, _ b: Voice, preferredRegion: String) -> Bool {
        if a.quality != b.quality { return a.quality > b.quality }
        let aPreferred = a.language == preferredRegion
        let bPreferred = b.language == preferredRegion
        if aPreferred != bPreferred { return aPreferred }
        return a.identifier < b.identifier
    }

    static func baseLanguage(_ bcp47: String) -> String {
        String(bcp47.lowercased().split(separator: "-").first ?? "")
    }

    private static func qualityNote(_ voice: Voice) -> String? {
        guard voice.quality < 2 else { return nil }
        return "\(voice.name) is a basic-quality voice. \(downloadHint(baseLanguage(voice.language)))"
    }

    static func downloadHint(_ language: String) -> String {
        "For a better Mac voice, the user can download a Premium or Enhanced \(languageName(language)) voice in System Settings → "
            + "Accessibility → Spoken Content → System Voice → Manage Voices; SrtFlow uses it from the next voiceover on."
    }

    private static func languageName(_ language: String) -> String {
        switch language {
        case "zh": return "Chinese"
        case "en": return "English"
        default: return language
        }
    }
}
