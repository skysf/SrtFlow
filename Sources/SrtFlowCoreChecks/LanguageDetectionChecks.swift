import Foundation
import SrtFlowCore

// 字幕源语言自动检测的评分裁决（SubtitleLanguageDetection）。
// 背景：docs/bugfixes/2026-08-09-subtitle-translate-after-same-language.md。
// 置信度数值取自 2026-08-09 真机实测：正确模型词置信度 ≈0.91–1.00，
// 错误模型（zh_CN 转英文音频）≈0.44–0.74。

func runLanguageDetectionChecks() {
    /// `text`：每个词的字（后面接序号）。中日韩的候选要写成中日韩的字 —— 它们先过「写成了这种语言的文字」那一关。
    func words(_ entries: [(start: Double, end: Double, confidence: Double?)], text: String = "w") -> [TimedWord] {
        entries.enumerated().map { index, entry in
            TimedWord(text: "\(text)\(index)", start: entry.start, end: entry.end, confidence: entry.confidence)
        }
    }

    // 打分：空词流 = 0（不许把「没词」当高置信）。
    checkEqual(SubtitleLanguageDetection.score(of: []), 0, "检测评分：空词流为 0")
    // 无置信度按中性 0.5 计。
    check(
        abs(SubtitleLanguageDetection.score(of: words([(0, 1, nil)])) - 0.5) < 1e-9,
        "检测评分：无置信度的词按 0.5 计"
    )
    // 词时长加权：2s@0.9 + 1s@0.3 → (0.9*2 + 0.3*1)/3 = 0.7，不是平均 0.6。
    check(
        abs(SubtitleLanguageDetection.score(of: words([(0, 2, 0.9), (2, 3, 0.3)])) - 0.7) < 1e-9,
        "检测评分：按词时长加权"
    )
    // 零时长词吃权重下限，不产生除零/NaN。
    let degenerate = SubtitleLanguageDetection.score(of: words([(1, 1, 0.8)]))
    check(abs(degenerate - 0.8) < 1e-9, "检测评分：零时长词按权重下限计")

    // ---- 阈值的标定（PR#22 复审 P1）----
    //
    // 判别区间来自实测：错误模型上限 0.74，正确模型下限 0.91。阈值必须落在
    // 中间，两侧都写成断言 —— 以后有人「调调看」就会当场红，而不是把某个
    // 错误模型悄悄放行。这是外部真值对账，不是拿常量跟自己比。
    check(
        SubtitleLanguageDetection.minimumConfidence > 0.74,
        "检测阈值必须高于实测的错误模型上限 0.74"
    )
    check(
        SubtitleLanguageDetection.minimumConfidence <= 0.91,
        "检测阈值必须不高于实测的正确模型下限 0.91"
    )
    // 「系统没给证据」不许过线。平台哪天整体不回报置信度，全候选一起跌到这个
    // 值 → 检测失败 → 引导手选，正是 fail-closed 想要的结局。
    check(
        SubtitleLanguageDetection.unknownConfidence < SubtitleLanguageDetection.minimumConfidence,
        "无置信度的中性分必须严格低于阈值（无证据不许被判成功）"
    )

    // 裁决：正确模型（高置信）胜出，与候选顺序无关。
    let english = SubtitleLanguageDetection.Candidate(
        localeIdentifier: "en_US",
        words: words([(0, 1, 0.95), (1, 2, 0.98), (2, 3, 0.91)])
    )
    // 实测的错误模型形态（zh_CN 转英文音频），加权分 0.55。
    let wrongModel = SubtitleLanguageDetection.Candidate(
        localeIdentifier: "zh_CN",
        words: words([(0, 1, 0.6), (1, 2, 0.5), (2, 3, 0.55)], text: "字")
    )
    checkEqual(
        SubtitleLanguageDetection.pick([wrongModel, english])?.localeIdentifier, "en_US",
        "检测裁决：高置信候选胜出"
    )
    // **只有一个错误模型时必须失败。** 这是原来那条 0.45 阈值放行的场景：
    // 用户的 Mac 上只装了中文模型、素材是英文 → 检测「成功」→ 整轨英文语音
    // 被按中文生成，得到一串乱码字幕。宁可返回 nil 让他手选。
    check(
        SubtitleLanguageDetection.pick([wrongModel]) == nil,
        "检测裁决：唯一候选是错误模型时必须判失败（不许因为没得挑就采用）"
    )
    // 两个候选**都**是错误模型：有得挑也不代表挑得对。
    let wrongModelB = SubtitleLanguageDetection.Candidate(
        localeIdentifier: "ko_KR",
        words: words([(0, 1, 0.52), (1, 2, 0.61), (2, 3, 0.48)], text: "말")
    )
    check(
        SubtitleLanguageDetection.pick([wrongModel, wrongModelB]) == nil,
        "检测裁决：两个候选都是错误模型时必须判失败"
    )
    // 实测错误模型的**上限**形态（0.74 那一档）也必须被挡住。
    let wrongModelPeak = SubtitleLanguageDetection.Candidate(
        localeIdentifier: "de_AT",
        words: words([(0, 1, 0.74), (1, 2, 0.74), (2, 3, 0.74)])
    )
    check(
        SubtitleLanguageDetection.pick([wrongModelPeak]) == nil,
        "检测裁决：错误模型的实测最高分 0.74 仍要判失败"
    )
    // 三个词全都没有 confidence：系统一个证据都没给，不能算成功。
    let noConfidence = SubtitleLanguageDetection.Candidate(
        localeIdentifier: "fr_FR",
        words: words([(0, 1, nil), (1, 2, nil), (2, 3, nil)])
    )
    check(
        SubtitleLanguageDetection.pick([noConfidence]) == nil,
        "检测裁决：全部词没有 confidence 时必须判失败"
    )
    check(
        SubtitleLanguageDetection.pick([noConfidence, wrongModel]) == nil,
        "检测裁决：无证据候选与错误模型混在一起也不许有赢家"
    )
    // 全部低于阈值 → nil（让用户手选，不硬猜）。
    let noise = SubtitleLanguageDetection.Candidate(
        localeIdentifier: "ja_JP",
        words: words([(0, 1, 0.2), (1, 2, 0.3), (2, 3, 0.25)], text: "の")
    )
    check(
        SubtitleLanguageDetection.pick([noise]) == nil,
        "检测裁决：全候选低于阈值时判定失败"
    )
    // 并列取先到者 —— 调用方按优先级排列候选（元数据 → 系统首选 → 已装）。
    let tieA = SubtitleLanguageDetection.Candidate(
        localeIdentifier: "de_DE", words: words([(0, 1, 0.9), (1, 2, 0.9), (2, 3, 0.9)])
    )
    let tieB = SubtitleLanguageDetection.Candidate(
        localeIdentifier: "fr_FR", words: words([(0, 1, 0.9), (1, 2, 0.9), (2, 3, 0.9)])
    )
    checkEqual(
        SubtitleLanguageDetection.pick([tieA, tieB])?.localeIdentifier, "de_DE",
        "检测裁决：并列取优先级更高的候选"
    )
    // 词数不足的候选在有足数候选时被排除（噪声上一两个高置信词不算数）。
    // 足数候选取 0.9 而不是贴着阈值的 0.8：这条用例守的是「谁有资格参赛」，
    // 别让它同时吊在门槛的浮点边界上。
    let sparse = SubtitleLanguageDetection.Candidate(
        localeIdentifier: "ko_KR", words: words([(0, 1, 0.99), (1, 2, 0.99)], text: "말")
    )
    let full = SubtitleLanguageDetection.Candidate(
        localeIdentifier: "en_GB", words: words([(0, 1, 0.9), (1, 2, 0.9), (2, 3, 0.9)])
    )
    checkEqual(
        SubtitleLanguageDetection.pick([sparse, full])?.localeIdentifier, "en_GB",
        "检测裁决：词数不足的候选让位于足数候选"
    )
    // ---- 短素材策略：放宽的是「参赛资格」，不是置信度门槛 ----
    //
    // 全部词数不足时退回全体比较，短素材才不至于永远检测不了。
    checkEqual(
        SubtitleLanguageDetection.pick([sparse])?.localeIdentifier, "ko_KR",
        "检测裁决：全候选词数不足时退回全体比较"
    )
    // 但退回来的候选照样要过阈值 —— 「短」不是硬猜的许可证。
    let sparseWeak = SubtitleLanguageDetection.Candidate(
        localeIdentifier: "it_IT", words: words([(0, 1, 0.6), (1, 2, 0.55)])
    )
    check(
        SubtitleLanguageDetection.pick([sparseWeak]) == nil,
        "检测裁决：词数不足的低分候选仍要判失败（短素材不等于放宽阈值）"
    )
    let sparseNoConfidence = SubtitleLanguageDetection.Candidate(
        localeIdentifier: "pt_BR", words: words([(0, 1, nil), (1, 2, nil)])
    )
    check(
        SubtitleLanguageDetection.pick([sparseNoConfidence]) == nil,
        "检测裁决：短且无置信度的候选必须判失败"
    )

    runScriptCheckCases(words: words)

    // ---- 候选构造：同一语言只占一个名额（PR#22 复审第二轮 P2）----
    //
    // 语言比较键：地区变体合并，文字系统不合并。
    checkEqual(
        SubtitleLanguageDetection.languageKey(ofLocaleIdentifier: "en_US"),
        SubtitleLanguageDetection.languageKey(ofLocaleIdentifier: "en_SG"),
        "语言键：en_US 与 en_SG 是同一种语言"
    )
    checkEqual(
        SubtitleLanguageDetection.languageKey(ofLocaleIdentifier: "en"),
        SubtitleLanguageDetection.languageKey(ofLocaleIdentifier: "en-Latn-US"),
        "语言键：en ≍ en-Latn-US"
    )
    check(
        SubtitleLanguageDetection.languageKey(ofLocaleIdentifier: "zh-Hans")
            != SubtitleLanguageDetection.languageKey(ofLocaleIdentifier: "zh-Hant"),
        "语言键：简繁是两种文字系统，不许合并"
    )
    check(
        SubtitleLanguageDetection.languageKey(ofLocaleIdentifier: "yue")
            != SubtitleLanguageDetection.languageKey(ofLocaleIdentifier: "zh_CN"),
        "语言键：粤语与普通话不是同一种"
    )
    check(
        SubtitleLanguageDetection.languageKey(ofLocaleIdentifier: "ja_JP")
            != SubtitleLanguageDetection.languageKey(ofLocaleIdentifier: "en_US"),
        "语言键：不同语言当然不能合并"
    )

    func source(_ id: String, download: Bool = false) -> SubtitleLanguageDetection.CandidateSource {
        SubtitleLanguageDetection.CandidateSource(localeIdentifier: id, allowsDownload: download)
    }

    // **本回归的判别用例**：三个英语变体不许吃光三个名额。
    // 修复前的按标识符去重会得到 [en_US, en_SG, en_IN] —— 装了日语模型也
    // 永远探不到日语（实测生产算法取到过 ["en_US", "zh_CN", "en_IN"]）。
    let mixed = SubtitleLanguageDetection.selectCandidates([
        source("en_US"), source("en_SG"), source("en_IN"), source("zh_CN"), source("ja_JP")
    ])
    checkEqual(
        mixed.map(\.localeIdentifier), ["en_US", "zh_CN", "ja_JP"],
        "候选构造：同一语言的变体只占一个名额，三个名额给三种语言"
    )
    checkEqual(
        Set(mixed.compactMap { SubtitleLanguageDetection.languageKey(ofLocaleIdentifier: $0.localeIdentifier) }).count,
        mixed.count,
        "候选构造：结果里不许出现两个同语言的候选"
    )
    // 变体去重取**优先级最高**的那个（顺序即优先级，元数据排最前）。
    let metadataFirst = SubtitleLanguageDetection.selectCandidates([
        source("en_GB", download: true), source("en_US"), source("ja_JP")
    ])
    checkEqual(
        metadataFirst.map(\.localeIdentifier), ["en_GB", "ja_JP"],
        "候选构造：同语言只留优先级最高的变体"
    )
    check(
        metadataFirst.first?.allowsDownload == true,
        "候选构造：元数据候选的下载许可不许被后面的变体稀释"
    )
    // 简繁必须都留下 —— 它们是两个方向，不是变体。
    checkEqual(
        SubtitleLanguageDetection.selectCandidates([
            source("zh-Hans"), source("zh-Hant"), source("ja_JP")
        ]).map(\.localeIdentifier),
        ["zh-Hans", "zh-Hant", "ja_JP"],
        "候选构造：zh-Hans 与 zh-Hant 各占一个名额"
    )
    // 截断上限就是探针预算。
    checkEqual(
        SubtitleLanguageDetection.selectCandidates([
            source("en_US"), source("ja_JP"), source("de_DE"), source("fr_FR")
        ]).count,
        SubtitleLanguageDetection.maximumCandidates,
        "候选构造：截断到探针预算"
    )
    checkEqual(SubtitleLanguageDetection.maximumCandidates, 3, "探针预算是 3 个候选")
    check(
        SubtitleLanguageDetection.selectCandidates([]).isEmpty,
        "候选构造：空来源给空结果"
    )
}

