import Foundation
import SrtFlowCore

// MARK: - 配旁白用 fal 的声音时，挑哪个音色（纯值）
//
// 管什么：方案第 42 条的最上面一档 —— 用户接了 fal 就用 fal 的声音（Eleven v4）配旁白。角色（`AIVoiceRole`）换成 ElevenLabs 的预制音色名；
// AI 直接点名 ElevenLabs 的音色（`Rachel`、`Brian`……）也认；都没点名按文字的语言取温和的那个角色。
// 音色名是 fal 在 Eleven v4 的 `voice` 字段例子里列的那一批（2026-09-29 读接口定义：Aria、Roger、Sarah、Laura、Charlie、George、Callum、
// River、Liam、Charlotte、Alice、Matilda、Will、Jessica、Eric、Chris、Brian、Daniel、Lily、Bill，默认 Rachel）。
// 不管什么：这一次用不用 fal（额度和 Key，AIVoiceoverTool）、怎么调（AIFalVoice）。

enum AIFalVoices {
    /// fal 的 Eleven v4 认的预制音色（大小写照它写的）。
    static let premade = [
        "Rachel", "Aria", "Roger", "Sarah", "Laura", "Charlie", "George", "Callum", "River", "Liam", "Charlotte", "Alice",
        "Matilda", "Will", "Jessica", "Eric", "Chris", "Brian", "Daniel", "Lily", "Bill"
    ]

    /// 角色 → 音色。**名字和 `AIVoiceRole.all` 一一对上**（check-fal 对账）。
    /// 女声：活泼 = Jessica（明亮）、温和 = Sarah（柔和）、英式 = Alice；男声：Brian（低沉稳重）、Eric（顺滑可信）、英式 = George（温暖）。
    /// ElevenLabs 的多语言模型用同一个音色读中英文，所以中文角色也用这几个。
    static let byRole: [String: String] = [
        "zh_female_lively": "Jessica", "zh_female_warm": "Sarah", "zh_male": "Eric",
        "en_female_lively": "Jessica", "en_female_warm": "Rachel", "en_male": "Brian",
        "en_female_british": "Alice", "en_male_british": "George"
    ]

    /// 没点名时：按文字的语言取温和的那个角色的音色；认不出语言用默认的 Rachel。
    static func defaultVoice(forLanguage language: String) -> String {
        AIVoiceRole.fallback(forLanguage: language).flatMap { byRole[$0.name] } ?? "Rachel"
    }

    static func voice(for role: AIVoiceRole) -> String { byRole[role.name] ?? "Rachel" }

    /// AI 点名的是不是 ElevenLabs 的预制音色（大小写不敏感）；是就回规范写法。
    static func named(_ requested: String) -> String? {
        premade.first { $0.caseInsensitiveCompare(requested.trimmingCharacters(in: .whitespaces)) == .orderedSame }
    }

    // MARK: fal 报的词时间 → 生成字幕认的词

    /// 词的写法照识别器的（`AIVoiceWords`）：英文词带着前面的空格、标点贴在词后面；中日韩的字之间没有空格。
    /// **词的字数要和原文对得上**（字母数字数出来差三成以内）：fal 没写 `timestamps` 元素的形状，认错了形状宁可不要 ——
    /// 没有词时间字幕就只是没有，不会错位。
    static func timedWords(_ times: [FalWordTime], text: String, duration: Double) -> [TimedWord] {
        guard !times.isEmpty, duration > 0 else { return [] }
        let spoken = letterCount(text)
        let reported = times.reduce(0) { $0 + letterCount($1.text) }
        guard spoken > 0, Double(reported) >= Double(spoken) * 0.7, Double(reported) <= Double(spoken) * 1.3 else { return [] }
        return times.enumerated().map { index, time in
            let start = min(max(time.start, 0), duration)
            // 至少 20 毫秒：一个词也得有个长度（同 AIVoiceWords）。
            let end = max(min(time.end, duration), start + 0.02)
            let cjk = time.text.unicodeScalars.first.map(isCJK) ?? false
            return TimedWord(text: index == 0 || cjk ? time.text : " " + time.text, start: start, end: end)
        }
    }

    private static func letterCount(_ text: String) -> Int {
        text.filter { $0.isLetter || $0.isNumber }.count
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        (0x3040...0x30FF).contains(scalar.value) || (0x3400...0x9FFF).contains(scalar.value) || (0xAC00...0xD7AF).contains(scalar.value)
    }

    // MARK: 克隆用的参考音频

    /// 16 位单声道 PCM 包成 WAV（44 字节头 + 数据）：fal 的克隆模型要一段参考音频，data URI 直接编进请求。
    static func wavData(samples: [Int16], sampleRate: Int) -> Data {
        let dataBytes = samples.count * 2
        var data = Data()
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append32(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8)); data.append(contentsOf: Array("fmt ".utf8))
        append32(16); append16(1); append16(1)                       // PCM、单声道
        append32(UInt32(sampleRate)); append32(UInt32(sampleRate * 2)); append16(2); append16(16)
        data.append(contentsOf: Array("data".utf8)); append32(UInt32(dataBytes))
        samples.withUnsafeBufferPointer { buffer in
            for sample in buffer { append16(UInt16(bitPattern: sample)) }
        }
        return data
    }
}
