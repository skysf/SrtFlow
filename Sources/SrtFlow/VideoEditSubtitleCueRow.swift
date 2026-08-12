import SwiftUI
import SrtFlowCore

/// 字幕列里哪个格子有光标。**焦点归面板持有**（`@FocusState` 在
/// `VideoEditSubtitlePanel` 上，行里拿的是 `FocusState.Binding`）：
/// 新建一行之后要由外面把光标放进去，而行自己是会被重建的临时值 ——
/// 从行内部延迟写自己的 `@FocusState` 实测无效（写进的是已经作废的那份），
/// 表现为按下 + 之后光标不在新行上，接着打的字全被当成快捷键吃掉
/// （空格播放、V 切眼睛、M 打标记）。2026-08-12 冒烟实测。
enum SubtitleFieldFocus: Hashable {
    case original(UUID)
    case translation(UUID)}

/// 字幕列里的一行：序号 + 起止时间 + 原文 + 译文 + 状态标记。
///
/// 所有写入走 `VideoEditProjectSubtitleLink` 的合同入口（一次提交 = 一步撤销；
/// 译文过期、置信度作废、两轨同步由合同保证，这里不碰规则本体）。
///
/// 文本草稿**不在这里**：它挂在工程上（`VideoEditSubtitleDraft.swift`），行只负责
/// 显示和把焦点变化转成「开草稿 / 落草稿」。这样保存、切工程、退出都能在读模型之前
/// 同步落定，不依赖失焦回调的时机（复审 P1）；dirty 判定与 CAS 也一并在那边。
struct VideoEditSubtitleCueRow: View {
    @ObservedObject var project: VideoEditProject
    let cue: SubtitleCue
    let meta: CueMeta?
    /// 播放头此刻正落在这条上。
    let isCurrent: Bool
    let isSelected: Bool
    /// 轨道眼睛推导出来的可编辑性：隐藏 = 不可编辑（与时间线字幕行同一条合同）。
    let canEditOriginal: Bool
    let canEditTranslation: Bool
    let onSelect: () -> Void

    @FocusState.Binding var focusedField: SubtitleFieldFocus?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("#\(cue.index)")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                    .frame(width: 24, alignment: .leading)
                // 两个时间码格子平分剩下的宽度：这一列可以被拖窄，钉死宽度
                // 会让「结束时间」在窄列里被切掉半截（实测 260pt 就切了）。
                TimecodeField(value: startBinding)
                    .font(.caption2.monospacedDigit())
                    .frame(minWidth: 58, maxWidth: .infinity)
                    .disabled(!canEditTiming)
                Text("→").font(.caption2).foregroundStyle(.tertiary)
                TimecodeField(value: endBinding)
                    .font(.caption2.monospacedDigit())
                    .frame(minWidth: 58, maxWidth: .infinity)
                    .disabled(!canEditTiming)
                badges
            }
            if canEditOriginal {
                TextField(
                    "Original text",
                    text: project.subtitleTextBinding(cueID: cue.id, isTranslation: false),
                    axis: .vertical
                )
                .lineLimit(1...3)
                .focused($focusedField, equals: .original(cue.id))
                .onSubmit { project.commitSubtitleDraft() }
            }
            if canEditTranslation {
                TextField(
                    "Translated text",
                    text: project.subtitleTextBinding(cueID: cue.id, isTranslation: true),
                    axis: .vertical
                )
                .lineLimit(1...3)
                .foregroundStyle(.secondary)
                .focused($focusedField, equals: .translation(cue.id))
                .onSubmit { project.commitSubtitleDraft() }
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .textFieldStyle(.roundedBorder)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onChange(of: focusedField) { old, new in
            // 光标落进哪一行，选中的就该是哪一行 —— 不然预览上的拖框、⌫ 删除
            // 指的还是上一行，用户改的和选的对不上。
            if new == .original(cue.id) {
                onSelect()
                project.beginSubtitleDraft(cueID: cue.id, isTranslation: false)
            } else if new == .translation(cue.id) {
                onSelect()
                project.beginSubtitleDraft(cueID: cue.id, isTranslation: true)
            }
            // 失焦即提交（走人的那一刻，不等回车）。
            let leftMine = (old == .original(cue.id) && new != .original(cue.id))
                || (old == .translation(cue.id) && new != .translation(cue.id))
            if leftMine, project.subtitleDraft?.cueID == cue.id {
                project.commitSubtitleDraft()
            }
        }
        // 整列被关掉、行被滚出复用范围时兜底一次；只提交属于自己那份草稿。
        .onDisappear {
            if project.subtitleDraft?.cueID == cue.id { project.commitSubtitleDraft() }
        }
    }

    /// 时间是两轨共用的（译文是原文的镜像），所以任一轨看得见就能改。
    private var canEditTiming: Bool { canEditOriginal || canEditTranslation }

    @ViewBuilder private var badges: some View {
        HStack(spacing: 4) {
            if meta?.translationStale == true {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
                    .instantHelp(verbatim: L10n("Translation is out of date — retranslate this cue."))
            }
            if meta?.readingSpeedWarning == true {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.yellow)
                    .instantHelp(verbatim: L10n("Too fast to read at this clip speed."))
            }
            if let confidence = meta?.recognitionConfidence, confidence < 0.5 {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.red)
                    .instantHelp(verbatim: L10n("Low recognition confidence — double-check this cue."))
            }
        }
        .font(.caption)
    }

    // MARK: - 时间

    private var currentCue: SubtitleCue? {
        project.state.subtitle?.cues.first { $0.id == cue.id }
    }

    /// 起止时间各自一个格子，写回时**两个值一起交给合同**（合同 1 同步两轨）。
    /// 读的是模型当前值，不是建行时的快照 —— 改完 start 紧接着改 end 时，
    /// 拿快照的 end 会把刚写进去的 start 连带覆盖回去。
    private var startBinding: Binding<TimeInterval> {
        Binding(
            get: { currentCue?.start ?? cue.start },
            set: { newValue in
                guard let now = currentCue, newValue < now.end else { return }
                project.linkedSetCueTime(id: cue.id, start: newValue, end: now.end)
            }
        )
    }

    private var endBinding: Binding<TimeInterval> {
        Binding(
            get: { currentCue?.end ?? cue.end },
            set: { newValue in
                guard let now = currentCue, newValue > now.start else { return }
                project.linkedSetCueTime(id: cue.id, start: now.start, end: newValue)
            }
        )
    }
}
