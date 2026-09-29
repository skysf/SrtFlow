import Foundation

// MARK: - 剪辑风格：从哪读、往哪写
//
// 管什么：内置的五张从 App 资源里读（recipe-*.md，外加所有剪辑风格共用的那段规矩 recipes-shared-rules.md）；用户的存在
// `~/Library/Application Support/SrtFlow/Recipes/`，一套一个 .md（方案第 41 条：测试版和正式版共用，同音乐库缓存）。
// 存一套（`save`）：同名 = 改这一套，旧的那份先挪走（默认进废纸篓，找得回来）再写新的；和内置的同名 = 用户改过的
// 那一版（同一个 id）。删一套也是进废纸篓。设置 → AI 里的列表订阅 `AIRecipeLibrary`。
// 不管什么：卡的格式和合并规则（AIRecipe / AIRecipeCatalog）、给 AI 的工具（AIRecipeTools）。

struct AIRecipeStore: Sendable {
    /// 用户的剪辑风格放在这里。
    let directory: URL
    /// 旧版本怎么挪走：App 里进废纸篓；自检换成挪进一个临时文件夹，不去碰真的废纸篓。
    var retire: @Sendable (URL) throws -> URL? = { url in
        var trashed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        return trashed as URL?
    }

    static var userDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SrtFlow/Recipes", isDirectory: true)
    }

    static let shared = AIRecipeStore(directory: userDirectory)

    // MARK: 读

    /// 用户的剪辑风格（文件夹里每个 .md；读不了、正文空的跳过）。
    func userRecipes() -> [AIRecipe] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return AIRecipe.parse(text, fileName: url.lastPathComponent, source: .user)
            }
    }

    /// 这一套在硬盘上的文件（只有用户的有）。
    func fileURL(for recipe: AIRecipe) -> URL? {
        guard recipe.source != .builtIn else { return nil }
        return userRecipeFiles()[recipe.id]
    }

    /// id → 文件（按文件里写的 id 认，不按文件名猜：用户手改过文件名也找得到）。
    private func userRecipeFiles() -> [String: URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var result: [String: URL] = [:]
        for url in files where url.pathExtension.lowercased() == "md" {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let recipe = AIRecipe.parse(text, fileName: url.lastPathComponent, source: .user),
                  result[recipe.id] == nil else { continue }
            result[recipe.id] = url
        }
        return result
    }

    // MARK: 写

    struct SaveResult: Equatable {
        var recipe: AIRecipe
        var file: URL
        /// 原来那一份挪到了哪（改的是已有的一套时）。
        var previousVersion: URL?
    }

    /// 存一套。`catalog` 是存之前的全部剪辑风格：名字撞上用户的就改那一套、撞上内置的就成了用户改过的那一版。
    func save(name: String, useFor: String, body: String, catalog: AIRecipeCatalog) throws -> SaveResult {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty else { throw AIToolError("text is empty: write the whole recipe.") }
        let existing = catalog.find(name)
        guard let id = existing?.id ?? AIRecipe.slug(name) else {
            throw AIToolError("name needs at least one letter or digit.")
        }
        let recipe = AIRecipe(
            id: id, title: name.trimmingCharacters(in: .whitespaces), useFor: useFor, body: trimmedBody,
            source: existing?.source == .builtIn || existing?.source == .customized ? .customized : .user
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var previous: URL?
        let file: URL
        if let old = userRecipeFiles()[id] {
            previous = try retire(old)
            file = old
        } else {
            file = directory.appendingPathComponent(id).appendingPathExtension("md")
        }
        try Data(recipe.fileText.utf8).write(to: file, options: .atomic)
        return SaveResult(recipe: recipe, file: file, previousVersion: previous)
    }

    /// 删一套用户的（进废纸篓）。内置的删不了。
    func remove(_ recipe: AIRecipe) throws {
        guard let file = fileURL(for: recipe) else { return }
        _ = try retire(file)
    }
}

// MARK: - 内置的五张

enum AIBuiltInRecipes {
    /// App 资源里的 recipe-*.md。打包后资源摊平在 Contents/Resources（scripts/build-app.sh）；`swift run` 的时候在
    /// 可执行文件旁边的 SrtFlow_SrtFlow.bundle 里。**不用 `Bundle.module`**：打好的 App 里没有那个 bundle，它会直接崩。
    static func load(from directories: [URL] = resourceDirectories) -> [AIRecipe] {
        for directory in directories {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            let recipes = files
                .filter { $0.lastPathComponent.hasPrefix("recipe-") && $0.pathExtension == "md" }
                .compactMap { url -> AIRecipe? in
                    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                    return AIRecipe.parse(text, fileName: url.lastPathComponent, source: .builtIn)
                }
            if !recipes.isEmpty { return recipes }
        }
        return []
    }

    /// 所有剪辑风格共用的那段规矩（读一套全文时接在后面）。
    static func sharedRules(from directories: [URL] = resourceDirectories) -> String {
        for directory in directories {
            let url = directory.appendingPathComponent("recipes-shared-rules.md")
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return ""
    }

    static var resourceDirectories: [URL] {
        var result: [URL] = []
        if let resources = Bundle.main.resourceURL { result.append(resources) }
        result.append(Bundle.main.bundleURL.appendingPathComponent("SrtFlow_SrtFlow.bundle", isDirectory: true))
        result.append(Bundle.main.bundleURL.appendingPathComponent("SrtFlow_SrtFlow.bundle/Contents/Resources", isDirectory: true))
        return result
    }
}
