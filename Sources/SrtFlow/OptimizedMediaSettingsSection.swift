import SwiftUI

// MARK: - 设置里的「优化媒体」一节
//
// 管什么：缓存占了多少、上限几档、「清空」按钮和按钮旁的一句话。**只订阅 `OptimizedMediaCacheSettings`**，不读工程
// （docs/architecture/preview-perf-ratchet.md 第十节：只有一个小视图关心的状态不放在工程上发）。
// 不管什么：算占用 / 清空 / 改上限本身（OptimizedMediaCacheSettings → OptimizedMediaStore）、预览工具条上的菜单
// （OptimizedMediaMenu）。
//
// 字节数按应用内的语言格式化（`\.locale` 由设置窗口根上的 `.appLanguage()` 注入）；十进制 GB，和访达一致。

struct OptimizedMediaSettingsSection: View {
    @ObservedObject private var settings = OptimizedMediaCacheSettings.shared
    @Environment(\.locale) private var locale

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        Section("Optimized Media") {
            Text("Videos with sparse keyframes are re-encoded in the background into a cache on this Mac, so clicks in the preview land at once. Exports always use the original files.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent {
                HStack(spacing: 6) {
                    Text(verbatim: usedText)
                        .monospacedDigit()
                    Button("Clear") { settings.clear() }
                        .disabled(settings.isClearing || settings.usedBytes == 0)
                        .instantHelp("Delete the cache. The preview uses the original files until the optimized media is prepared again")
                }
                .controlSize(.small)
            } label: {
                Text("Cache")
            }
            Picker(selection: Binding(get: { settings.capacityBytes }, set: { settings.setCapacity($0) })) {
                ForEach(presets, id: \.self) { bytes in
                    Text(verbatim: bytes.formatted(.byteCount(style: .file).locale(locale))).tag(bytes)
                }
            } label: {
                Text("Limit")
            }
            .controlSize(.small)
            .instantHelp("Past this size, the parts used least recently are deleted first. Parts unused for 30 days are deleted when SrtFlow starts")
            if let message = settings.message {
                Text(verbatim: message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            // 后台正在转的时候占用在变：这一节摆着就每隔几秒算一遍（关掉窗口 task 就取消）。
            while !Task.isCancelled {
                await settings.refresh()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    /// 几档，外加记住的那个值不在档上的情况（有人用 defaults 命令写过），不然 Picker 显示空白。
    private var presets: [Int64] {
        var all = OptimizedMediaStore.capacityPresets
        if !all.contains(settings.capacityBytes) {
            all.append(settings.capacityBytes)
            all.sort()
        }
        return all
    }

    private var usedText: String {
        guard let bytes = settings.usedBytes else { return "…" }
        return bytes.formatted(.byteCount(style: .file, spellsOutZero: false).locale(locale))
    }
}
