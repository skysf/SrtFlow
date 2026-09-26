import SwiftUI
import SrtFlowCore

/// 字幕表里的一行：轨道标记 + 序号 + 起止时间 + 这一句的字 + 状态标记。
///
/// 一行只编一句（2026-09-26 起原文、译文是两条独立的轨，表里按时间交错排，计划 S12）；
/// 行首一条橙 / 青色的竖条标出是哪条轨，颜色和时间线上两行一致。
///
/// 所有写入走 `VideoEditProjectSubtitleLink` 的合同入口（一次提交 = 一步撤销；
/// 置信度作废、译文跟上原文由合同保证，这里不碰规则本体）。
///
/// 文本草稿**不在这里**：它挂在工程上（`VideoEditSubtitleDraft.swift`），行只负责
/// 显示和把焦点变化转成「开草稿 / 落草稿」。这样保存、切工程、退出都能在读模型之前
/// 同步落定，不依赖失焦回调的时机（复审 P1）；dirty 判定与 CAS 也一并在那边。
///
/// **焦点归面板持有**（`@FocusState` 在 `VideoEditSubtitlePanel` 上，行里拿的是
/// `FocusState.Binding`）：新建一行之后要由外面把光标放进去，而行自己是会被重建的临时值 ——
/// 从行内部延迟写自己的 `@FocusState` 实测无效（写进的是已经作废的那份），
/// 表现为按下 + 之后光标不在新行上，接着打的字全被当成快捷键吃掉
/// （空格播放、V 切段的显隐、M 打标记）。2026-08-12 冒烟实测。
struct VideoEditSubtitleCueRow: View {
    let project: VideoEditProject
    let cue: SubtitleCue
    let track: SubtitleTrack
    /// 原文句的元数据（置信度、读速告警）；译文句没有。
    let meta: CueMeta?
    /// 译文句：原文改过字、这句过期了（现算，`SubtitleCompanion.isTranslationStale`）。
    let isStale: Bool
    /// 这一句单独藏起来了（V）：照样能改，只是预览、烧录、导出的字幕文件里都没有它。
    let isHidden: Bool
    /// 播放头此刻正落在这句上。
    let isCurrent: Bool
    let isSelected: Bool
    /// 这条轨看得见吗：隐藏 = 不可编辑（与时间线字幕行同一条合同）。
    let canEdit: Bool
    let onSelect: () -> Void

    @FocusState.Binding var focusedCueID: UUID?

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        HStack(alignment: .top, spacing: 6) {
            // 行首的轨道标记：橙 = 原文、青 = 译文（同时间线上两行的颜色）。
            RoundedRectangle(cornerRadius: 1.5)
                .fill(track == .original ? Color.orange : Color.teal)
                .frame(width: 3)
                .instantHelp(trackName)
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
                        .disabled(!canEdit)
                    Text("→").font(.caption2).foregroundStyle(.tertiary)
                    TimecodeField(value: endBinding)
                        .font(.caption2.monospacedDigit())
                        .frame(minWidth: 58, maxWidth: .infinity)
                        .disabled(!canEdit)
                    badges
                }
                if canEdit {
                    TextField(placeholder, text: project.subtitleTextBinding(cueID: cue.id), axis: .vertical)
                        .lineLimit(1...3)
                        .foregroundStyle(track == .translation ? HierarchicalShapeStyle.secondary : .primary)
                        .focused($focusedCueID, equals: cue.id)
                        .onSubmit { project.commitSubtitleDraft() }
                } else {
                    // 藏起来的轨：字照样看得见，但不给输入框（灰显，同时间线上那一行）。
                    Text(SubtitleSerializer.plainText(cue.text))
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .lineLimit(3)
                }
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
        .onChange(of: focusedCueID) { old, new in
            // 光标落进哪一行，选中的就该是哪一行 —— 不然预览上的拖框、⌫ 删除
            // 指的还是上一行，用户改的和选的对不上。
            if new == cue.id {
                onSelect()
                project.beginSubtitleDraft(cueID: cue.id)
            }
            // 失焦即提交（走人的那一刻，不等回车）。
            if old == cue.id, new != cue.id, project.subtitleDraft?.cueID == cue.id {
                project.commitSubtitleDraft()
            }
        }
        // 整列被关掉、行被滚出复用范围时兜底一次；只提交属于自己那份草稿。
        .onDisappear {
            if project.subtitleDraft?.cueID == cue.id { project.commitSubtitleDraft() }
        }
    }

    /// 字面量走 `LocalizedStringKey`（两张字符串表里都有），别拼成 String —— 那样不翻译。
    private var placeholder: LocalizedStringKey { track == .original ? "Original text" : "Translated text" }
    private var trackName: LocalizedStringKey { track == .original ? "Original track" : "Translated track" }

    @ViewBuilder private var badges: some View {
        HStack(spacing: 4) {
            if isHidden {
                Image(systemName: "eye.slash")
                    .foregroundStyle(.secondary)
                    .instantHelp("Hidden line — not shown, burned in or exported")
            }
            if isStale {
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

    /// 读的是模型当前值，不是建行时的快照 —— 改完 start 紧接着改 end 时，
    /// 拿快照的 end 会把刚写进去的 start 连带覆盖回去。
    private var currentCue: SubtitleCue? { project.state.subtitleCue(cue.id) }

    /// 起止时间各自一个格子，写回时**两个值一起交给合同**（只改这句所在的那条轨）。
    private var startBinding: Binding<TimeInterval> {
        Binding(
            get: { currentCue?.start ?? cue.start },
            set: { newValue in
                guard let now = currentCue, newValue < now.end else { return }
                project.setSubtitleCueTime(id: cue.id, start: newValue, end: now.end)
            }
        )
    }

    private var endBinding: Binding<TimeInterval> {
        Binding(
            get: { currentCue?.end ?? cue.end },
            set: { newValue in
                guard let now = currentCue, newValue > now.start else { return }
                project.setSubtitleCueTime(id: cue.id, start: now.start, end: newValue)
            }
        )
    }
}
