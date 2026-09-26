import Foundation
import SrtFlowCore

// 字幕分段：成句、断句、变速、边界合同、显示时间。2026-09-26 从 main.swift 搬出来（那个文件只许降），
// 同一天按主流规范重写了断句和显示时间。规则与出处：docs/architecture/subtitle-generation-style.md。
// 断句用例用的是南极工程里真实转写出来的词和时间（用户截图里的那几句）。

func runSubtitleSegmentationChecks() {
    checkMappingAndBoundaries()
    checkBreaksOnRealSpeech()
    checkChineseBreaks()
    checkLineFitAndConfig()
    checkDisplayTiming()
    checkSourceOverlap()    // SubtitleSourceOverlapChecks.swift
}

private func window(
    src: ClosedRange<Double>, tlStart: Double = 0, speed: Double = 1, lane: Int = 0, clip: UUID = UUID()
) -> SubtitleClipWindow {
    SubtitleClipWindow(
        clipID: clip, assetFingerprint: "asset-a",
        sourceStart: src.lowerBound, sourceEnd: src.upperBound,
        timelineStart: tlStart, speed: speed, laneRank: lane
    )
}

private func words(_ list: [(String, Double, Double)], confidence: Double = 0.9) -> [TimedWord] {
    list.map { TimedWord(text: $0.0, start: $0.1, end: $0.2, confidence: confidence) }
}

private func texts(_ out: SegmentedSubtitles) -> [String] { out.cues.map(\.text) }

