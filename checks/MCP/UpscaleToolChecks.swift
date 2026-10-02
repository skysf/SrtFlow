import Foundation
import SrtFlowMCPKit

// upscale_clip（2026-10-02）：小程序那份清单里的词表和 App 的类型逐项对账（档位 = FalUpscaleTiers、目标 = FalUpscaleTarget 按短边叫、
// 范围 = UpscaleRangeChoice），工具的定义（参数、必填、枚举、只在配了 fal 时列、上网、不删东西），说明里每个档位都点了名、
// 写的「about N min」和每档的典型时长一致（面板和进度也从同一个数算）。

func runUpscaleToolChecks() {
    // ---- 词表 ↔ App 的类型
    checkEqual(MCPVocabulary.upscaleTiers, FalUpscaleTiers.all.map(\.id), "the tier vocabulary is the App's tiers, in the panel's order")
    for name in MCPVocabulary.upscaleTiers { check(AIUpscaleNames.tier(name) != nil, "tier \(name) resolves") }
    check(MCPVocabulary.upscaleTiers.contains(AIUpscaleNames.defaultTierID), "the default tier is in the vocabulary")
    checkEqual(MCPVocabulary.upscaleTargets, FalUpscaleTarget.allCases.map(AIUpscaleNames.name(of:)), "the targets are the App's three, named by short side")
    checkEqual(AIUpscaleNames.target("2160p"), .p2160, "2160p is the 4K target")
    checkEqual(AIUpscaleNames.target("1080p"), .p1080, "1080p")
    check(AIUpscaleNames.target("4k") == nil && AIUpscaleNames.target("4K") == nil, "4K is not a name (the vocabulary says 2160p)")
    for name in MCPVocabulary.upscaleRanges { check(AIUpscaleNames.range(name) != nil, "range \(name) resolves") }
    checkEqual(AIUpscaleNames.range("longest"), .longestUse, "longest is the longest use in the project")
    checkEqual(AIUpscaleNames.range("clip"), .thisClip, "clip is this clip")
    checkEqual(AIUpscaleNames.range("file"), .wholeFile, "file is the whole file")
    for choice in [UpscaleRangeChoice.thisClip, .longestUse, .wholeFile] {
        check(MCPVocabulary.upscaleRanges.contains(AIUpscaleNames.name(of: choice)), "range \(choice) has a name in the vocabulary")
        checkEqual(AIUpscaleNames.range(AIUpscaleNames.name(of: choice)), choice, "range names round-trip")
    }

    // ---- 定义
    checkEqual(MCPToolName.upscaleClip.provider, .fal, "upscale_clip belongs to fal (listed only with a key)")
    let definition = MCPToolName.upscaleClip.definition
    check(definition.openWorld, "upscale_clip reaches out to fal.ai")
    check(!definition.readOnly && !definition.destructive, "upscale_clip writes a new file and changes clips but deletes nothing")
    let schema = definition.inputSchema
    checkEqual(schema["required"]?.arrayValue?.compactMap(\.stringValue), ["clip_id"], "only clip_id is required")
    let properties = schema["properties"]?.objectValue ?? [:]
    checkEqual(Set(properties.keys), ["clip_id", "tier", "target", "range"], "the parameters")
    checkEqual(properties["tier"]?["enum"]?.arrayValue?.compactMap(\.stringValue), MCPVocabulary.upscaleTiers, "tier lists the tiers")
    checkEqual(properties["target"]?["enum"]?.arrayValue?.compactMap(\.stringValue), MCPVocabulary.upscaleTargets, "target lists the targets")
    checkEqual(properties["range"]?["enum"]?.arrayValue?.compactMap(\.stringValue), MCPVocabulary.upscaleRanges, "range lists the ranges")
    let text = definition.description
    for word in ["fal.ai", "get_job", "waiting_for_user", "estimated_cost_usd", "replaced_ids", "source_size", "daily limit", "revert", "undo", "phase"] {
        check(text.contains(word), "the description mentions \(word)")
    }
    for id in MCPVocabulary.upscaleTiers { check(text.contains(id), "the description names tier \(id)") }
    for name in MCPVocabulary.upscaleTargets + MCPVocabulary.upscaleRanges { check(text.contains(name), "the description names \(name)") }
    // 说明里每档「about N min」和 typicalSeconds 折成的分钟数一致（面板、进度用的同一个数）。
    for tier in FalUpscaleTiers.all {
        let minutes = FalJobProgress.minutes(tier.typicalSeconds)
        check(text.contains("about \(minutes) min"), "\(tier.id): the description says about \(minutes) min")
    }
    // 总说明的 fal 那一行带着它（Claude Code 开场只看目录）。
    check(MCPInstructions.text(providers: [.fal]).contains("upscale_clip"), "the instructions' fal line names upscale_clip")
    check(!MCPInstructions.text.contains("upscale_clip"), "without a key the instructions do not mention it")
}
