import SwiftUI
import SrtFlowCore

// MARK: - 时间线上的字幕 cue 块
//
// 管什么：一条 cue 在字幕行上画成什么样（色块、选中描边、拖动中的渲染位移）、收点击
// 和移动手势、悬停的提示文字。
// 不管什么：点了选谁、拖到哪、两轨镜像怎么同步 —— 全在行（`subtitleRow`）和
// `VideoEditTimelineDragWiring.swift` 里，块只往外回调。
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
    let isSelected: Bool
    /// 拖动中的渲染位移（秒）。nil = 没在被拖，按模型里的位置画。
    let dragOffset: Double?
    /// 单击 / 双击都从这里出去（`NSApp.currentEvent` 的 clickCount 由行来分流）。
    let onTap: () -> Void
    /// (手势总位移, 指针在滚动视口里的位置)。起手（冻结这一轮的输入）也由行在
    /// 这里判 —— 判据要带上「有没有活着的会话」，块里的一个布尔值判不了。
    let onDragChange: (CGSize, CGPoint) -> Void
    let onDragEnd: () -> Void

    /// 只比画面用得到的输入（同 `ClipBlockView`）。闭包比不了、也不用比：它们捕获的是
    /// 时间线视图，读的是它的 `@State` 和工程对象，永远是最新的。
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.cue == rhs.cue && lhs.pps == rhs.pps && lhs.tint == rhs.tint
            && lhs.isSelected == rhs.isSelected && lhs.dragOffset == rhs.dragOffset
    }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        RoundedRectangle(cornerRadius: 3)
            .fill(tint.opacity(isSelected ? 0.8 : 0.45))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(.white, lineWidth: isSelected ? 1.2 : 0)
            )
            // 宽和高都与框选的命中判定共用常量：画多大就该按多大判，
            // 否则一条 0.05 秒的 cue 框得中却看不见、或反过来。
            .frame(
                width: max(TimelineMarquee.cueMinimumWidth, (cue.end - cue.start) * pps),
                height: TimelineMarquee.cueHeight
            )
            .offset(
                x: (cue.start + (dragOffset ?? 0)) * pps,
                y: TimelineMarquee.cueTopInset
            )
            .zIndex(dragOffset != nil ? 10 : 0)
            .onTapGesture(perform: onTap)
            .gesture(
                // 与剪辑/形状块同一套：坐标系钉在不动的滚动视口上
                //（块会在手指底下挪窝，自动滚动还会把内容抽走）。
                DragGesture(minimumDistance: 4, coordinateSpace: .named(VideoEditTimelineView.scrollSpace))
                    .onChanged { value in onDragChange(value.translation, value.location) }
                    .onEnded { _ in onDragEnd() }
            )
            .instantHelp(verbatim: SubtitleSerializer.plainText(cue.text))
    }
}