/// 按原来的时间映射、边界合同、变速（这几条合同没变，字换成了去标点之后的样子）。
private func checkMappingAndBoundaries() {
    // 识别器风格的词流：英文词自带前导空格、标点附着词尾。
    let speech = words([
        ("Hello,", 0.0, 0.4), (" world.", 0.5, 0.9), (" This", 2.0, 2.3),
        (" is", 2.3, 2.5), (" a", 2.5, 2.6), (" test.", 2.6, 3.0)
    ])
    var mixed = speech
    mixed[1].confidence = 0.7

    // 1×：两句 → 两条；「Hello,」「world.」各不到 1 秒，并成一条；置信度取均值。
    let plain = SubtitleSegmenter.segment(words: mixed, window: window(src: 0...10))
    checkEqual(texts(plain), ["Hello world", "This is a test"], "1×：两句两条、去了标点、太短的小句并起来")
    checkEqual(plain.cues.map(\.start), [0, 2.0], "1×：起点是开口那一刻")
    if let id = plain.cues.first?.id, let meta = plain.meta[id] {
        check(abs((meta.recognitionConfidence ?? 0) - 0.8) < 0.0001, "1×：置信度均值")
        checkEqual(meta.provenance?.sourceAssetFingerprint, "asset-a", "1×：provenance 带素材指纹")
        checkEqual(meta.provenance?.sourceStart, 0, "1×：provenance 源起点")
    }

    // 2×：映射到时间线（timelineStart 5）；前一条说完离下一条不到半秒 → 延到下一条前 2 帧（接上、不闪）。
    let fastWindow = window(src: 0...10, tlStart: 5, speed: 2)
    let fast = SubtitleSegmenter.segment(words: speech, window: fastWindow)
    checkEqual(fast.cues.map(\.start), [5, 6.0], "2×：起点映射（句二 2.0s → 6.0s）")
    let config = SubtitleSegmentationConfig()
    let fastDoc = SubtitleSegmenter.assemble([fast], windows: [fastWindow], config: config).document
    check(abs((fastDoc.cues.first?.end ?? 0) - (6.0 - config.gap)) < 0.0001, "2×：短的一条延到下一条前 2 帧")

    // 0.1×：一句在时间线上被拉到 10s，超 maxCueDuration → 拆成多条（同一素材不同速度分段不同是合同行为）。
    let slow = SubtitleSegmenter.segment(words: Array(speech[2...]), window: window(src: 0...10, speed: 0.1))
    check(slow.cues.count > 1, "0.1×：超长句要按词边界拆条")
    check(slow.cues.allSatisfy { $0.duration <= 7.0 + 0.0001 }, "0.1×：每条不超 maxCueDuration")

    // 8×：两句背靠背，前一条被后一条顶住借不到位 → 阅读速度无解，如实告警。
    let rushedWindow = window(src: 0...10, speed: 8)
    let rushed = SubtitleSegmenter.segment(
        words: [TimedWord(text: "Fast one.", start: 0.0, end: 1.0), TimedWord(text: " Two.", start: 1.0, end: 1.5)],
        window: rushedWindow
    )
    let rushedResult = SubtitleSegmenter.assemble([rushed], windows: [rushedWindow], config: config)
    checkEqual(rushedResult.document.cues.count, 2, "8×：两句两条")
    if let first = rushedResult.document.cues.first, let second = rushedResult.document.cues.last {
        check(first.duration < 0.2, "8×：前句被后句顶住借不到位")
        checkEqual(rushedResult.meta[first.id]?.readingSpeedWarning, true, "8×：无解要告警")
        checkEqual(rushedResult.meta[second.id]?.readingSpeedWarning, false, "8×：后句借到位就不告警")
    }

    // 边界合同：半开区间中点归属，相邻分片不重复不遗漏；clamp 零时长丢弃。
    let a = window(src: 0...2.45)
    let b = window(src: 2.45...10, tlStart: 2.45)
    let textA = texts(SubtitleSegmenter.segment(words: speech, window: a)).joined(separator: "|")
    let textB = texts(SubtitleSegmenter.segment(words: speech, window: b)).joined(separator: "|")
    check(textA.contains("This is"), "边界：中点 2.4 的词归前片")
    check(!textA.contains("a test"), "边界：中点 2.55 的词不归前片")
    check(textB.contains("a test"), "边界：后片接住剩余词")
    check(!textB.contains("This"), "边界：前片的词不重复出现在后片")
    checkEqual(
        SubtitleSegmenter.attributeWords(speech, to: a).count + SubtitleSegmenter.attributeWords(speech, to: b).count,
        speech.count, "边界：两片词数合计 = 全量，无重复无遗漏"
    )
    check(SubtitleSegmenter.attributeWords([TimedWord(text: "x", start: 2.45, end: 2.45)], to: b).isEmpty,
          "边界：clamp 后零时长要丢弃")

    // 折行（允许两行时）：贪心塞行、只在词边界换行。
    let twoLines = SubtitleSegmentationConfig(maxLineCount: 2, maxLineUnits: 5)
    let wrapped = SubtitleSegmenter.segment(
        words: words([("aaaa", 0, 1), (" bbbb", 1, 2), (" cccc", 2, 3)]), window: window(src: 0...10), config: twoLines
    )
    checkEqual(wrapped.cues.first?.text, "aaaa bbbb\ncccc", "折行：贪心塞行、词边界换行")

    // 停顿断句：无标点也按停顿切；中文词直接相连。
    let paused = SubtitleSegmenter.segment(
        words: words([("无标点", 0, 0.5), ("的话", 0.5, 1.0), ("靠停顿", 2.5, 3.0)]), window: window(src: 0...10)
    )
    checkEqual(texts(paused), ["无标点的话", "靠停顿"], "停顿：超阈值断句")
}

