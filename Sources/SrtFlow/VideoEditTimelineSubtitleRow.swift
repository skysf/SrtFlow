import AppKit
import SwiftUI
import SrtFlowCore

// MARK: - 字幕行（原文 / 译文两条独立的轨）
//
// 从 `VideoEditTimelineView.swift` 拆出来（拆分前 2101 行，远超仓库约 800 行的
// 警戒线）。2026-09-26 起两条轨独立：各自的句子、各自的 ID，点哪一行选中的就是
// 那一行的句子，挪 / 裁 / 删互不影响（docs/plans/2026-09-26-hide-guides-independent-subtitles.md）。
// 块本身在 `VideoEditTimelineSubtitleCueBlock.swift`（按值比较，不跟着时间线重算）；
// 这里只管行、点了选谁、拖动会话的起手和落地、裁切落到哪。
// 可见性与布局的长期约束见
// docs/architecture/subtitle-track-visibility-and-layout.md。
// 接线守卫 `checks/timeline-drag-wiring.sh` 按文件扫描，挪动这里的东西要同步改它。

extension VideoEditTimelineView {

    // MARK: - 字幕行

    func subtitleRow(kind: SubtitleTrack) -> some View {
        let cues = project.state.subtitleCues(of: kind)
        let hidden = project.state.isSubtitleTrackHidden(kind)
        let tint: Color = kind == .original ? .orange : .teal
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary.opacity(0.25))
                .frame(width: contentWidth)
            ForEach(cues) { cue in
                SubtitleCueBlockView(
                    cue: cue,
                    pps: pps,
                    tint: tint,
                    isSelected: project.selectedSubtitleCueIDs.contains(cue.id),
                    isHidden: project.state.isSubtitleCueHidden(cue.id),
                    drag: dragBox,
                    isDragMember: dragMembers.contains(cue.id),
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
                        if dragBox.clipDrag == nil || dragBox.movingCueID != cue.id {
                            dragBox.movingCueID = cue.id
                            beginCueDrag(cue)
                        }
                        updateClipDrag(translation: translation, pointerViewport: pointerViewport)
                    },
                    onDragEnd: {
                        // 起手记号由 `dragBox.end()` 一起清。
                        endClipDrag()
                    },
                    canTrim: project.activeTool == .select,
                    onTrim: { leading, delta in
                        // 走和别的块同一个裁切入口：选中的一组一起裁、吸附、亮线（§3.6 / §4）。
                        project.clock.endPeek()
                        project.liveTrim(
                            anchor: TimelineTrim.Member(id: cue.id, kind: .cue), leading: leading, deltaSeconds: delta
                        )
                    },
                    // 字幕不参与 AV 合成，收尾不用重建预览。
                    onTrimEnd: { project.endLiveEdit(rebuildsPreview: false) },
                    onToggleHidden: {
                        project.selectSubtitleCue(cue.id)
                        project.toggleHiddenForSelection()
                    }
                )
                // 按值比较：拖动每动一下时间线都重算，没变的 cue 别跟着重算
                //（见 `SubtitleCueBlockView` 文件头）。
                .equatable()
            }
        }
        // 隐藏中：灰显 + **不吃事件**，与其他轨道（`trackRow`）的合同一致。
        // 少了 allowsHitTesting 这一半，隐藏的字幕行照样点得中、拖得动 ——
        // 隐藏 = 不可编辑，灰显只是它的观感。框选那边本来就跳过隐藏轨（`Row.isHidden`）。
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
                // 只编双击的那一句（计划 S13）。
                SubtitleInlineEditor(project: project, cueID: cue.id, onDone: { editingCue = nil })
                .frame(width: 320)
                .padding(12)
                .appLanguage()
            }
        }
    }

    /// 正在就地编辑的那条 cue（在这一行的 cue 里找）。
    private func editingCueValue(in cues: [SubtitleCue]) -> SubtitleCue? {
        guard let editingCue else { return nil }
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
