import AppKit
import SwiftUI

// 音乐来源与署名。
//
// **这不是装饰，是 CC-BY 的强制义务**：库里每一首都要求署名，没有这个页面
// 那批素材一首都不能用（产品口径见 docs/plans/2026-09-22-audio-library.md 第十节）。
//
// 署名句由 manifest 的 `license.text` 给出（来自素材源站的现成句子），App 这边
// 只负责显示和让人能拷走 —— 自己拼句子会在换音源时悄悄写错。
//
// **当前工程用到的排在最前面并标出来**：用户真正要履行义务的是这几条，
// 让他在一百条里自己找是把合规变成负担。

struct AudioLibraryCreditsView: View {
    let items: [AudioLibraryItem]
    /// 当前工程里用到的素材 id。
    let usedIDs: Set<String>
    @Environment(\.dismiss) private var dismiss

    private var sorted: [AudioLibraryItem] {
        items.sorted {
            (usedIDs.contains($0.id) ? 0 : 1, $0.artist, $0.title)
                < (usedIDs.contains($1.id) ? 0 : 1, $1.artist, $1.title)
        }
    }

    private var usedItems: [AudioLibraryItem] { sorted.filter { usedIDs.contains($0.id) } }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sorted) { item in
                        row(item)
                        Divider()
                    }
                }
            }
            Divider()
            footer
        }
        .frame(width: 520, height: 420)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Music credits").font(.headline)
            Text("Every track below is licensed under Creative Commons Attribution. If you publish a video that uses one, credit it as shown.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
    }

    private func row(_ item: AudioLibraryItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if usedIDs.contains(item.id) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .font(.caption)
                    .instantHelp("Used in this project")
            }
            VStack(alignment: .leading, spacing: 2) {
                // 署名句原样显示：它来自素材源站，改一个字都可能不再满足条款。
                Text(verbatim: item.license.text)
                    .font(.caption)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(verbatim: item.license.code)
                    if let src = item.license.src {
                        Link(destination: src) { Text(verbatim: src.host ?? "source") }
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var footer: some View {
        HStack {
            // 拷的是**用到的那些**（没用到的抄进片尾字幕反而是错的）；一首都没用
            // 时退回全部，因为那时用户多半是想先看看要写什么。
            Button("Copy credits") {
                let lines = (usedItems.isEmpty ? sorted : usedItems)
                    .map { "\($0.license.text) — \($0.license.code)" }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
            }
            .instantHelp("Copy the credit lines for the tracks used in this project")
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }
}
