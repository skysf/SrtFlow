import Foundation
import SrtFlowMCPKit

// MARK: - 工具：剪辑套路（recipes 只读、save_recipe 写）
//
// 管什么：`recipes` 列出全部套路（每套一句「什么时候用」）、按名字回全文（后面接上所有套路共用的规矩）；
// `save_recipe` 存用户自己的一套（用户开口才存；同名改那一套、旧的进废纸篓；和内置同名 = 用户改过的那一版）。
// 套路由 AI 自己挑（方案第 39 条），总说明里写着「剪整片之前先挑一套、一句话告诉用户」。
// 不管什么：卡的格式和合并（AIRecipe）、读写文件（AIRecipeStore）、设置里的列表（AIRecipeSettingsList，存完由路由叫它刷新）。

enum AIRecipeTools {
    // MARK: recipes

    static func recipes(_ args: AIToolArguments, store: AIRecipeStore = .shared,
                        builtIn: [AIRecipe] = AIBuiltInRecipes.load(), sharedRules: String = AIBuiltInRecipes.sharedRules()) throws -> AIToolResult {
        let catalog = AIRecipeCatalog(builtIn: builtIn, user: store.userRecipes())
        guard let name = try args.string("id"), !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .ok([
                "recipes": .array(catalog.recipes.map { recipe in
                    [
                        "id": .string(recipe.id),
                        "title": .string(recipe.title),
                        "use_for": .string(recipe.useFor),
                        "source": .string(recipe.source.rawValue)
                    ]
                }),
                "folder": .string((store.directory.path as NSString).abbreviatingWithTildeInPath),
                "next_step": """
                Pick the recipe that fits what the user wants, tell the user in one sentence which one you follow, then read it \
                with recipes {id}. The user's own words always win over the recipe.
                """
            ])
        }
        guard let recipe = catalog.find(name) else {
            let ids = catalog.recipes.map(\.id).joined(separator: ", ")
            throw AIToolError("There is no recipe called \(name). Recipes: \(ids).")
        }
        var text = recipe.body
        if !sharedRules.isEmpty { text += "\n\n" + sharedRules }
        return .ok([
            "id": .string(recipe.id),
            "title": .string(recipe.title),
            "use_for": .string(recipe.useFor),
            "source": .string(recipe.source.rawValue),
            "text": .string(text)
        ])
    }

    // MARK: save_recipe

    static func save(_ args: AIToolArguments, store: AIRecipeStore = .shared,
                     builtIn: [AIRecipe] = AIBuiltInRecipes.load()) throws -> AIToolResult {
        let name = try args.requiredString("name")
        let useFor = try args.requiredString("use_for")
        let text = try args.requiredString("text")
        let catalog = AIRecipeCatalog(builtIn: builtIn, user: store.userRecipes())
        let saved = try store.save(name: name, useFor: useFor, body: text, catalog: catalog)
        var result: [String: JSONValue] = [
            "saved": .string(saved.recipe.id),
            "title": .string(saved.recipe.title),
            "file": .string((saved.file.path as NSString).abbreviatingWithTildeInPath)
        ]
        if saved.recipe.source == .customized { result["replaces_built_in"] = .string(saved.recipe.id) }
        if let previous = saved.previousVersion {
            result["previous_version"] = .string("moved to the Trash: \((previous.path as NSString).abbreviatingWithTildeInPath)")
        }
        return .ok(.object(result))
    }
}
