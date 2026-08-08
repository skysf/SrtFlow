import Foundation
import SrtFlowCore

// 工程级字幕布局覆盖（SubtitleLayout）与单行分段默认值的合同。
// 背景：docs/architecture/subtitle-track-visibility-and-layout.md ——
// 预览拖框与 ASS 烧录必须共用同一份数值；生成的字幕默认单行。

func runSubtitleLayoutChecks() {
    let style = BurnInStyle.default

    // nil 覆盖 = 原样式，一个字段都不许动。
    checkEqual(style.assStyle(layout: nil), style.assStyle, "布局：nil 覆盖不改样式")

    // 覆盖生效：锚定强制底部中心，边距/字号全听覆盖的。
    let layout = SubtitleLayout(marginLeft: 120, marginRight: 60, marginBottom: 200, fontScale: 1.5)
    let overridden = style.assStyle(layout: layout)
    checkEqual(overridden.alignment, 2, "布局：覆盖后锚定固定为底部中心")
    checkEqual(overridden.marginL, 120, "布局：左边距进 ASS")
    checkEqual(overridden.marginR, 60, "布局：右边距进 ASS")
    checkEqual(overridden.marginV, 200, "布局：底边距进 ASS")
    check(
        abs(overridden.fontSize - style.fontSize * 1.5) < 0.0001,
        "布局：字号倍率进 ASS"
    )

    // assDocument 的接线：整份 ASS 文本里必须是覆盖后的样式行。
    let cue = SubtitleCue(index: 1, start: 0, end: 2, text: "hello")
    let doc = style.assDocument(cues: [cue], aspectRatio: 16.0 / 9.0, layout: layout)
    // ASS 样式行的边距是 4 位零填充（实测格式）。
    check(
        doc.contains(",2,0120,0060,0200,"),
        "布局：assDocument 写进覆盖后的对齐与边距"
    )
    let plain = style.assDocument(cues: [cue], aspectRatio: 16.0 / 9.0)
    check(
        plain.contains(String(
            format: ",%d,%04d,%04d,%04d,",
            style.position.assAlignment,
            style.marginHorizontal, style.marginHorizontal, style.marginVertical
        )),
        "布局：不带覆盖的 assDocument 保持全局样式"
    )

    // 构造钳制：负边距归零、倍率限幅。
    let clamped = SubtitleLayout(marginLeft: -5, marginRight: -1, marginBottom: -9, fontScale: 99)
    checkEqual(clamped.marginLeft, 0, "布局：负左边距归零")
    checkEqual(clamped.marginBottom, 0, "布局：负底边距归零")
    check(
        clamped.fontScale == SubtitleLayout.fontScaleRange.upperBound,
        "布局：字号倍率限幅"
    )

    // 生成默认单行（2026-08-09 产品决定）：默认配置行数 1、参数集版本随之升 2。
    let defaults = SubtitleSegmentationConfig()
    checkEqual(defaults.maxLineCount, 1, "分段：默认单行")
    checkEqual(SubtitleSegmentationConfig.version, 2, "分段：默认值变更必须升参数集版本")

    // 超长句在默认配置下拆成多条 cue，而不是折成第二行。
    let window = SubtitleClipWindow(
        clipID: UUID(), assetFingerprint: "asset-layout",
        sourceStart: 0, sourceEnd: 60, timelineStart: 0, speed: 1, laneRank: 0
    )
    let longSpeech: [TimedWord] = (0..<16).map { index in
        TimedWord(
            text: index == 0 ? "word\(index)" : " word\(index)",
            start: Double(index), end: Double(index) + 0.8, confidence: 0.9
        )
    }
    let out = SubtitleSegmenter.segment(words: longSpeech, window: window)
    check(out.cues.count > 1, "分段：超长句默认拆条")
    check(
        out.cues.allSatisfy { !$0.text.contains("\n") },
        "分段：默认配置绝不产出第二行"
    )
}
