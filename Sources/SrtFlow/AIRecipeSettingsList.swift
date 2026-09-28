import AppKit
import SwiftUI

// MARK: - 设置 → AI 里的「剪辑套路」
//
// 管什么：列出用户自己的套路（含改过的内置那张），一行一个：名字、在访达中显示、删除（进废纸篓）；外加打开套路文件夹。
// 方案第 41 条：SrtFlow 里不做编辑界面 —— 想改就让 AI 改，或者用文本编辑器打开那个 .md。
// 不管什么：套路怎么读写（AIRecipeStore）、给 AI 的工具（AIRecipeTools）。

/// 设置页订阅的那一份用户套路。AI 存完一套由路由叫 `refresh`；设置页每次出现也刷一次（用户可能在访达里改过文件）。
@MainActor
final class AIRecipeLibrary: ObservableObject {
    static let shared = AIRecipeLibrary()

    @Published private(set) var userRecipes: [AIRecipe] = []
    private let store = AIRecipeStore.shared

    private init() { refresh() }

    func refresh() {
        let catalog = AIRecipeCatalog(builtIn: AIBuiltInRecipes.load(), user: store.userRecipes())
        let mine = catalog.recipes.filter { $0.source != .builtIn }
        if mine != userRecipes { userRecipes = mine }
    }

    func reveal(_ recipe: AIRecipe) {
        guard let url = store.fileURL(for: recipe) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func remove(_ recipe: AIRecipe) {
        try? store.remove(recipe)
        refresh()
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(store.directory)
    }
}

struct AIRecipesList: View {
    @ObservedObject private var library = AIRecipeLibrary.shared

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Editing recipes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Open Folder") { library.openFolder() }
                    .controlSize(.small)
                    .instantHelp("Show the folder with your own recipes in Finder")
            }
            if library.userRecipes.isEmpty {
                Text("When AI edits a whole video it follows one of SrtFlow's recipes (promo, cinematic opening, sci-fi, documentary, vlog). Ask it to save a style you like as your own recipe and it shows up here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(library.userRecipes, id: \.id) { recipe in
                    AIRecipeRow(recipe: recipe, library: library)
                }
            }
        }
        .onAppear { library.refresh() }
    }
}

private struct AIRecipeRow: View {
    let recipe: AIRecipe
    let library: AIRecipeLibrary

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        HStack(spacing: 6) {
            Text(verbatim: recipe.title)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
            if recipe.source == .customized {
                Text("Replaces the built-in one")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Show in Finder") { library.reveal(recipe) }
                .controlSize(.small)
                .instantHelp("Open this recipe's file in Finder; any text editor can change it")
            Button("Delete") { library.remove(recipe) }
                .controlSize(.small)
                .instantHelp("Move this recipe to the Trash")
        }
    }
}
