import Foundation
import SrtFlowMCPKit

// 剪辑风格（方案第 39–41 条）：配方卡的格式（开头几行 key: value，缺了照收）、名字 → id、内置和用户的合并（同 id 盖住内置、
// 内置在前按固定顺序）、按 id / 标题找；存一套（同名改那一套、旧的挪走；内置的名字 = 用户改过的那一版）、删一套；
// recipes / save_recipe 的结果；以及 App 资源里的五张内置卡：id 齐全、每张都有「什么时候用」，**卡里提到的工具名、参数名、
// 选项值都真的存在**（工具改了名、卡没跟着改，AI 照着卡调就会报错）。编法见 scripts/check-mcp.sh。

func runRecipeChecks() {
    runRecipeSizeChecks()
    formatChecks()
    catalogChecks()
    storeChecks()
    builtInChecks()
}

private func formatChecks() {
    let text = "---\nid: course-promo\ntitle: 课程推广\nuse_for: Selling my course.\n---\n# Course promo\n\nHook first.\n"
    let recipe = AIRecipe.parse(text, fileName: "whatever.md", source: .user)
    checkEqual(recipe?.id, "course-promo", "the id comes from the header")
    checkEqual(recipe?.title, "课程推广", "the title comes from the header")
    checkEqual(recipe?.useFor, "Selling my course.", "use_for is read")
    checkEqual(recipe?.body, "# Course promo\n\nHook first.", "the body is what follows the header")
    if let recipe {
        checkEqual(AIRecipe.parse(recipe.fileText, fileName: "x.md", source: .user), recipe, "fileText reads back the same")
    }
    let bare = AIRecipe.parse("# My Style\nCut fast.", fileName: "my style.md", source: .user)
    checkEqual(bare?.id, "my-style", "without a header the id comes from the file name")
    checkEqual(bare?.title, "My Style", "without a header the title is the first heading")
    check(AIRecipe.parse("---\nid: x\n---\n  \n", fileName: "x.md", source: .user) == nil, "a recipe with no text is not a recipe")
    var multiLine = AIRecipe(id: "a", title: "A\nB", useFor: "one\ntwo", body: "x", source: .user)
    multiLine = AIRecipe.parse(multiLine.fileText, fileName: "a.md", source: .user) ?? multiLine
    checkEqual(multiLine.useFor, "one two", "use_for is written on one line")
    checkEqual(AIRecipe.slug("Course Promo!"), "course-promo", "slug: lower case, spaces to dashes, symbols dropped")
    checkEqual(AIRecipe.slug("课程推广"), "课程推广", "slug keeps Chinese")
    checkEqual(AIRecipe.slug("a/b:c"), "abc", "slug drops characters a file name cannot have")
    check(AIRecipe.slug("  !! ") == nil, "a name with nothing usable has no slug")
}

private func recipe(_ id: String, _ title: String, _ source: AIRecipe.Source) -> AIRecipe {
    AIRecipe(id: id, title: title, useFor: "when \(id)", body: "body of \(id)", source: source)
}

private func catalogChecks() {
    let builtIn = [recipe("documentary", "Documentary", .builtIn), recipe("product-promo", "Product or course promo", .builtIn)]
    let user = [recipe("zoo", "Zoo style", .user), recipe("documentary", "My documentary", .user), recipe("apple", "Apple style", .user)]
    let catalog = AIRecipeCatalog(builtIn: builtIn, user: user)
    checkEqual(catalog.recipes.map(\.id), ["product-promo", "documentary", "apple", "zoo"],
               "built-in recipes first in the fixed order, then the user's by title")
    checkEqual(catalog.recipes[1].source, .customized, "a user recipe with a built-in id replaces it")
    checkEqual(catalog.recipes[1].title, "My documentary", "the user's version is the one listed")
    checkEqual(catalog.find("PRODUCT OR COURSE PROMO")?.id, "product-promo", "find by title ignores case")
    checkEqual(catalog.find("Zoo Style")?.id, "zoo", "find by title")
    checkEqual(catalog.find("product-promo")?.id, "product-promo", "find by id")
    check(catalog.find("nope") == nil, "unknown names are not found")
}

