import SwiftUI
import SrtFlowCore

// MARK: - 字幕表表头的「样子」那一行：逐词高亮、工程自己的样式
//
// 管什么：逐词高亮的开关和颜色（`TimelineState.subtitleHighlight`，方案第 38 条），以及这个工程有自己的字幕样式
// （AI 改过，方案第 54 条）时说一声、给一个「用烧录页的样式」。一次改动一步撤销
// （`setSubtitleHighlight` / `useAppWideSubtitleStyle`，VideoEditProjectSubtitleLink.swift）。
// 不管什么：样式在哪儿编（全 App 的在烧录页，工程自己的只有 AI 改）、字怎么画（BurnInSubtitleOverlay）。
// 放大多少只有 AI 改（edit_subtitles 的 style），这里新打开时用默认的 1.1 倍。

struct VideoEditSubtitleLookRow: View {
    let project: VideoEditProject

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        let highlight = project.state.subtitleHighlight
        // 只有 SrtFlow 自己生成的字幕（转写、配音）知道每个词什么时候说；一句都没有时打开了也不会亮。
        let knowsWordTimes = project.state.allSubtitleCues.contains { $0.words != nil }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Toggle(isOn: Binding(
                    get: { highlight != nil },
                    set: { project.setSubtitleHighlight($0 ? SubtitleWordHighlight() : nil) }
                )) {
                    Text("Highlight each word")
                        .font(.caption)
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .disabled(highlight == nil && !knowsWordTimes)
                .instantHelp("The word being spoken changes colour, in the preview and in the exported video. Only subtitles SrtFlow made (from speech or a voiceover) know when each word is said")
                if let highlight {
                    ColorPicker("", selection: Binding(
                        get: { highlight.color.swiftUIColor },
                        set: { project.setSubtitleHighlight(SubtitleWordHighlight(color: SubtitleColor($0), scale: highlight.scale)) }
                    ), supportsOpacity: false)
                    .labelsHidden()
                    .controlSize(.small)
                    .instantHelp("Colour of the word being spoken")
                }
                Spacer(minLength: 4)
            }
            if project.state.projectSubtitleStyle != nil {
                HStack(spacing: 6) {
                    Text("This project has its own subtitle style.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Use Burn In style", action: project.useAppWideSubtitleStyle)
                        .controlSize(.small)
                        .instantHelp("Use the subtitle style from the Burn In Subtitles page again")
                }
            }
        }
    }
}