/// 南极工程里真实转写出来的句子（用户截图图 3、图 5 和讨论里点到的几句）。
private func checkBreaksOnRealSpeech() {
    // 图 5：「you're born inside a box, a hospital, driven home inside another, a car,」—— 用户要拆成几条。
    // 片段的源区间是 9.03…15.28：前面的「next,」和后面的「your」中点在区间外，不归它。
    let born = SubtitleSegmenter.segment(words: words([
        (" next,", 8.506, 8.926), (" you're", 8.926, 9.766), (" born", 9.766, 9.886), (" inside", 9.886, 10.246),
        (" a", 10.246, 10.486), (" box,", 10.486, 10.966), (" a", 10.966, 11.326), (" hospital,", 11.326, 12.106),
        (" driven", 12.106, 12.826), (" home", 12.826, 13.006), (" inside", 13.006, 13.366),
        (" another,", 13.366, 14.026), (" a", 14.026, 14.506), (" car,", 14.506, 15.046), (" your", 15.046, 15.826)
    ]), window: window(src: 9.03...15.28))
    checkEqual(texts(born), ["you're born inside a box", "a hospital", "driven home inside another", "a car"],
               "图 5：按逗号拆成一个个小句（每条都够 1 秒）")

    // 图 3：43 个字符，比一行多半个字，只能切三条；不能切成「a continent that has never / belonged」这种。
    let continent = SubtitleSegmenter.segment(words: words([
        ("At", 1.680, 2.940), (" the", 2.940, 3.120), (" bottom", 3.120, 3.240), (" of", 3.240, 3.480),
        (" the", 3.480, 3.600), (" world", 3.600, 3.900), (" lies", 3.900, 4.320), (" a", 4.320, 4.440),
        (" continent", 4.440, 4.920), (" that", 4.920, 5.160), (" has", 5.160, 5.340), (" never", 5.340, 5.520),
        (" belonged", 5.520, 6.000), (" to", 6.000, 6.120), (" anyone.", 6.120, 6.660)
    ]), window: window(src: 0...10))
    checkEqual(texts(continent), ["At the bottom of the world", "lies a continent", "that has never belonged to anyone"],
               "图 3：几段一起挑切法，切在关系词「that」前面")

    // 太短的小句并给更短的那一边：「to me,」只有 0.4 秒。
    let gym = SubtitleSegmenter.segment(words: words([
        (" Even", 41.335, 41.815), (" a", 41.815, 42.055), (" gym,", 42.055, 42.475), (" to", 42.475, 42.595),
        (" me,", 42.595, 42.895), (" is", 42.895, 43.315), (" just", 43.315, 43.615), (" another", 43.615, 43.735),
        (" kind", 43.735, 43.915), (" of", 43.915, 44.035), (" box.", 44.035, 44.635)
    ]), window: window(src: 41...45))
    checkEqual(texts(gym), ["Even a gym to me", "is just another kind of box"], "太短的小句并到更短的邻居")

    // 只有一个词的小句不单独成条：「Oh,」并进后面。
    let oh = SubtitleSegmenter.segment(words: words([
        ("Oh,", 4.260, 5.700), (" you", 5.700, 5.820), (" are", 5.820, 6.000), (" the", 6.000, 6.180),
        (" first", 6.180, 6.360), (" one.", 6.360, 7.260)
    ]), window: window(src: 0...8))
    checkEqual(texts(oh), ["Oh you are the first one"], "一个词的小句并进后面那句")

    // 长句没有逗号：每条都放得下，没有一条以 a / the / to / my 这类词结尾。
    let pole = SubtitleSegmenter.segment(words: words([
        (" I'm", 53.815, 54.775), (" going", 54.775, 54.835), (" to", 54.835, 55.015), (" walk", 55.015, 55.195),
        (" from", 55.195, 55.375), (" the", 55.375, 55.495), (" South", 55.495, 55.675), (" Pole", 55.675, 56.095),
        (" all", 56.095, 56.395), (" the", 56.395, 56.575), (" way", 56.575, 56.695), (" to", 56.695, 56.815),
        (" the", 56.815, 56.875), (" North", 56.875, 57.055), (" Pole", 57.055, 57.355), (" and", 57.355, 58.315),
        (" stretch", 58.315, 58.675), (" my", 58.675, 58.915), (" box", 58.915, 59.035), (" until", 59.035, 59.335),
        (" it's", 59.335, 59.635), (" the", 59.635, 59.695), (" size", 59.695, 59.875), (" of", 59.875, 59.995),
        (" the", 59.995, 60.115), (" earth.", 60.115, 60.355)
    ]), window: window(src: 53...61))
    let dangling: Set<String> = ["a", "an", "the", "to", "of", "my", "and", "that", "has", "is"]
    check(pole.cues.count == 3, "长句：最少切几段能放下就切几段（119 个字符 → 3 条）")
    check(pole.cues.allSatisfy { SubtitleLineMeasure.units($0.text) <= 21 }, "长句：每条不超过 42 个字符")
    check(pole.cues.allSatisfy { !dangling.contains(String($0.text.split(separator: " ").last ?? "").lowercased()) },
          "长句：没有一条以功能词结尾")
    checkEqual(texts(pole).joined(separator: " "),
               "I'm going to walk from the South Pole all the way to the North Pole and stretch my box until it's the size of the earth",
               "长句：一个词都不丢")

    // 缩写的点不是句号：「in the U.S. today.」是一句。
    let acronym = SubtitleSegmenter.segment(words: words([
        ("in", 0, 0.3), (" the", 0.3, 0.5), (" U.S.", 0.5, 1.0), (" today.", 1.0, 1.6)
    ]), window: window(src: 0...5))
    checkEqual(texts(acronym), ["in the U.S. today"], "缩写的点不断句、也不去掉")
}

