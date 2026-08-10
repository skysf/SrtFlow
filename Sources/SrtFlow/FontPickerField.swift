import SwiftUI
import SrtFlowCore

/// 选字体。
///
/// 原来是个普通的下拉菜单：几百个名字全用系统字体列出来，看不出那个字体长什么样，
/// 得选中、关掉菜单、等预览重渲染才知道。现在改成一个列表，**每个名字用它自己的
/// 字体画**，而且是一个真正的 List —— 上下方向键走一遍，左边的预览就跟着一句句变，
/// 不用点进点出。
struct FontPickerField: View {
    @Binding var fontName: String
    @ObservedObject var catalog: FontCatalogStore

    @State private var isPresented = false

    var body: some View {
        HStack {
            Text("Typeface")
            Spacer()
            Button {
                isPresented = true
            } label: {
                HStack(spacing: 6) {
                    // 按钮上也用该字体本身写它的名字。
                    Text(fontName)
                        .font(.custom(fontName, size: 13))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if catalog.font(named: fontName)?.supportsChinese == true {
                        ChineseBadge()
                    }
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
            }
            .instantHelp("Pick the typeface for burned-in subtitles")
            .popover(isPresented: $isPresented, arrowEdge: .trailing) {
                FontBrowser(fontName: $fontName, catalog: catalog)
            }
        }
    }
}

/// 弹出来的字体列表。选中就立刻生效，预览跟着变，不用确认。
private struct FontBrowser: View {
    @Binding var fontName: String
    @ObservedObject var catalog: FontCatalogStore

    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            if catalog.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
            Divider()
            Text("Arrow keys walk the list — the preview follows as you go.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        .frame(width: 330, height: 400)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
            TextField("Search fonts", text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .instantHelp("Clear the search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// 用 List 的选中态，方向键才能走 —— 走到哪儿就选到哪儿，预览立刻跟上。
    private var list: some View {
        List(selection: selection) {
            if !chinese.isEmpty {
                Section("Supports Chinese") {
                    ForEach(chinese) { font in
                        FontRow(font: font, isCurrent: font.familyName == fontName)
                            .tag(font.familyName)
                    }
                }
            }
            if !others.isEmpty {
                Section("Other fonts") {
                    ForEach(others) { font in
                        FontRow(font: font, isCurrent: font.familyName == fontName)
                            .tag(font.familyName)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private var selection: Binding<String?> {
        Binding(
            get: { fontName },
            set: { if let new = $0 { fontName = new } }
        )
    }

    private var matches: [SubtitleFont] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return catalog.fonts }
        return catalog.fonts.filter {
            $0.familyName.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var chinese: [SubtitleFont] { matches.filter(\.supportsChinese) }
    private var others: [SubtitleFont] { matches.filter { !$0.supportsChinese } }
}

private struct FontRow: View {
    let font: SubtitleFont
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 6) {
            // 名字用这个字体本身画出来，一眼就能看出粗细和字形。
            Text(font.familyName)
                .font(.custom(font.familyName, size: 15))
                .lineLimit(1)
                .truncationMode(.middle)
            if font.supportsChinese {
                ChineseBadge()
            }
            Spacer(minLength: 0)
            if isCurrent {
                Image(systemName: "checkmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 1)
    }
}

/// 含中文字形的标记。中文字幕挑错字体是最常见的坑，标出来省事。
private struct ChineseBadge: View {
    var body: some View {
        Text("中")
            .font(.caption2)
            .padding(.horizontal, 4)
            .padding(.vertical, 0.5)
            .background(.tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
    }
}
