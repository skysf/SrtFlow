import CoreText
import Foundation
import SwiftUI

// MARK: - 文字可用的字体
//
// **和字幕的 `FontCatalog` 是两份，故意的。**
//
// 字幕那份只收「文件可读 + CoreText 能解析」的字体，因为烧字幕要把字体文件
// 软链进任务目录喂给 libass；macOS 的苹方等系统中文字体放在普通进程读不了的
// 目录里，libass 打不开会悄悄换字体，所以必须先筛掉。
//
// 文字这边**没有这个约束** —— 渲染全程走 Core Text，字体由系统字体服务提供，
// 读不读得到文件根本无所谓。用字幕那份表的话，苹方这种最常用的中文字体会
// 从列表里消失，而它明明画得出来。

struct TextFontFamily: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var supportsChinese: Bool
}

@MainActor
final class TextFontCatalogStore: ObservableObject {
    @Published private(set) var families: [TextFontFamily] = []
    @Published private(set) var isLoading = true

    static let shared = TextFontCatalogStore()

    private init() {}

    func loadIfNeeded() {
        guard isLoading, families.isEmpty else { return }
        Task {
            let scanned = await Task.detached(priority: .userInitiated) { TextFontCatalogStore.scan() }.value
            self.families = scanned
            self.isLoading = false
        }
    }

    var chineseCapable: [TextFontFamily] { families.filter(\.supportsChinese) }
    var others: [TextFontFamily] { families.filter { !$0.supportsChinese } }

    /// 用这几个字判断字体有没有中文字形（与字幕那边同一把探针）。
    private static let chineseProbe = CharacterSet(charactersIn: "中文字幕测试的一二三")

    nonisolated private static func scan() -> [TextFontFamily] {
        let names = (CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? []
        return names
            // 以点开头的是系统内部字体（.LastResort 之类），不该出现在列表里。
            .filter { !$0.hasPrefix(".") && !$0.isEmpty }
            .map { name in
                let font = CTFontCreateWithName(name as CFString, 24, nil)
                let characters = CTFontCopyCharacterSet(font) as CharacterSet
                return TextFontFamily(
                    name: name,
                    supportsChinese: characters.isSuperset(of: chineseProbe)
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// 字体选择器：按钮 + 带搜索的浮层。中文字体单独一组排在前面 ——
/// 做中文标题时在三百个字体里翻找中文的那几个是很痛苦的事。
struct TextFontPicker: View {
    @Binding var fontName: String
    @ObservedObject var catalog: TextFontCatalogStore

    @State private var isPresented = false
    @State private var query = ""

    var body: some View {
        HStack {
            Text("Typeface").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button {
                isPresented = true
            } label: {
                HStack(spacing: 6) {
                    // 按钮上用该字体本身写它的名字。
                    Text(fontName)
                        .font(.custom(fontName, size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
            }
            .instantHelp("Pick the typeface for this text")
            .popover(isPresented: $isPresented, arrowEdge: .leading) {
                browser.appLanguage()
            }
        }
        .onAppear { catalog.loadIfNeeded() }
    }

    private var browser: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
            if catalog.isLoading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    section("Chinese", families: filtered(catalog.chineseCapable))
                    section("Other", families: filtered(catalog.others))
                }
            }
            .frame(width: 240, height: 300)
        }
        .padding(10)
    }

    private func filtered(_ families: [TextFontFamily]) -> [TextFontFamily] {
        guard !query.isEmpty else { return families }
        return families.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, families: [TextFontFamily]) -> some View {
        if !families.isEmpty {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 6)
            ForEach(families) { family in
                Button {
                    fontName = family.name
                    isPresented = false
                } label: {
                    HStack {
                        Text(family.name)
                            .font(.custom(family.name, size: 13))
                            .lineLimit(1)
                        Spacer()
                        if family.name == fontName {
                            Image(systemName: "checkmark").font(.caption2)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 2)
            }
        }
    }
}