/// 中文：转写出来一个字一个词、逗号是单独的「 ，」；一行 16 个字，只在词边界上切。
private func checkChineseBreaks() {
    let chinese: [(String, Double, Double)] = [
        ("剪", 0.00, 1.02), ("辑", 1.02, 1.20), ("的", 1.20, 1.32), ("视", 1.32, 1.44), ("频", 1.44, 1.56),
        ("越", 1.56, 1.74), ("来", 1.74, 1.86), ("越", 1.86, 2.04), ("多", 2.04, 2.16), (" ，", 2.16, 2.40),
        ("把", 2.40, 2.52), ("硬", 2.52, 2.70), ("盘", 2.70, 2.88), ("都", 2.88, 3.06), ("撑", 3.06, 3.18),
        ("爆", 3.18, 3.30), ("了", 3.30, 3.54), (" ，", 3.54, 4.02), ("剪", 4.02, 4.20), ("映", 4.20, 4.32),
        ("是", 4.32, 4.62), ("否", 4.62, 4.68), ("有", 4.68, 4.86), ("可", 4.86, 4.98), ("能", 4.98, 5.04),
        ("在", 5.04, 5.28), ("保", 5.28, 5.46), ("证", 5.46, 5.64), ("画", 5.64, 5.88), ("面", 5.88, 6.00),
        ("不", 6.00, 6.18), ("受", 6.18, 6.36), ("损", 6.36, 6.54), ("的", 6.54, 6.66), ("前", 6.66, 6.78),
        ("提", 6.78, 6.90), ("下", 6.90, 7.08), ("大", 7.08, 7.68), ("幅", 7.68, 7.92), ("度", 7.92, 8.04),
        ("降", 8.04, 8.28), ("低", 8.28, 8.40), ("导", 8.40, 8.64), ("出", 8.64, 8.76), ("视", 8.76, 8.94),
        ("频", 8.94, 9.12), ("的", 9.12, 9.24), ("大", 9.24, 9.36), ("小", 9.36, 9.48), ("呢", 9.48, 9.66),
        (" ？", 9.66, 10.08)
    ]
    let config = SubtitleSegmentationConfig.generation(languageCode: "zh", frameDuration: 1.0 / 30, maxLineEms: .infinity)
    let out = SubtitleSegmenter.segment(words: words(chinese), window: window(src: 0...11), config: config)
    let lines = texts(out)
    checkEqual(Array(lines.prefix(2)), ["剪辑的视频越来越多", "把硬盘都撑爆了"], "中文：逗号处断开、逗号去掉")
    check(lines.count >= 4, "中文：33 个字的那一句切成几条")
    check(lines.allSatisfy { SubtitleLineMeasure.units($0) <= 16 }, "中文：每条不超过 16 个字")
    checkEqual(lines.dropFirst(2).joined(), "剪映是否有可能在保证画面不受损的前提下大幅度降低导出视频的大小呢？",
               "中文：一个字都不丢、问号留着")
    // 不切在词中间（系统分词），不让助词起头。
    let joined = lines.joined(separator: "|")
    for word in ["大幅度", "受损", "前提", "可能", "保证", "画面", "降低", "导出", "视频", "大小"] {
        check(!joined.contains(String(word.prefix(1)) + "|" + String(word.dropFirst())), "中文：不从「\(word)」中间切")
    }
    check(lines.allSatisfy { !"的了吗呢吧啊着过们".contains($0.first ?? " ") }, "中文：助词不起头")
}

