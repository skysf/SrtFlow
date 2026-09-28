import Foundation

// MARK: - 配音用哪个声音（纯值）
//
// 管什么：配方卡里写的是**角色**（zh_female_lively、en_male_steady…，方案第 16、43 条），具体用哪个系统声音运行时按这台 Mac
// 装了哪些挑：同语言、同性别里高级 > 增强 > 默认；没有这个性别就退到另一个并说一声；只有默认质量的时候告诉用户去哪下载更好的。
// 也认系统声音的名字或 identifier（用户点名「用婷婷」）。每个角色带一点语气：活泼的音调略高，沉稳的略低。
// 不管什么：怎么合成（AISpeechSynthesis）、放上时间线（AIVoiceoverTool）。
//
// 排除的声音：Eloquence 那一族（Eddy、Flo、Reed…，机器人味）、老的「speech.synthesis.voice」那一族（Fred、Ralph…）、
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

    /// 一个角色：语言（zh / en）、性别、语气。
    struct Role: Equatable {
        enum Style: String { case lively, warm, steady }

        var language: String
        var gender: Voice.Gender
        var style: Style

        /// "zh_female_lively" → Role；不是角色名就是 nil（那就当系统声音的名字找）。
        init?(_ name: String) {
            let parts = name.lowercased().split(separator: "_").map(String.init)
            guard parts.count == 3, ["zh", "en"].contains(parts[0]), let style = Style(rawValue: parts[2]) else { return nil }
            switch parts[1] {
            case "female": gender = .female
            case "male": gender = .male
            default: return nil
            }
            language = parts[0]
            self.style = style
        }

        init(language: String, gender: Voice.Gender, style: Style) {
            self.language = language
            self.gender = gender
            self.style = style
        }

        /// 没点名时的角色：按文字的语言（中英以外的语言也照找），温和女声（纪录片、vlog 都合适）。
        static func fallback(forLanguage language: String) -> Role {
            Role(language: language, gender: .female, style: .warm)
        }

        /// 活泼的音调略高、沉稳的略低（AVSpeechUtterance.pitchMultiplier，1 = 原样）。
        var pitch: Double {
            switch style {
            case .lively: return 1.08
            case .warm: return 1.0
            case .steady: return 0.94
            }
        }
    }

    var voice: Voice
    var pitch: Double
    /// 要告诉用户的话（退到了另一个性别、只有默认质量）；没有就是 nil。
    var note: String?

    /// 按角色或名字挑。`requested` 为 nil 时用 `Role.fallback`。
    static func choose(_ requested: String?, textLanguage: String, from installed: [Voice]) throws -> AIVoiceChoice {
        let usable = installed.filter(isUsable)
        if let requested, Role(requested) == nil {
            let wanted = requested.lowercased()
            guard let voice = usable.first(where: { $0.name.lowercased() == wanted || $0.identifier.lowercased() == wanted }) else {
                throw AIToolError("There is no voice called \(requested) on this Mac. Use a role (\(roleNames)) or the name of an installed system voice.")
            }
            return AIVoiceChoice(voice: voice, pitch: 1, note: qualityNote(voice))
        }
        let role = requested.flatMap(Role.init) ?? Role.fallback(forLanguage: textLanguage)
        let sameLanguage = usable.filter { baseLanguage($0.language) == role.language }
            .sorted { comesFirst($0, $1, role: role) }
        guard !sameLanguage.isEmpty else {
            throw AIToolError("No \(languageName(role.language)) voice is installed on this Mac. \(downloadHint(role.language))")
        }
        let sameGender = sameLanguage.filter { $0.gender == role.gender }
        // 两个女声角色（活泼、温和）有两个女声时各用一个：活泼用排第一的，温和用排第二的。
        let pool = sameGender.isEmpty ? sameLanguage : sameGender
        let index = role.gender == .female && role.style == .warm && pool.count > 1 ? 1 : 0
        let voice = pool[index]
        var notes: [String] = []
        if sameGender.isEmpty {
            let wanted = role.gender == .male ? "male" : "female"
            notes.append("No \(wanted) \(languageName(role.language)) voice is installed, so \(voice.name) was used. \(downloadHint(role.language))")
        } else if let note = qualityNote(voice) {
            notes.append(note)
        }
        return AIVoiceChoice(voice: voice, pitch: role.pitch, note: notes.isEmpty ? nil : notes.joined(separator: " "))
    }

    static let roleNames = "zh_female_lively, zh_female_warm, zh_male_steady, en_female_lively, en_female_warm, en_male_steady"

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

    /// 排序：质量高的在前；同质量里大陆普通话 / 美式英语在前；再按 identifier（每次挑的都一样）。
    private static func comesFirst(_ a: Voice, _ b: Voice, role: Role) -> Bool {
        if a.quality != b.quality { return a.quality > b.quality }
        let preferredRegion = role.language == "zh" ? "zh-CN" : "en-US"
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
        "For a much better voice, the user can download a Premium or Enhanced \(languageName(language)) voice in System Settings → "
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
