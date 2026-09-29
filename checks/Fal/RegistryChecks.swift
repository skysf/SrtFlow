import Foundation
import SrtFlowMCPKit

// 第一组：模型表和估价。
// - 每种事有且只有一个默认；每个登记的端点都合规、有对应的写法（FalDialect）、有接口定义快照，快照里的提交路径就是它的端点号
//   （快照放错文件 / 端点改了快照没换，当场红）；
// - 估价的算术：登记的单价是从 fal 的页面抄的，这里把几个典型用量的钱数钉死（视频按分辨率档、音乐不满一分钟按一分钟……）；
// - 小程序里抄的词表（kind / 分辨率 / 画幅）和 App 里的类型对账。

func runRegistryChecks() {
    // 每种事一个默认，全覆盖
    checkEqual(FalModels.known.count, FalModel.Kind.allCases.count, "one registered model per kind")
    checkEqual(Set(FalModels.known.map(\.kind)), Set(FalModel.Kind.allCases), "every kind has a registered model")
    checkEqual(FalModels.defaults.count, FalModel.Kind.allCases.count, "one default per kind")
    for kind in FalModel.Kind.allCases {
        check(FalModels.preset(for: kind).kind == kind, "preset(\(kind)) is of that kind")
    }

    // 端点：合规、有写法、有快照、快照的路径对得上
    checkEqual(
        Set(FalDialect.byEndpoint.keys), Set(FalModels.known.map { $0.endpoint.lowercased() }),
        "the dialect table and the registry list the same endpoints"
    )
    for model in FalModels.known {
        check(FalModels.isValidEndpoint(model.endpoint), "\(model.endpoint) is a valid endpoint id")
        check(FalDialect(endpoint: model.endpoint) != .generic, "\(model.endpoint) has its own dialect")
        check(!model.title.isEmpty, "\(model.endpoint) has a title")
        check((model.unitPrice ?? 0) > 0, "\(model.endpoint) has a registered price")
        if let schema = FalSchema(endpoint: model.endpoint) {
            checkEqual(schema.submitPath, "/" + model.endpoint, "the schema snapshot of \(model.endpoint) is for that endpoint")
            check(schema.input != nil && schema.output != nil, "the snapshot of \(model.endpoint) has an input and an output schema")
        } else {
            check(false, "no schema snapshot for \(model.endpoint) (scripts/fal-models/refresh.sh downloads it)")
        }
    }
    // 用户口径（2026-09-29）：视频只用 minimax/h3-max/ 这个系列。
    for model in FalModels.known where model.kind == .textToVideo || model.kind == .imageToVideo {
        check(model.endpoint.hasPrefix("minimax/h3-max/"), "video models come from the minimax/h3-max/ series: \(model.endpoint)")
    }

    // 端点号的写法
    for good in ["minimax/h3-max/text-to-video", "fal-ai/zonos2", "elevenlabs/music/v2.5", "a/b"] {
        check(FalModels.isValidEndpoint(good), "\(good) is valid")
    }
    for bad in ["", "zonos2", "/fal-ai/x", "fal-ai/x/", "fal-ai//../x", "fal ai/x", "fal-ai/中文", "https://fal.run/x/y"] {
        check(!FalModels.isValidEndpoint(bad), "\(bad) is not valid")
    }

    // 认端点：登记的 → 用户改成的 → 没登记
    let registered = FalModels.resolve(endpoint: "MINIMAX/h3-max/text-to-video", kind: .textToVideo)
    checkEqual(registered.unitPrice, 0.08, "an endpoint is recognised whatever its case")
    let custom = FalModel(kind: .image, endpoint: "acme/pix", title: "Pix", unitPrice: 0.5)
    checkEqual(FalModels.resolve(endpoint: "acme/pix", kind: .image, overrides: [.image: custom]).unitPrice, 0.5, "the user's own model keeps its price")
    let unknown = FalModels.resolve(endpoint: "acme/other", kind: .image, overrides: [.image: custom])
    check(unknown.unitPrice == nil, "an endpoint nobody registered has no price (so SrtFlow asks each time)")
    check(FalModels.resolve(endpoint: "fal-ai/zonos2", kind: .image).unitPrice == nil, "a registered endpoint asked for another kind is not trusted")
    checkEqual(FalModels.preset(for: .image, overrides: [.image: custom]).endpoint, "acme/pix", "the user's model wins over the default")

    // 估价的算术
    func estimate(_ endpoint: String, _ kind: FalModel.Kind, _ usage: FalUsage) -> Double? {
        FalModels.resolve(endpoint: endpoint, kind: kind).estimate(usage)
    }
    let h3 = "minimax/h3-max/text-to-video"
    checkClose(estimate(h3, .textToVideo, FalUsage(seconds: 5, tier: "768P")), 0.40, "5 s at 768p")
    checkClose(estimate(h3, .textToVideo, FalUsage(seconds: 15, tier: "1080P")), 2.40, "15 s at 1080p")
    checkClose(estimate(h3, .textToVideo, FalUsage(seconds: 10, tier: "480P")), 0.50, "10 s at 480p")
    checkClose(estimate(h3, .textToVideo, FalUsage(seconds: 5, tier: nil)), 0.40, "no tier falls back to the unit price")
    checkClose(estimate(h3, .textToVideo, FalUsage(seconds: 5, tier: "2K")), 0.40, "an unknown tier falls back to the unit price")
    checkClose(estimate("bytedance/seedream/v5/flash/text-to-image", .image, FalUsage(images: 1)), 0.027, "one image")
    checkClose(estimate("bytedance/seedream/v5/flash/text-to-image", .image, FalUsage(images: 0)), 0.027, "at least one image")
    checkClose(estimate("elevenlabs/tts/eleven-v4", .voice, FalUsage(characters: 500)), 0.04, "500 characters of voice")
    checkClose(estimate("elevenlabs/tts/eleven-v4", .voice, FalUsage(characters: 0)), 0, "nothing to say costs nothing")
    checkClose(estimate("elevenlabs/music/v2.5", .music, FalUsage(seconds: 30)), 0.6, "30 s of music is billed as a minute")
    checkClose(estimate("elevenlabs/music/v2.5", .music, FalUsage(seconds: 60)), 0.6, "exactly a minute of music")
    checkClose(estimate("elevenlabs/music/v2.5", .music, FalUsage(seconds: 61)), 1.2, "61 s of music is billed as two minutes")
    checkClose(estimate("sonilo/v1.1/text-to-sound-effects", .soundEffect, FalUsage(seconds: 5)), 0.009, "5 s of sound effect")
    checkClose(
        estimate("fal-ai/zonos2", .voiceClone, FalUsage(seconds: FalUsage.speechSeconds(characters: 300), characters: 300)), 0.02,
        "300 characters cloned: 75 s counts as two minutes"
    )
    check(estimate("acme/other", .image, FalUsage()) == nil, "no registered price, no estimate")
    checkClose(FalUsage.speechSeconds(characters: 1000), 250, "a thousand characters is estimated slowly (4 per second)")

    // 词表对账（小程序不链接 App 的类型，词表是抄的）
    checkEqual(MCPVocabulary.generationKinds, FalModel.Kind.allCases.filter(\.isGenerateKind).map(\.rawValue), "generation kinds match FalModel.Kind")
    checkEqual(MCPVocabulary.videoResolutions, FalInputs.videoResolutions.map { $0.lowercased() }, "video resolutions match FalInputs")
    checkEqual(MCPVocabulary.generationAspects, FalInputs.h3MaxTextAspects, "aspect ratios match H3 Max's")
    for kind in FalModel.Kind.allCases {
        check(kind.isGenerateKind == (kind != .voice && kind != .voiceClone), "\(kind): narration kinds are not generate kinds")
    }
    // 每个种类的计费单位跟登记表里写的一致（估价用它分派）
    for model in FalModels.known {
        switch model.kind {
        case .image: checkEqual(model.kind.unit, .image, "image is billed per image")
        case .imageToVideo, .textToVideo: checkEqual(model.kind.unit, .videoSecond, "video is billed per second")
        case .voice: checkEqual(model.kind.unit, .thousandCharacters, "voice is billed per 1000 characters")
        case .voiceClone, .music: checkEqual(model.kind.unit, .audioMinute, "clone and music are billed per minute")
        case .soundEffect: checkEqual(model.kind.unit, .audioSecond, "sound effects are billed per second")
        }
    }
    // 存进用户设置里的模型读得宽：缺的字段走默认
    let lenient = try? JSONDecoder().decode(FalModel.self, from: Data(#"{"kind":"music","endpoint":"acme/song"}"#.utf8))
    checkEqual(lenient?.title, "acme/song", "a saved model without a title falls back to its endpoint")
    check(lenient?.unitPrice == nil && lenient?.tierPrices.isEmpty == true, "a saved model without a price has none")
    let round = try? JSONDecoder().decode(FalModel.self, from: JSONEncoder().encode(FalModels.known[1]))
    checkEqual(round, FalModels.known[1], "a model survives a save / load round trip")
}
