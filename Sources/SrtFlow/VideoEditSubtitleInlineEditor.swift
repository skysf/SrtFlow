import SwiftUI
import SrtFlowCore

/// 就地编辑一句字幕的文字：时间线上双击 cue 块（浮层）与预览里双击字幕
/// （画面上的输入框）共用这一个视图 —— **两个入口，一套提交规则**。
///
/// 只编被双击的那一句（2026-09-26 起原文、译文是两条独立的轨，不再一一对应，
/// 「一个浮层两格」说不清第二格是哪一句 —— 计划 S13）。
///
/// 草稿与提交规则都不在这里：文本挂在工程上的 `SubtitleTextDraft`
/// （见 `VideoEditSubtitleDraft.swift`），写入走 `VideoEditProjectSubtitleLink`
/// 的合同入口。这样一来：
/// - 保存 / 切工程 / 退出能在读模型之前同步落定，不依赖失焦回调的时机；
/// - CAS 基线在**进入这一格时**冻结，父视图重建（预览每 0.05 秒跟着时钟重建一次）
///   不会把基线刷新成别处刚写进去的新值、再让旧草稿盖回去（复审 P1）。
///
/// 提交时机与仓库其余输入框一致：**回车或失焦即提交**，没有单独的「取消」——
/// 改错了按 ⌘Z。一次提交 = 一步撤销。
struct SubtitleInlineEditor: View {
    let project: VideoEditProject
    let cueID: UUID
    /// 输入框收工（回车、点完成）后通知调用方关掉浮层。
    var onDone: () -> Void = {}

    @FocusState private var focused: Bool

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        VStack(alignment: .leading, spacing: 6) {
            TextField(placeholder, text: project.subtitleTextBinding(cueID: cueID), axis: .vertical)
                .lineLimit(1...4)
                .foregroundStyle(isTranslation ? HierarchicalShapeStyle.secondary : .primary)
                .focused($focused)
                .onSubmit { finish() }
            HStack(spacing: 8) {
                Text(Timecode.formatMillis(cue?.start ?? 0, separator: ","))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 6)
                Button("Done") { finish() }
                    .controlSize(.small)
                    .instantHelp("Finish editing this line", shortcut: .plain("Return"))
            }
        }
        .textFieldStyle(.roundedBorder)
        .onAppear {
            focused = true
            project.beginSubtitleDraft(cueID: cueID)
        }
        .onChange(of: focused) { _, now in
            if now { project.beginSubtitleDraft(cueID: cueID) } else { project.commitSubtitleDraft() }
        }
        // 浮层被点走、被别的操作关掉时也要落盘 —— 失焦即提交，不许丢字。
        .onDisappear { project.commitSubtitleDraft() }
    }

    private var cue: SubtitleCue? { project.state.subtitleCue(cueID) }

    private var isTranslation: Bool { project.state.subtitleTrack(of: cueID) == .translation }

    /// 字面量走 `LocalizedStringKey`（两张字符串表里都有），别拼成 String —— 那样不翻译。
    private var placeholder: LocalizedStringKey { isTranslation ? "Translated text" : "Original text" }

    private func finish() {
        project.commitSubtitleDraft()
        onDone()
    }
}
