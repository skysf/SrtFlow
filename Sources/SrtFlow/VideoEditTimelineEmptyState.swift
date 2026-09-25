import SwiftUI

// MARK: - 时间线的空状态
//
// 管什么：工程里一段素材都没有时，时间线那块「把素材拖进来开始创作」的虚线提示。
// 不管什么：拖入本身（`VideoEditView` 整页的 `.onDropOfFiles`）。
// 从 `VideoEditTimelineView.swift` 拆出来（那个文件超过 600 行、只许降）。

struct TimelineEmptyState: View {
    var body: some View {
        let _ = PerfCounters.body(Self.self)
        VStack {
            Spacer()
            HStack(spacing: 10) {
                Image(systemName: "film")
                    .foregroundStyle(.secondary)
                Text("Drag material here and start to create")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .foregroundStyle(.quaternary)
            )
            .padding(.horizontal, 24)
            Spacer()
        }
    }
}