private func storeChecks() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("srtflow-recipes-\(UUID().uuidString)")
    let trash = root.appendingPathComponent("trash", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try? FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    var store = AIRecipeStore(directory: root.appendingPathComponent("Recipes", isDirectory: true))
    store.retire = { url in
        let target = trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }
    let builtIn = [recipe("product-promo", "Product or course promo", .builtIn)]
    func catalog() -> AIRecipeCatalog { AIRecipeCatalog(builtIn: builtIn, user: store.userRecipes()) }

    let first = try? store.save(name: "Course promo", useFor: "My course.", body: "v1", catalog: catalog())
    checkEqual(first?.recipe.id, "course-promo", "a new recipe gets an id from its name")
    checkEqual(first?.file.lastPathComponent, "course-promo.md", "one .md per recipe, named after the id")
    check(first?.previousVersion == nil, "nothing is moved away for a new recipe")
    let second = try? store.save(name: "course promo", useFor: "My course, v2.", body: "v2", catalog: catalog())
    check(second?.previousVersion != nil, "saving under the same name moves the old version away first")
    checkEqual(store.userRecipes().map(\.body), ["v2"], "the same name replaces the recipe")
    let custom = try? store.save(name: "Product or course promo", useFor: "Mine.", body: "my promo", catalog: catalog())
    checkEqual(custom?.recipe.id, "product-promo", "a built-in's name makes the user's version of it")
    checkEqual(catalog().find("product-promo")?.source, .customized, "and it replaces the built-in in the list")
    checkThrows("an empty text is refused") { _ = try store.save(name: "x", useFor: "y", body: "  ", catalog: catalog()) }
    checkThrows("a name without letters is refused") { _ = try store.save(name: "!!", useFor: "y", body: "z", catalog: catalog()) }
    if let mine = catalog().find("product-promo") {
        try? store.remove(mine)
        checkEqual(catalog().find("product-promo")?.source, .builtIn, "deleting the user's version brings the built-in back")
    }

    // 工具：列表带 id、标题、什么时候用、来源；全文后面接上共用的规矩；找不到时说出有哪些。
    let list = try? AIRecipeTools.recipes(args([:]), store: store, builtIn: builtIn, sharedRules: "SHARED")
    checkEqual(list?.payload["recipes"]?.arrayValue?.compactMap { $0["id"]?.stringValue }, ["product-promo", "course-promo"],
               "recipes lists every recipe")
    checkEqual(list?.payload["recipes"]?.arrayValue?.last?["source"]?.stringValue, "yours", "the source is shown")
    let full = try? AIRecipeTools.recipes(args(["id": "Course promo"]), store: store, builtIn: builtIn, sharedRules: "SHARED")
    checkEqual(full?.payload["text"]?.stringValue, "v2\n\nSHARED", "the full recipe ends with the shared rules")
    checkThrows("an unknown recipe is refused") {
        _ = try AIRecipeTools.recipes(args(["id": "nope"]), store: store, builtIn: builtIn, sharedRules: "")
    }
    checkThrows("save_recipe needs use_for") {
        _ = try AIRecipeTools.save(args(["name": "a", "text": "b"]), store: store, builtIn: builtIn)
    }
}

/// App 资源里的内置卡（自检从仓库根目录跑，直接读 Sources/SrtFlow/Resources）。
private func builtInChecks() {
    let resources = URL(fileURLWithPath: "Sources/SrtFlow/Resources", isDirectory: true)
    let builtIn = AIBuiltInRecipes.load(from: [resources])
    checkEqual(builtIn.map(\.id).sorted(), AIRecipeCatalog.builtInOrder.sorted(), "the five built-in recipes are in the app")
    for recipe in builtIn {
        check(!recipe.useFor.isEmpty && !recipe.title.isEmpty, "\(recipe.id) says when to use it and has a title")
    }
    let shared = AIBuiltInRecipes.sharedRules(from: [resources])
    check(shared.contains("Rules for every recipe"), "the shared rules are in the app")
    let known = knownNames()
    for (name, text) in builtIn.map({ ($0.id, $0.body) }) + [("shared rules", shared)] {
        let unknown = identifiers(in: text).filter { !known.contains($0) }
        check(unknown.isEmpty, "\(name) mentions names SrtFlow's tools do not have: \(unknown.sorted())")
    }
    // generate_media 只有填了 fal Key 才在工具清单里，卡却一直读得到：提到它的地方必须是条件句（2026-09-29 用户拍板）。
    check(shared.contains("If generate_media is among your tools"), "the shared rules teach generate_media as a conditional")
    check(shared.contains("waiting_for_user") && shared.contains("estimated_cost_usd") && shared.contains("480p"),
          "the shared rules cover the banner question, the estimate and 480p drafts")
    for recipe in builtIn where recipe.body.contains("generate_media") {
        check(recipe.body.contains("only if generate_media is among your tools"),
              "\(recipe.id) mentions generate_media only under the condition that it exists")
    }
    check(builtIn.allSatisfy { $0.body.contains("generate_media") }, "every card says what generate_media may add for its style")
}

/// 工具名、所有参数名（整份工具清单里的 properties）、选项词表里的值，外加 AI 能在结果里读到的几个字段名。
private func knownNames() -> Set<String> {
    var names = Set(MCPToolName.allCases.map(\.rawValue))
    func walk(_ value: JSONValue) {
        switch value {
        case .object(let object):
            if case .object(let properties)? = object["properties"] { names.formUnion(properties.keys) }
            object.values.forEach(walk)
        case .array(let items):
            items.forEach(walk)
        default:
            break
        }
    }
    walk(MCPToolName.listJSON)
    names.formUnion(MCPVocabulary.transitions + MCPVocabulary.filterPresetIDs + MCPVocabulary.textAnimations
        + MCPVocabulary.clipAnimations + MCPVocabulary.soundScenes + MCPVocabulary.textEmphasis
        + MCPVocabulary.numberStyles + MCPVocabulary.voiceRoles + MCPVocabulary.textPositions + MCPVocabulary.subtitlePositions)
    names.insert("music_credits")  // get_timeline 的结果里的字段
    names.insert("lines_with_word_times")  // get_subtitles 的结果里的字段
    // generate_media（只有填了 fal Key 才在清单里，但 listJSON 是配好时的全份）的词表和结果字段：卡里提到它们时要对得上。
    names.formUnion(MCPVocabulary.generationKinds + MCPVocabulary.videoResolutions + MCPVocabulary.generationAspects)
    names.formUnion(["estimated_cost_usd", "cost_usd", "waiting_for_user", "job_id"])
    return names
}

/// 看起来像工具名 / 参数名（snake_case）或者选项值（camelCase，如 pushLeft、coldWhite）的词。
/// camelCase 两头都要至少两个小写字母：「15 dB」的 dB 不算。
private func identifiers(in text: String) -> Set<String> {
    let pattern = #"\b(?:[a-z][a-z0-9]*(?:_[a-z0-9]+)+|[a-z]{2,}[A-Z][a-z]+[A-Za-z]*)\b"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    return Set(regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } })
}
