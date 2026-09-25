import SwiftUI

/// 检查器里「什么都没选」时的项目总览：总长、各轨的段数、输出尺寸、挂着的字幕文件。
///
/// 从 `VideoEditInspector.swift` 拆出来（2026-09-25：那个文件在超长基线里、行数只许降，给检查器
/// 换成「停着时的播放头」要加几行，就把这块最独立的顺手搬出来抵账）。它只读工程、不看播放头。
struct InspectorProjectOverview: View {
    @ObservedObject var project: VideoEditProject

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        Text("Project").font(.headline)

        VStack(alignment: .leading, spacing: 5) {
            summaryRow("Total length", MediaFormatting.duration(project.duration))
            summaryRow("Main track clips", "\(project.state.mainClips.count)")
            let overlayCount = project.state.overlayTracks.reduce(0) { $0 + $1.clips.count }
            if overlayCount > 0 {
                summaryRow("Upper track clips", "\(overlayCount)")
            }
            let audioCount = project.state.audioTracks.reduce(0) { $0 + $1.clips.count }
            if audioCount > 0 {
                summaryRow("Audio clips", "\(audioCount)")
            }
            if !project.state.shapes.isEmpty {
                summaryRow("Shapes", "\(project.state.shapes.count)")
            }
            if !project.state.textOverlays.isEmpty {
                summaryRow("Text", "\(project.state.textOverlays.count)")
            }
            summaryRow("Output size", "\(Int(project.renderSize.width))×\(Int(project.renderSize.height))")
        }

        Divider()

        VStack(alignment: .leading, spacing: 6) {
            Text("Subtitles").font(.callout).fontWeight(.medium)
            if let url = project.state.subtitleURL {
                HStack(spacing: 6) {
                    Image(systemName: "captions.bubble").foregroundStyle(.secondary)
                    Text(url.lastPathComponent)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        project.removeSubtitle()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .instantHelp("Unlink this subtitle file from the project")
                }
                Text("Burned in on export, using the style from the Burn In Subtitles tool.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Add a subtitle file to burn it into the exported video.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        Divider()

        // 这里曾经还有一个 Export… 按钮。删掉了（2026-08-12 用户）：
        // 窗口右上角的工具栏本来就有一个，同一个动作摆两遍只是占地方。
        // 多选那一段里的 Export… 留着 —— 那个说的是「只导出选中的这几段」，
        // 不是同一件事。
        Text("Select a clip on the timeline to adjust its speed, volume, and transition. Select a shape to recolor and resize it.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func summaryRow(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption).monospacedDigit()
        }
    }
}