/// 按画面宽度封一行（竖屏更短）；生成用的那一套按语言分档。
private func checkLineFitAndConfig() {
    let born = words([
        (" you're", 9.03, 9.766), (" born", 9.766, 9.886), (" inside", 9.886, 10.246), (" a", 10.246, 10.486),
        (" box,", 10.486, 10.966)
    ])
    let narrow = SubtitleSegmentationConfig(maxLineEms: 8)
    let out = SubtitleSegmenter.segment(words: born, window: window(src: 9...11), config: narrow)
    check(out.cues.count > 1, "画面宽度：竖屏放不下一整个小句就再切")
    check(out.cues.allSatisfy { SubtitleLineMeasure.ems($0.text) <= 8 }, "画面宽度：每条都放得下，不会被折行")

    let english = SubtitleSegmentationConfig.generation(languageCode: "en", frameDuration: 1.0 / 30, maxLineEms: 29)
    checkEqual(english.maxLineUnits, 21, "英文一档：每行 42 个字符")
    checkEqual(english.maxUnitsPerSecond, 10, "英文一档：20 字符 / 秒")
    checkEqual(english.maxLineEms, 29, "画面宽度原样带进来")
    check(abs(english.gap - 2.0 / 30) < 1e-9, "两条之间留 2 帧（按工程帧率）")
    let chinese = SubtitleSegmentationConfig.generation(languageCode: "zh", frameDuration: 1.0 / 24, maxLineEms: 29)
    checkEqual(chinese.maxLineUnits, 16, "中文一档：每行 16 个字")
    checkEqual(chinese.maxUnitsPerSecond, 9, "中文一档：9 字 / 秒")
    checkEqual(SubtitleSegmentationConfig.generation(languageCode: nil, frameDuration: 1.0 / 24, maxLineEms: 29).maxLineUnits,
               21, "语言不明按英文一档")
    checkEqual(SubtitleLineMeasure.units("ab 中文"), 3.5, "字数：半角算半个、全角算一个、空格也算")
    check(SubtitleLineMeasure.isMostlyFullWidth("用AI做剪映") && !SubtitleLineMeasure.isMostlyFullWidth("hello 世界"),
          "以全角为主：看得见的字里全角过半")
}

/// 显示时间：最短 5/6 秒、两条之间 2 帧、不到半秒的空档接上、说完多停半秒、不越过素材结尾。
private func checkDisplayTiming() {
    let config = SubtitleSegmentationConfig(frameDuration: 1.0 / 30)
    let gap = config.gap
    func cue(_ start: Double, _ end: Double, _ text: String = "some words here") -> SubtitleCue {
        SubtitleCue(start: start, end: end, text: text)
    }
    var cues = [cue(0, 1.0), cue(1.3, 2.0), cue(3.2, 3.4), cue(5.0, 5.1)]
    let lastID = cues[3].id
    SubtitleCueTiming.apply(to: &cues, limits: [lastID: 5.6], config: config)
    check(abs(cues[0].end - (1.3 - gap)) < 1e-9, "时间：空档不到半秒 → 接上，只留 2 帧")
    check(abs(cues[1].end - 2.5) < 1e-9, "时间：后面空得多 → 说完多停半秒")
    check(abs(cues[2].end - (3.2 + 5.0 / 6.0)) < 1e-9, "时间：太短 → 至少 5/6 秒")
    check(abs(cues[3].end - 5.6) < 1e-9, "时间：不越过它那段素材在时间线上的结尾")
    let gaps = zip(cues, cues.dropFirst()).map { $1.start - $0.end }
    check(gaps.allSatisfy { abs($0 - gap) < 1e-9 || $0 >= config.chainThreshold - 1e-9 },
          "时间：两条之间要么只差 2 帧、要么至少半秒")

    // 阅读速度按最终显示时长算；中文一档 9 字 / 秒。
    var meta: [UUID: CueMeta] = [:]
    let fastChinese = cue(0, 1.0, "这是一句十三个字的中文字幕")
    let slowChinese = cue(2, 4, "这是一句十三个字的中文字幕")
    meta[fastChinese.id] = CueMeta()
    meta[slowChinese.id] = CueMeta()
    let zh = SubtitleSegmentationConfig.generation(languageCode: "zh", frameDuration: 1.0 / 30, maxLineEms: .infinity)
    SubtitleCueTiming.markReadingSpeed([fastChinese, slowChinese], meta: &meta, config: zh)
    checkEqual(meta[fastChinese.id]?.readingSpeedWarning, true, "阅读速度：1 秒 13 个字超了")
    checkEqual(meta[slowChinese.id]?.readingSpeedWarning, false, "阅读速度：2 秒 13 个字没超")
}
