import SwiftUI

// MARK: - 预览工具条上的「优化媒体 / 原片」菜单 + 转码中的小进度
//
// 管什么：预览的画面用优化媒体（默认）还是原片，以及后台还有几块要转（小转圈）。**只订阅 `OptimizedMediaCoordinator`**，
// 不订阅工程（docs/architecture/preview-perf-ratchet.md 第十节：只有一个小视图关心的状态不放在工程上发）。
// 不管什么：转码本身、换源（OptimizedMediaCoordinator / CompositionClipInsert）。

struct OptimizedMediaMenu: View {
    @ObservedObject var coordinator: OptimizedMediaCoordinator

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        HStack(spacing: 4) {
            Menu {
                Button {
                    coordinator.setMode(.optimized)
                } label: {
                    if coordinator.mode == .optimized {
                        Label("Optimized media", systemImage: "checkmark")
                    } else {
                        Text("Optimized media")
                    }
                }
                Button {
                    coordinator.setMode(.original)
                } label: {
                    if coordinator.mode == .original {
                        Label("Original files", systemImage: "checkmark")
                    } else {
                        Text("Original files")
                    }
                }
            } label: {
                // **两个字面量各写在自己的分支里**（文案覆盖扫描器认不出三目里的字面量，见 VideoEditView 的同款注释）。
                Group {
                    if coordinator.mode == .optimized {
                        Label("Optimized", systemImage: "bolt.fill")
                    } else {
                        Label("Original file", systemImage: "film")
                    }
                }
                .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .instantHelp("Preview picture: optimized media (dense keyframes, so clicks while playing land at once) or the original files")

            if coordinator.pendingCount > 0 {
                ProgressView()
                    .controlSize(.mini)
                    .instantHelp("Preparing optimized media in the background — the preview uses the original files until each part is ready")
            }
        }
    }
}
