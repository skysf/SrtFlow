import Foundation

// MARK: - 工具清单：剪辑套路
//
// 管什么：recipes（只读：列出每套和「什么时候用」、按名字回全文）和 save_recipe（写：存用户自己的一套）的说明文字和参数。
// 两个挨着的用途按第 33 条拆成一个只读、一个会写，说明里写清彼此的区别。
// 不管什么：套路的内容（App 资源里的 recipe-*.md）、怎么读写（App 里的 AIRecipeTools / AIRecipeStore）。
// 产品决定见 docs/plans/2026-09-27-mcp.md 第 39–41 条：套路由 AI 自己挑，不做斜杠命令。

enum MCPRecipeTools {
    static func definition(for name: MCPToolName) -> MCPToolDefinition {
        switch name {
        case .recipes:
            return MCPToolDefinition(
                .recipes, title: "Read editing recipes",
                description: """
                SrtFlow's editing recipes: how to cut a whole video in a style — structure by the second, shot lengths, \
                transitions, filters, fonts, music, voice and a checklist. Without id: every recipe with when to use it \
                (built in: product or course promo, cinematic opening, sci-fi, documentary, daily vlog; the user may have \
                their own). With id: the whole recipe. Before editing a whole video from the user's footage, pick the one \
                that fits their goal, tell them in one sentence which one you follow, and follow it; what the user says \
                always wins over the recipe.
                """,
                input: MCPSchema.object([
                    "id": MCPSchema.string("A recipe's id or title; leave out to list them all.")
                ]),
                readOnly: true
            )
        case .saveRecipe:
            return MCPToolDefinition(
                .saveRecipe, title: "Save a recipe",
                description: """
                Save an editing recipe of the user's own, only when they ask (e.g. "save this as a recipe"). text is the \
                whole recipe in Markdown, written like the built-in ones (read one with recipes first). The name of one of \
                their recipes replaces it (the old file goes to the Trash); a built-in recipe's name makes their own version \
                of it. Recipes live in SrtFlow's Recipes folder (Settings → AI lists them), not in the project folder.
                """,
                input: MCPSchema.object([
                    "name": MCPSchema.string("The recipe's name, e.g. \"Course promo\"."),
                    "use_for": MCPSchema.string("One sentence: when to use this recipe."),
                    "text": MCPSchema.string("The whole recipe in Markdown.")
                ], required: ["name", "use_for", "text"]),
                destructive: true
            )
        default:
            preconditionFailure("\(name) is not a recipe tool")
        }
    }
}