// ---- 中日韩的候选要写成中日韩的字（2026-10-02 南极工程）----
//
// 真机：英文旁白，中文模型写出「3red65 days」「rain forsts」这种拉丁字母，词置信度不低；英文模型这段停顿多，
// 加权只有 0.873。以前 `pick` 只比把握，中文以 0.9 胜出、整段转成乱码（docs/bugfixes/2026-10-03-auto-detect-picks-chinese-for-english.md）。
// 下面的英文词是那段旁白的真实转写（本机缓存，9.35–23.64 秒，35 个词，时间和置信度原样抄来）。
private func runScriptCheckCases(words: ([(start: Double, end: Double, confidence: Double?)], String) -> [TimedWord]) {
    let narration: [(String, Double, Double, Double)] = [
        (" the", 9.851, 10.091, 0.999), (" lives", 10.091, 10.211, 1.000), (" of", 10.211, 10.571, 0.999),
        (" people", 10.571, 10.751, 0.998), (" far", 10.751, 11.231, 0.998), (" from", 11.231, 11.531, 0.999),
        (" the", 11.531, 11.711, 0.996), (" modern", 11.711, 12.071, 0.998), (" world.", 12.071, 12.551, 0.748),
        (" Past", 12.671, 13.451, 0.537), (" Wales", 13.451, 13.871, 0.959), (" in", 13.871, 14.111, 0.954),
        (" the", 14.111, 14.231, 0.994), (" Southern", 14.231, 14.591, 0.811), (" Ocean,", 14.591, 15.131, 0.672),
        (" over", 15.131, 15.791, 0.767), (" the", 15.791, 16.091, 0.998), (" equator,", 16.091, 16.751, 0.898),
        (" head", 16.751, 17.351, 0.940), (" for", 17.351, 17.651, 0.995), (" the", 17.651, 17.771, 0.998),
        (" other", 17.771, 17.951, 0.977), (" end", 17.951, 18.131, 0.992), (" of", 18.131, 18.311, 0.998),
        (" the", 18.311, 18.431, 0.997), (" world,", 18.431, 18.911, 0.793), (" meeting", 18.911, 19.691, 0.634),
        (" life", 19.691, 20.111, 0.992), (" I", 20.111, 20.471, 0.997), (" have", 20.471, 20.591, 0.993),
        (" never", 20.591, 20.771, 0.999), (" seen", 20.771, 21.011, 0.999), (" before,", 21.011, 21.731, 0.754),
        (" pole", 21.731, 22.631, 0.952), (" to", 22.631, 22.871, 0.998),
    ]
    let english = SubtitleLanguageDetection.Candidate(
        localeIdentifier: "en_US",
        words: narration.map { TimedWord(text: $0.0, start: $0.1, end: $0.2, confidence: $0.3) }
    )
    let englishScore = SubtitleLanguageDetection.score(of: english.words)
    check(englishScore > 0.86 && englishScore < 0.88, "真实英文旁白的分数是 0.873（停顿多，比合成语音标定的 0.91 低）：\(englishScore)")
    // 中文模型转同一段：拉丁字母的近似单词，词置信度 0.9（比英文模型还高 —— 以前就是这样赢的）。
    let garbled = ["3red65", "days", "seven", "contenents", "into", "the", "deepest", "rain", "forsts", "across",
                   "the", "whides", "desits", "into", "the", "lifes", "of", "peeple"]
    let chinese = SubtitleLanguageDetection.Candidate(
        localeIdentifier: "zh_CN",
        words: garbled.enumerated().map { TimedWord(text: $1, start: 9.85 + Double($0) * 0.7, end: 10.5 + Double($0) * 0.7, confidence: 0.9) }
    )
    check(SubtitleLanguageDetection.score(of: chinese.words) > englishScore, "前提：中文模型的乱码分数比英文模型高（只比把握就会选它）")
    check(!SubtitleLanguageDetection.isWrittenInOwnScript(chinese), "中文模型写出来全是拉丁字母：不算写成了中文")
    check(SubtitleLanguageDetection.isWrittenInOwnScript(english), "英文候选不核对文字系统")
    checkEqual(SubtitleLanguageDetection.pick([english, chinese])?.localeIdentifier, "en_US", "南极工程：英文旁白判成英文（不是中文）")
    checkEqual(SubtitleLanguageDetection.pick([chinese, english])?.localeIdentifier, "en_US", "南极工程：中文排在前面也判成英文")
    check(SubtitleLanguageDetection.pick([chinese]) == nil, "只有中文模型、写出来是拉丁乱码：判失败（让 AI 带 language 再调），不是判成中文")

    // 正面对照：真中文照样认得出来，中英夹杂也是。
    let mandarin = SubtitleLanguageDetection.Candidate(
        localeIdentifier: "zh_CN", words: words([(0, 1, 0.93), (1, 2, 0.95), (2, 3, 0.94)], "南极")
    )
    let weakEnglish = SubtitleLanguageDetection.Candidate(
        localeIdentifier: "en_US", words: words([(0, 1, 0.6), (1, 2, 0.55), (2, 3, 0.6)], "w")
    )
    checkEqual(SubtitleLanguageDetection.pick([weakEnglish, mandarin])?.localeIdentifier, "zh_CN", "真中文照样判成中文")
    // 中英夹杂：一半的字是汉字（缓存里真中文的最低一档 43%）。
    let mixed = SubtitleLanguageDetection.Candidate(
        localeIdentifier: "zh_CN",
        words: [TimedWord(text: "今天", start: 0, end: 1, confidence: 0.92), TimedWord(text: "AI", start: 1, end: 2, confidence: 0.9),
                TimedWord(text: "剪辑", start: 2, end: 3, confidence: 0.93)]
    )
    check(SubtitleLanguageDetection.isWrittenInOwnScript(mixed), "中英夹杂（汉字占 2/3）算写成了中文")
    let mostlyLatin = SubtitleLanguageDetection.Candidate(
        localeIdentifier: "zh_CN",
        words: [TimedWord(text: "hello", start: 0, end: 1, confidence: 0.9), TimedWord(text: "world", start: 1, end: 2, confidence: 0.9),
                TimedWord(text: "好", start: 2, end: 3, confidence: 0.9)]
    )
    check(!SubtitleLanguageDetection.isWrittenInOwnScript(mostlyLatin), "汉字只占 1/11（低于 25%）：不算写成了中文")
    let japanese = SubtitleLanguageDetection.Candidate(localeIdentifier: "ja_JP", words: words([(0, 1, 0.9)], "こんにちは"))
    let korean = SubtitleLanguageDetection.Candidate(localeIdentifier: "ko_KR", words: words([(0, 1, 0.9)], "안녕하세요"))
    check(SubtitleLanguageDetection.isWrittenInOwnScript(japanese), "日文假名算写成了日文")
    check(SubtitleLanguageDetection.isWrittenInOwnScript(korean), "韩文谚文算写成了韩文")
    let digitsOnly = SubtitleLanguageDetection.Candidate(localeIdentifier: "zh_CN", words: words([(0, 1, 0.95)], "365"))
    check(!SubtitleLanguageDetection.isWrittenInOwnScript(digitsOnly), "一个字母都没有（全是数字）：不算写成了中文")
    check(SubtitleLanguageDetection.usesCJKScript("yue_CN") && SubtitleLanguageDetection.usesCJKScript("zh_TW"),
          "粤语、繁体中文也核对文字系统")
    check(!SubtitleLanguageDetection.usesCJKScript("es_ES") && !SubtitleLanguageDetection.usesCJKScript("en_US"),
          "西班牙语、英语不核对")
}

