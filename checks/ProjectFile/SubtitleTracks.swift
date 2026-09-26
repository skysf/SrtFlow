import Foundation
import SrtFlowCore

// 第 34 组：两条字幕轨（原文 / 译文）在工程里的合同。2026-09-26 从 main.swift 搬出眼睛那一段并按
// 「两条轨独立」重写（docs/plans/2026-09-26-hide-guides-independent-subtitles.md）：
//
//   1. 画面上排成几块（`subtitleScreenBlocks`，预览与烧录共用）：两只眼睛都开、译文没有自己的布局 =
//      叠成一块（原文在上）；译文有布局 = 各一块；只开一只 = 那一块；都关 = 一块都没有。数据面
//      （独立字幕文件）不受眼睛影响。
//   2. v6 及更早：译文轨默认隐藏（升级不许把旧成片变成双语）。
//   3. v22 及更早：译文与原文同 ID 的镜像对，打开时拆成两条独立轨；v23 文件里撞了 ID 的也换新。
//   4. `translationLayout` 按需落键、往返无损；`requiresFormatVersion23` 的判据。
//   5. 没有原文轨时，编辑入口不许凭空垫一条空轨（`editSubtitleTracks` 的 creatingOriginal）。

func checkSubtitleTracks(root: URL) throws {
    let dir = root.appendingPathComponent("subtitle-tracks")
    let media = dir.appendingPathComponent("a.mp4")
    makeFile(media)
    let cueA = SubtitleCue(index: 1, start: 0, end: 2, text: "hello")
    let cueB = SubtitleCue(index: 2, start: 2, end: 4, text: "world")
    let tA = SubtitleCue(index: 1, start: 0, end: 1, text: "你好")
    let tB = SubtitleCue(index: 2, start: 1, end: 4, text: "世界")

    var both = timeline(mainMedia: [media])
    both.subtitle = SubtitleDocumentModel(cues: [cueA, cueB])
    both.subtitleCompanion = SubtitleCompanion(
        translation: SubtitleDocumentModel(cues: [tA, tB]), targetLanguage: "zh-Hans", sourceLanguage: "en",
        origin: .imported, translationLinks: [tA.id: TranslationLink(sourceIDs: [cueA.id], sourceText: cueA.text)]
    )

    // ---- 1. 画面上排成几块 ----
    let stacked = both.subtitleScreenBlocks()
    checkEqual(stacked.map(\.tracks), [[.original, .translation]], "两只眼睛都开、译文没有自己的布局：叠成一块")
    checkEqual(stacked.first?.text(at: 1.5), "hello\n世界", "叠成一块：原文在上、译文在下（两条轨的句子起止不必对齐）")
    checkEqual(both.visibleSubtitleChoice, .bilingual, "两只眼睛都开 = 双语（导出面板的文案）")

    var separated = both
    separated.subtitleLayout = SubtitleLayout(marginLeft: 0, marginRight: 0, marginBottom: 80)
    separated.translationLayout = SubtitleLayout(marginLeft: 0, marginRight: 0, marginBottom: 900, fontScale: 0.8)
    let apart = separated.subtitleScreenBlocks()
    checkEqual(apart.map(\.tracks), [[.original], [.translation]], "译文有自己的布局：各一块")
    checkEqual(apart.last?.layout, separated.translationLayout, "分开摆：译文用自己的布局")
    checkEqual(apart.first?.layout, separated.subtitleLayout, "分开摆：原文用自己的布局")

    var translationOnly = both
    translationOnly.subtitleHidden = true
    translationOnly.subtitleLayout = separated.subtitleLayout
    checkEqual(translationOnly.subtitleScreenBlocks().map(\.tracks), [[.translation]], "只开译文：只有译文那一块")
    checkEqual(translationOnly.subtitleScreenBlocks().first?.layout, separated.subtitleLayout,
               "只开译文、它没有自己的布局：占原文那一块的位置")
    checkEqual(translationOnly.subtitleScreenBlocks().first?.text(at: 0.5), "你好", "只开译文：拿到的是译文")

    var none = both
    none.subtitleHidden = true
    none.translationHidden = true
    check(none.subtitleScreenBlocks().isEmpty, "两只眼睛都关：一块都没有（预览不画、不烧）")
    checkEqual(none.visibleSubtitleChoice, nil, "两只眼睛都关 = 什么都不显示")
    checkEqual(none.subtitleDocument(for: .translation)?.cues.map(\.id), [tA.id, tB.id], "都关也不影响译文文件导出")
    check(none.subtitleDocument(for: .original) != nil, "都关也不影响原文文件导出")

    var noTranslation = both
    noTranslation.subtitleCompanion = nil
    checkEqual(noTranslation.visibleSubtitleChoice, .original, "没有译文轨时只能是原文")
    check(!noTranslation.hasVisibleTranslation, "没有译文轨时 hasVisibleTranslation 为假")
    checkEqual(both.subtitleTrack(of: tB.id), .translation, "按 ID 找得到句子在哪条轨")
    checkEqual(both.subtitleCue(cueB.id)?.text, "world", "按 ID 找句子（哪条轨都找）")

    // ---- 4. translationLayout：按需落键、往返无损、v23 判据 ----
    let project = dir.appendingPathComponent("tracks.srtflowproj")
    try VideoEditProjectIO.save(separated, to: project)
    let separatedLoaded = try VideoEditProjectIO.load(from: project).timeline
    checkEqual(separatedLoaded.translationLayout, separated.translationLayout, "translationLayout 往返无损")
    checkEqual(separatedLoaded.subtitleCompanion?.translation?.cues.map(\.id), [tA.id, tB.id], "译文句的 ID 往返不变")
    try VideoEditProjectIO.save(both, to: project)
    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: project)) as? [String: Any]
    check((raw?["timeline"] as? [String: Any])?["translationLayout"] == nil, "叠在一起（nil）时不落 translationLayout 键")
    checkEqual(raw?["formatVersion"] as? Int, 23, "带译文轨的工程写 v23")
    check(both.requiresFormatVersion23, "有译文轨：v23 判据为真")
    check(!noTranslation.requiresFormatVersion23, "没有译文轨、也没有译文布局：v23 判据为假")

    // ---- 2 / 3. 老工程：v6 的眼睛迁移 + v22 的镜像对拆开 ----
    // 老文件用「真存一份 → 改版本号 → 删掉新键」造，不手写 JSON（手写的 cue 结构一旦跟不上模型，
    // 就变成「整份工程打不开」，测的是错的东西）。老版本里译文与原文**同 ID**，所以这里存镜像对。
    var mirrored = both
    var mirror = SubtitleDocumentModel(cues: [cueA, cueB])
    mirror.cues[0].text = "你好"
    mirror.cues[1].text = "世界"
    mirrored.subtitleCompanion = SubtitleCompanion(
        translation: mirror, origin: .imported, cueMeta: [cueB.id: CueMeta(translationStale: true)]
    )
    func legacy(_ version: Int, removing keys: [String]) throws -> TimelineState {
        let file = dir.appendingPathComponent("v\(version)-legacy.srtflowproj")
        try VideoEditProjectIO.save(mirrored, to: file)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        json["formatVersion"] = version
        var timelineJSON = json["timeline"] as! [String: Any]
        for key in keys { timelineJSON.removeValue(forKey: key) }
        json["timeline"] = timelineJSON
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        return try VideoEditProjectIO.load(from: file).timeline
    }
    let v6 = try legacy(6, removing: ["translationHidden"])
    checkEqual(v6.translationHidden, true, "v6 老工程：译文轨默认隐藏（不许把旧成片变成双语）")
    checkEqual(v6.visibleSubtitleChoice, .original, "v6 老工程：迁移后推导结果与旧版渲染一致")

    let v22 = try legacy(22, removing: [])
    let split = v22.subtitleCompanion
    checkEqual(split?.translation?.cues.map(\.text), ["你好", "世界"], "v22 老工程：译文照样在")
    check(split?.translation?.cues.allSatisfy { $0.id != cueA.id && $0.id != cueB.id } == true,
          "v22 老工程：译文句换了自己的 ID（不再和原文同 ID）")
    let links = (split?.translation?.cues ?? []).map { split?.translationLinks[$0.id]?.sourceIDs }
    checkEqual(links, [[cueA.id], [cueB.id]], "v22 老工程：来源记成原来那句原文")
    let staleness = (split?.translation?.cues ?? []).map { split?.isTranslationStale($0.id, original: v22.subtitle) }
    checkEqual(staleness, [false, true], "v22 老工程：当年标过过期的照样过期，没标的不过期")

    // v23 文件里译文 ID 撞了原文（外部改动）：读盘换新 ID，不丢句子。
    try VideoEditProjectIO.save(mirrored, to: project)
    let collided = try VideoEditProjectIO.load(from: project).timeline
    checkEqual(collided.subtitleCompanion?.translation?.cues.count, 2, "v23 撞 ID：句子不丢")
    check(collided.subtitleCompanion?.translation?.cues.allSatisfy { $0.id != cueA.id && $0.id != cueB.id } == true,
          "v23 撞 ID：换成新 ID（点一句不会选中两句）")

    // ---- 5. 没有原文轨时不凭空垫一条 ----
    var empty = TimelineState()
    empty.editSubtitleTracks { original, _ in original.cues.append(cueA) }
    checkEqual(empty.subtitle, nil, "没有原文轨：编辑入口什么也不做（不多出一行空字幕）")
    empty.editSubtitleTracks(creatingOriginal: true) { original, _ in original.cues.append(cueA) }
    checkEqual(empty.subtitle?.cues.count, 1, "手写第一行：就地建一条原文轨")
}
