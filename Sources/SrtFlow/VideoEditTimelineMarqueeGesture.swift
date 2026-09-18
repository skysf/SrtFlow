import AppKit
import SwiftUI

// MARK: - 框选（拉框选中一片）
//
// 从 `VideoEditTimelineView.swift` 拆出来（拆分前 2101 行，远超仓库约 800 行的
// 警戒线）。命中判定的纯值部分在 `VideoEditTimelineMarquee.swift`，这里只有接线：
// 手势、会话起止、喂给命中判定的行模型，以及「看框不看模型」的高亮助手。
// 长期约束见 docs/architecture/timeline-drag-gestures.md 的「框选」一节。
// 接线守卫 `checks/timeline-drag-wiring.sh` 按文件扫描，挪动这里的东西要同步改它。

extension VideoEditTimelineView {

    // MARK: - 框选

    /// 空白处拉框：相交即选中，⌘/⇧ 加选，拖到视口边缘自动滚动。
    ///
    /// **整轮拖框不写 `project`** —— 命中集合只在 `marquee` 这个 `@State` 里，
    /// 松手才落一次。每一拍写 `@Published` 的选择会连带预览区、检查器、所有块
    /// 连同缩略图与波形重建，还要重挂一次自动保存，框立刻就跟不上光标了
    /// （和拖块同一条约束，见 docs/architecture/timeline-drag-gestures.md）。
    var marqueeGesture: some Gesture {
        // 起手门槛和块的移动手势一致：手抖几个点不该把已有的选择清掉。
        DragGesture(minimumDistance: 4, coordinateSpace: .named(VideoEditTimelineView.scrollSpace))
            .onChanged { value in
                if marquee == nil { beginMarquee(at: value.startLocation) }
                updateMarquee(pointer: value.location)
            }
            .onEnded { _ in endMarquee() }
    }

    private func beginMarquee(at start: CGPoint) {
        // 拉框期间把悬停预览收掉，画面回播放头 —— 和拖块的处理一致。
        project.clock.endPeek()
        let flags = NSEvent.modifierFlags
        marquee = TimelineMarquee.Session(
            // 锚点存**滚动内容**的坐标：视口坐标 + 此刻的滚动量。这个量必须
            // **现读**（`TimelineScrollGeometry`）—— 缓存进 `@State` 的版本在
            // 起手这一拍可能还是上一次布局的值，框就会整体画到指针左边。
            anchor: CGPoint(x: start.x + scrollGeometry.offsetX, y: start.y),
            additive: flags.contains(.command) || flags.contains(.shift),
            base: TimelineMarquee.Hit(
                clips: project.selectedClipIDs,
                shapes: project.selectedShapeIDs,
                texts: project.selectedTextIDs,
                cues: project.selectedSubtitleCueIDs
            )
        )
    }

    /// `pointer` 是指针在滚动视口里的位置（手势坐标系钉在视口上）。
    private func updateMarquee(pointer: CGPoint) {
        guard marquee != nil else { return }
        applyMarqueePoint(pointer: pointer)
        autoScroller.update(pointerX: pointer.x, viewportWidth: viewportWidth) {
            // 自动滚动那一拍指针没动，只有滚动量变了 —— 框要跟着内容继续长。
            applyMarqueePoint(pointer: pointer)
        }
    }

    private func applyMarqueePoint(pointer: CGPoint) {
        guard var session = marquee else { return }
        session.update(
            current: CGPoint(x: pointer.x + scrollGeometry.offsetX, y: pointer.y),
            rows: marqueeRows(),
            pixelsPerSecond: pps
        )
        marquee = session
    }

    private func endMarquee() {
        autoScroller.stop()
        defer { marquee = nil }
        guard let session = marquee else { return }
        // 空框 = 点了一下空白：四类一起清（和 `.onTapGesture` 同义）。
        project.applyBoxSelection(
            clips: session.hit.clips,
            shapes: session.hit.shapes,
            texts: session.hit.texts,
            cues: session.hit.cues
        )
    }

    /// 喂给命中判定的行模型。y 用滚动内容的坐标 —— 时间线没有纵向滚动，
    /// 视口坐标和内容坐标在 y 上是同一个数（`rowLayouts` 也按这个排）。
    private func marqueeRows() -> [TimelineMarquee.Row] {
        rowLayouts().compactMap { layout -> TimelineMarquee.Row? in
            let spec = layout.spec
            let items: [TimelineMarquee.Item]
            if let slot = spec.slot {
                items = project.state[track: slot].map {
                    TimelineMarquee.Item(id: $0.id, start: $0.timelineStart, end: $0.timelineEnd, kind: .clip)
                }
            } else if spec.isShapes {
                items = project.state.shapes.map {
                    TimelineMarquee.Item(id: $0.id, start: $0.timelineStart, end: $0.timelineEnd, kind: .shape)
                }
            } else if let level = spec.textLevel {
                items = textOverlays(atLevel: level).map {
                    TimelineMarquee.Item(id: $0.id, start: $0.timelineStart, end: $0.timelineEnd, kind: .text)
                }
            } else if let kind = spec.subtitleKind {
                // 译文轨是原文轨的镜像（同 ID 同时间），从哪一行框中的都是同一条 cue。
                let cues = kind == .original
                    ? project.state.subtitle?.cues
                    : project.state.subtitleCompanion?.translation?.cues
                items = (cues ?? []).map {
                    TimelineMarquee.Item(id: $0.id, start: $0.start, end: $0.end, kind: .subtitleCue)
                }
            } else {
                // 标尺行：拖它是 scrub，框不到任何东西。
                return nil
            }
            // 纵向按**画出来的**块算，不是整行：字幕/形状块在行内上下都留了白，
            // 按整行判的话框从留白里扫过也会选中（常量与画块处共用）。
            let minY: Double
            let maxY: Double
            if spec.isShapes {
                minY = layout.minY + TimelineMarquee.shapeTopInset
                maxY = minY + TimelineMarquee.shapeHeight
            } else if spec.textLevel != nil {
                minY = layout.minY + TimelineMarquee.textTopInset
                maxY = minY + TimelineMarquee.textHeight
            } else if spec.subtitleKind != nil {
                minY = layout.minY + TimelineMarquee.cueTopInset
                maxY = minY + TimelineMarquee.cueHeight
            } else {
                minY = layout.minY
                maxY = layout.maxY
            }
            return TimelineMarquee.Row(
                minY: minY,
                maxY: maxY,
                isHidden: spec.isHidden,
                items: items
            )
        }
    }

    /// 拉框中的高亮只看框，不看模型 —— 模型要等松手才写。
    func isSelected(clip id: UUID) -> Bool {
        marquee?.hit.clips.contains(id) ?? project.selectedClipIDs.contains(id)
    }

    func isSelected(shape id: UUID) -> Bool {
        marquee?.hit.shapes.contains(id) ?? project.selectedShapeIDs.contains(id)
    }

    func isSelected(text id: UUID) -> Bool {
        marquee?.hit.texts.contains(id) ?? project.selectedTextIDs.contains(id)
    }

    func isSelected(cue id: UUID) -> Bool {
        marquee?.hit.cues.contains(id) ?? project.selectedSubtitleCueIDs.contains(id)
    }

}
