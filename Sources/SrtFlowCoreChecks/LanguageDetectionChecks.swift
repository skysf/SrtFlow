import Foundation
import SrtFlowCore

// 字幕源语言自动检测的评分裁决（SubtitleLanguageDetection）。
// 背景：docs/bugfixes/2026-08-09-subtitle-translate-after-same-language.md。
// 置信度数值取自 2026-08-09 真机实测：正确模型词置信度 ≈0.91–1.00，
// 错误模型（zh_CN 转英文音频）≈0.44–0.74。

func runLanguageDetectionChecks() {
    func words(_ entries: [(start: Double, end: Double, confidence: Double?)]) -> [TimedWord] {
        entries.enumerated().map { index, entry in
            TimedWord(text: "w\(index)", start: entry.start, end: entry.end, confidence: entry.confidence)
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
        words: words([(0, 1, 0.6), (1, 2, 0.5), (2, 3, 0.55)])
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
        words: words([(0, 1, 0.52), (1, 2, 0.61), (2, 3, 0.48)])
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
        words: words([(0, 1, 0.2), (1, 2, 0.3), (2, 3, 0.25)])
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
        localeIdentifier: "ko_KR", words: words([(0, 1, 0.99), (1, 2, 0.99)])
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
}
