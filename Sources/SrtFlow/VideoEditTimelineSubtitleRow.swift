import AppKit
import SwiftUI
import SrtFlowCore

// MARK: - 字幕行（原文 / 译文两条镜像轨）
//
// 从 `VideoEditTimelineView.swift` 拆出来（拆分前 2101 行，远超仓库约 800 行的
// 警戒线）。译文轨是原文轨的镜像（同 ID 同时间），点任意一行选中的是同一条 cue。
// 块本身在 `VideoEditTimelineSubtitleCueBlock.swift`（按值比较，不跟着时间线重算）；
// 这里只管行、点了选谁、拖动会话的起手和落地。
// 可见性与布局的长期约束见
// docs/architecture/subtitle-track-visibility-and-layout.md。
// 接线守卫 `checks/timeline-drag-wiring.sh` 按文件扫描，挪动这里的东西要同步改它。

extension VideoEditTimelineView {

    // MARK: - 字幕行

    func subtitleRow(kind: SubtitleRowKind) -> some View {
        // 译文轨是原文轨的**镜像**：同 ID、同时间（LinkedSubtitleEditing 强制），
        // 所以两行的块位置天然对齐，点任意一行选中的是同一条 cue。
        let cues = kind == .original
            ? project.state.subtitle?.cues
            : project.state.subtitleCompanion?.translation?.cues
        let hidden = kind == .original
            ? project.state.subtitleHidden
            : project.state.translationHidden
        let tint: Color = kind == .original ? .orange : .teal
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary.opacity(0.25))
                .frame(width: contentWidth)
            if let cues {
                ForEach(cues) { cue in
                    SubtitleCueBlockView(
                        cue: cue,
                        pps: pps,
                        tint: tint,
                        isSelected: isSelected(cue: cue.id),
                        dragOffset: dragOffset(movingID: cue.id),
                        onTap: {
                            // 点选 = 选中这条 cue（预览出字幕拖框）+ 把播放头
                            // 带进这条字幕，画面上立刻有字可调。⌘/⇧ 点是加选。
                            let event = NSApp.currentEvent
                            let flags = event?.modifierFlags ?? []
                            let additive = flags.contains(.command) || flags.contains(.shift)
                            if !additive { clock.seek(to: cue.start + 0.05) }
                            project.selectSubtitleCue(cue.id, additive: additive)
                            // 双击 = 就地改这条的文字。用 clickCount 分流，
                            // 不另挂 count: 2 的手势：那会和块自己的拖动抢，
                            // 单击选中还得等系统确认「不是双击」，慢半拍。
                            guard !additive, (event?.clickCount ?? 1) >= 2 else { return }
                            if clock.isPlaying { clock.togglePlayback() }
                            editingCue = EditingCue(id: cue.id, kind: kind)
                        },
                        onDragChange: { translation, pointerViewport in
                            // 判据带上「有没有活着的会话」：只比 id 的话，
                            // 上一轮被打断（切栏目/关窗）留下的陈旧 id 会让
                            // 同一条 cue 的下一次拖动整轮都建不出会话。
                            if clipDrag == nil || movingCueID != cue.id {
                                movingCueID = cue.id
                                beginCueDrag(cue)
                            }
                            updateClipDrag(translation: translation, pointerViewport: pointerViewport)
                        },
                        onDragEnd: {
                            movingCueID = nil
                            endClipDrag()
                        }
                    )
                    // 按值比较：拖动每动一下时间线都重算，没变的 cue 别跟着重算
                    //（见 `SubtitleCueBlockView` 文件头）。
                    .equatable()
                }
            }
        }
        // 隐藏中：灰显 + **不吃事件**，与其他轨道（`trackRow`）的合同一致。
        // 少了 allowsHitTesting 这一半，隐藏的字幕行照样点得中、拖得动，而且
        // 两条字幕轨是镜像的，改的是**两轨**的时间 —— 隐藏 = 不可编辑，
        // 灰显只是它的观感。框选那边本来就跳过隐藏轨（`Row.isHidden`）。
        .opacity(hidden ? 0.35 : 1)
        .allowsHitTesting(!hidden)
        // 就地编辑的浮层**挂在整行上，锚点按 unit point 算到块中心**。
        //
        // 不许挂在 cue 块本身：块是用 `.offset` 画出去的，offset 只改渲染不改布局
        // 框，popover 会锚在未偏移的原位 —— 也就是这一行的最左端，浮层于是弹在
        // 离被点的字幕很远的地方（2026-08-12 用户报的第一版就是这样）。
        .popover(
            isPresented: Binding(
                get: { editingCue?.kind == kind && editingCueValue(in: cues) != nil },
                set: { if !$0 { editingCue = nil } }
            ),
            attachmentAnchor: .point(cueAnchor(editingCueValue(in: cues))),
            arrowEdge: .top
        ) {
            if let cue = editingCueValue(in: cues) {
                SubtitleInlineEditor(
                    project: project,
                    cueID: cue.id,
                    editsOriginal: !project.state.subtitleHidden,
                    editsTranslation: project.state.hasVisibleTranslation,
                    onDone: { editingCue = nil }
                )
                .frame(width: 320)
                .padding(12)
                .appLanguage()
            }
        }
    }

    /// 正在就地编辑的那条 cue（在这一行的 cue 里找）。
    private func editingCueValue(in cues: [SubtitleCue]?) -> SubtitleCue? {
        guard let editingCue, let cues else { return nil }
        return cues.first { $0.id == editingCue.id }
    }

    /// 浮层的锚点：这一行里那个块的**中心上沿**，换成行宽的比例。
    private func cueAnchor(_ cue: SubtitleCue?) -> UnitPoint {
        guard let cue, contentWidth > 1 else { return .top }
        let width = max(TimelineMarquee.cueMinimumWidth, (cue.end - cue.start) * pps)
        let center = cue.start * pps + width / 2
        return UnitPoint(x: min(max(center / contentWidth, 0), 1), y: 0)
    }

}
