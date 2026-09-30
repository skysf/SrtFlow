import Foundation

// MARK: - 工具清单：剪辑风格
//
// 管什么：recipes（只读：列出每套和「什么时候用」、按名字回全文）和 save_recipe（写：存用户自己的一套）的说明文字和参数。
// 两个挨着的用途按第 33 条拆成一个只读、一个会写，说明里写清彼此的区别。
// 不管什么：剪辑风格的内容（App 资源里的 recipe-*.md）、怎么读写（App 里的 AIRecipeTools / AIRecipeStore）。
// 产品决定见 docs/plans/2026-09-27-mcp.md 第 39–41 条：剪辑风格由 AI 自己挑，不做斜杠命令。

enum MCPRecipeTools {
    static func definition(for name: MCPToolName) -> MCPToolDefinition {
        switch name {
        case .recipes:
            return MCPToolDefinition(
                .recipes, title: "Read editing styles",
                description: """
                SrtFlow's editing styles: how to cut a whole video in a style — structure by the second, shot lengths, \
                transitions, filters, fonts, music, voice and a checklist. Without id: every style with when to use it \
                (preset: product or course promo, cinematic opening, sci-fi, documentary, daily vlog; the user may have \
                their own). With id: the whole style. Before editing a whole video from the user's footage, pick the one \
                that fits their goal, tell them in one sentence which one you follow, and follow it; what the user says \
                always wins over the style. If they want a style again later, offer save_recipe. Call them editing \
                styles when talking to the user (the built-in ones are preset styles).
                """,
                input: MCPSchema.object([
                    "id": MCPSchema.string("A style's id or title; leave out to list them all.")
                ]),
                readOnly: true
            )
        case .saveRecipe:
            return MCPToolDefinition(
                .saveRecipe, title: "Save an editing style",
                description: """
                Save an editing style of the user's own, only when they ask (e.g. "save this as a style"). text is the \
                whole style in Markdown, written like the preset ones (read one with recipes first). The name of one of \
                their styles replaces it (the old file goes to the Trash); a preset style's name makes their own version \
                of it. Styles live in SrtFlow's own folder (Settings → AI lists them), not in the project folder.
                """,
                input: MCPSchema.object([
                    "name": MCPSchema.string("The style's name, e.g. \"Course promo\"."),
                    "use_for": MCPSchema.string("One sentence: when to use this style."),
                    "text": MCPSchema.string("The whole style in Markdown.")
                ], required: ["name", "use_for", "text"]),
                destructive: true
            )
        default:
            preconditionFailure("\(name) is not a recipe tool")
        }
    }
}
