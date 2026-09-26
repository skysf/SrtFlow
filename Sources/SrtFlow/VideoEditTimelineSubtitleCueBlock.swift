import SwiftUI
import SrtFlowCore

// MARK: - 时间线上的字幕 cue 块
//
// 管什么：一条 cue 在字幕行上画成什么样（色块、选中描边、拖动中的渲染位移）、收点击、
// 移动手势和两头的裁切把手（2026-09-26 加，同形状块）、悬停的提示文字。
// 不管什么：点了选谁、拖到哪、裁多少 —— 全在行（`subtitleRow`）、`VideoEditTimelineDragWiring.swift`
// 和工程的 `liveTrim` 里，块只往外回调。
//
// 从 `subtitleRow` 的 ForEach 里拆出来（2026-09-24）：写在行里的话它就是时间线 body 的
// 一部分，拖动每动一下时间线一重算，几十条 cue 连同各自的提示修饰器全部跟着重算
//（用户 74 条 cue 的工程实测：拖一段音频 30 拍，提示修饰器重算 2300 多次）。
// 现在按值比较（`==`），cue 没变就不重算 —— 与 `TextBlockView` / `ShapeBlockView` 同一套。

struct SubtitleCueBlockView: View, Equatable {
    let cue: SubtitleCue
    let pps: Double
    /// 原文轨橙、译文轨青。
    let tint: Color
    /// 模型里的选中。拉框进行中的实时高亮另走 `marqueeHit`（看框不看模型）。
    let isSelected: Bool
    /// 这一句单独藏起来了（V）：灰显 + 斜杠眼睛，但照样点得中、拖得动（同别的块）。
    let isHidden: Bool
    /// 拖动 / 拉框的会话盒子：只 `onReceive` 自己那份位移和框选命中（同 `ClipBlockView`）。
    let drag: TimelineDragBox
    /// 在不在这一轮拖动的成员里（时间线按 `dragMembers` 算好传进来，一轮只变两次）：
    /// 是成员才订阅位移，不是就拿一个永远不发的发布者（§0b）。
    let isDragMember: Bool
    /// 单击 / 双击都从这里出去（`NSApp.currentEvent` 的 clickCount 由行来分流）。
    let onTap: () -> Void
    /// (手势总位移, 指针在滚动视口里的位置)。起手（冻结这一轮的输入）也由行在
    /// 这里判 —— 判据要带上「有没有活着的会话」，块里的一个布尔值判不了。
    let onDragChange: (CGSize, CGPoint) -> Void
    let onDragEnd: () -> Void
    /// 分割工具下不给把手（与剪辑 / 形状块同规矩）：父级传 `activeTool == .select`。
    let canTrim: Bool
    /// (leading, 手势开始以来的总位移秒数)。落到工程的 `liveTrim`。
    let onTrim: (Bool, Double) -> Void
    let onTrimEnd: () -> Void
    /// 右键「隐藏 / 显示」：和 V 同一个动作，先替用户选中这一句（同别的块的右键项）。
    let onToggleHidden: () -> Void
    /// 右键「剪切 / 拷贝 / 粘贴」（`VideoEditProject.runClipboardCommand`：右键的这一块在选中集合里就作用于整个选择）。
    let onClipboard: (TimelineClipboardCommand) -> Void

    /// 拖动中的渲染位移（秒）。nil = 没在被拖，按模型里的位置画。从 `drag.$offsets` 收。
    @State private var dragOffset: Double?
    /// 拉框进行中这块在不在框里；nil = 没在拉框、或者和模型里一样，按 `isSelected` 画。
    @State private var marqueeHit: Bool?
    private var highlighted: Bool { marqueeHit ?? isSelected }
    private var width: Double { max(TimelineMarquee.cueMinimumWidth, (cue.end - cue.start) * pps) }

    /// 只比画面用得到的输入（同 `ClipBlockView`）。闭包比不了、也不用比：它们捕获的是
    /// 时间线视图，读的是它的 `@State` 和工程对象，永远是最新的。
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.cue == rhs.cue && lhs.pps == rhs.pps && lhs.tint == rhs.tint
            && lhs.isSelected == rhs.isSelected && lhs.drag === rhs.drag && lhs.isDragMember == rhs.isDragMember
            && lhs.canTrim == rhs.canTrim && lhs.isHidden == rhs.isHidden
    }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        RoundedRectangle(cornerRadius: 3)
            .fill(tint.opacity(highlighted ? 0.8 : 0.45))
            .overlay(alignment: .leading) {
                // 灰显本身还不够（同剪辑块）：得看得出这一句是按 V 藏起来的。块太窄就不画。
                if isHidden, width > 16 {
                    Image(systemName: "eye.slash").font(.system(size: 7)).foregroundStyle(.white).padding(.leading, 3)
                }
            }
            .timelineHiddenLook(isHidden)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(.white, lineWidth: highlighted ? 1.2 : 0)
            )
            // 宽和高都与框选的命中判定共用常量：画多大就该按多大判，
            // 否则一条 0.05 秒的 cue 框得中却看不见、或反过来。
            .frame(width: width, height: TimelineMarquee.cueHeight)
            // 把手要在 .offset 之前挂上，不然会留在块没偏移时的位置（同剪辑 / 形状块）。
            .overlay(alignment: .leading) { trimHandle(leading: true) }
            .overlay(alignment: .trailing) { trimHandle(leading: false) }
            .offset(
                x: (cue.start + (dragOffset ?? 0)) * pps,
                y: TimelineMarquee.cueTopInset
            )
            .zIndex(dragOffset != nil ? 10 : 0)
            .onTapGesture(perform: onTap)
            .contextMenu {
                TimelineClipboardMenu.items(onClipboard)
                Divider()
                Button(isHidden ? "Show Line" : "Hide Line", action: onToggleHidden)
            }
            .gesture(
                // 与剪辑/形状块同一套：坐标系钉在不动的滚动视口上
                //（块会在手指底下挪窝，自动滚动还会把内容抽走）。
                DragGesture(minimumDistance: 4, coordinateSpace: .named(VideoEditTimelineView.scrollSpace))
                    .onChanged { value in onDragChange(value.translation, value.location) }
                    .onEnded { _ in onDragEnd() }
            )
            .instantHelp(verbatim: SubtitleSerializer.plainText(cue.text))
            // 只收自己那份：位移 / 框选命中没变就不写 @State，这块就不重算（§0b）。
            .onReceive(drag.offsets(member: isDragMember)) { offsets in
                let mine = offsets.offset(for: cue.id)
                if mine != dragOffset { dragOffset = mine }
            }
            .onReceive(drag.$marqueeHit) { hit in
                // 框里的和模型里的一样就记 nil：不然框一起手，全部块都从 nil 变成 false、各重算一遍。
                let mine = hit.map { $0.cues.contains(cue.id) }.flatMap { $0 == isSelected ? nil : $0 }
                if mine != marqueeHit { marqueeHit = mine }
            }
    }

    /// 与形状块的裁切把手同款：太窄不给（点不到移动区），手势必须用 .global
    /// —— 把手挂在块边缘，.local 会随裁切生效跟着块边移动，位移被自己抵消。
    @ViewBuilder
    private func trimHandle(leading: Bool) -> some View {
        if width > 26, canTrim {
            Rectangle()
                .fill(highlighted ? .white.opacity(0.85) : .white.opacity(0.001))
                .frame(width: highlighted ? 4 : 7)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .global)
                        .onChanged { value in onTrim(leading, value.translation.width / pps) }
                        .onEnded { _ in onTrimEnd() }
                )
                .pointerStyle(.columnResize)
        }
    }
}
