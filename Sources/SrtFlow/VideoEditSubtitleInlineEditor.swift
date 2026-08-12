import SwiftUI
import SrtFlowCore

/// 就地编辑一条字幕的文字：时间线上双击 cue 块（浮层）与预览里双击字幕
/// （画面上的输入框）共用这一个视图 —— **两个入口，一套提交规则**。
///
/// 草稿与提交规则都不在这里：文本挂在工程上的 `SubtitleTextDraft`
/// （见 `VideoEditSubtitleDraft.swift`），写入走 `VideoEditProjectSubtitleLink`
/// 的合同入口。这样一来：
/// - 保存 / 切工程 / 退出能在读模型之前同步落定，不依赖失焦回调的时机；
/// - CAS 基线在**进入这一格时**冻结，父视图重建（预览每 0.05 秒跟着时钟重建一次）
///   不会把基线刷新成别处刚写进去的新值、再让旧草稿盖回去（复审 P1）。
///
/// 提交时机与仓库其余输入框一致：**回车或失焦即提交**，没有单独的「取消」——
/// 改错了按 ⌘Z。一格 = 一步撤销：原文和译文分别是两格，各自一步。
struct SubtitleInlineEditor: View {
    @ObservedObject var project: VideoEditProject
    let cueID: UUID
    /// 原文轨看得见吗。**隐藏 = 不可编辑**（与时间线字幕行同一条合同），
    /// 看不见的那条不给输入框 —— 否则用户会在改一条自己看不到的字幕。
    let editsOriginal: Bool
    /// 译文轨看得见吗（有译文轨且眼睛开着）。
    let editsTranslation: Bool
    /// 输入框收工（回车、点完成）后通知调用方关掉浮层。
    var onDone: () -> Void = {}

    @FocusState private var focus: Field?

    enum Field: Hashable { case original, translation }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if editsOriginal {
                TextField(
                    "Original text",
                    text: project.subtitleTextBinding(cueID: cueID, isTranslation: false),
                    axis: .vertical
                )
                .lineLimit(1...4)
                .focused($focus, equals: .original)
                .onSubmit { finish() }
            }
            if editsTranslation {
                TextField(
                    "Translated text",
                    text: project.subtitleTextBinding(cueID: cueID, isTranslation: true),
                    axis: .vertical
                )
                .lineLimit(1...4)
                .foregroundStyle(.secondary)
                .focused($focus, equals: .translation)
                .onSubmit { finish() }
            }
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
            focus = editsOriginal ? .original : .translation
            project.beginSubtitleDraft(cueID: cueID, isTranslation: !editsOriginal)
        }
        .onChange(of: focus) { _, new in
            switch new {
            case .original: project.beginSubtitleDraft(cueID: cueID, isTranslation: false)
            case .translation: project.beginSubtitleDraft(cueID: cueID, isTranslation: true)
            case nil: project.commitSubtitleDraft()
            }
        }
        // 浮层被点走、被别的操作关掉时也要落盘 —— 失焦即提交，不许丢字。
        .onDisappear { project.commitSubtitleDraft() }
    }

    private var cue: SubtitleCue? {
        project.state.subtitle?.cues.first { $0.id == cueID }
    }

    private func finish() {
        project.commitSubtitleDraft()
        onDone()
    }
}
