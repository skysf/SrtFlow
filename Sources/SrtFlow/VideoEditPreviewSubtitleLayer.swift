import SwiftUI
import SrtFlowCore

// MARK: - 预览上的字幕
//
// 管什么：播放头此刻每一块字幕显示什么（`TimelineState.subtitleScreenBlocks`，和烧录同一份）、
// 每一块量出来多高，以及拖框 / 就地改字要用的矩形（`SubtitlePreviewFrames`：整块的、两条轨叠在一起时
// 某条轨那几行的）。
// 不管什么：画面上点选 / 双击改字（`SubtitlePreviewEditLayer`）、拖框（`SubtitleFrameCanvas`）、
// 描边文字本身怎么画（`BurnInSubtitleOverlay`，烧字幕页也用）。
//
// 2026-09-26 起原文、译文两条独立的轨（docs/plans/2026-09-26-hide-guides-independent-subtitles.md）：
// 叠在一起时是一块（原文在上、译文在下），分开摆时各是一块。叠在一起时另外（透明地）量一下译文那几行
// 单独多高：拖框只框被选中那条轨的几行，拖它时两条就此分开、另一条原地钉住（计划 S8）。

/// 预览上每一块字幕此刻量出来的高度（点）。键见 `SubtitleScreenBlock.measureKey` / `tailMeasureKey`。
typealias SubtitleBlockHeights = [String: Double]

extension SubtitleScreenBlock {
    /// 这一块在预览上量高度用的键：块里有哪几条轨。
    var measureKey: String { tracks.map(\.rawValue).joined(separator: "+") }
    /// 叠在一起时，下面那条轨（译文）那几行单独量出来的高度。
    var tailMeasureKey: String { measureKey + ".tail" }
}

/// 预览上字幕块的矩形：整块的、叠在一起时某条轨那几行的。拖框和就地改字共用这一份，
/// 换算本身在 `SubtitleFrameGeometry`（不许算第二遍）。
struct SubtitlePreviewFrames {
    let boxSize: CGSize
    let style: BurnInStyle
    let heights: SubtitleBlockHeights
    /// 画面此刻显示的是哪一刻（`clock.displayTime`）：叠在一起的一块只有两条轨此刻都有字才切两截。
    let time: Double

    func geometry(of block: SubtitleScreenBlock) -> SubtitleFrameGeometry {
        SubtitleFrameGeometry(boxSize: boxSize, style: style, layout: block.layout, blockHeight: heights[block.measureKey] ?? 0)
    }

    /// 某条轨在这一块里占的矩形：单独一块就是整块；叠在一起时按量出来的译文高度切成上下两截
    /// （此刻只有一条轨有字时退回整块 —— 那时量出来的译文高度可能是上一句的，不能拿来切）。
    func rect(of track: SubtitleTrack, in block: SubtitleScreenBlock) -> CGRect {
        let whole = geometry(of: block).frameRect
        guard block.isStacked, block.text(of: .original, at: time) != nil, block.text(of: .translation, at: time) != nil,
              let tail = heights[block.tailMeasureKey], tail > 1, tail < whole.height - 1 else {
            return whole
        }
        switch track {
        case .translation: return CGRect(x: whole.minX, y: whole.maxY - tail, width: whole.width, height: tail)
        case .original: return CGRect(x: whole.minX, y: whole.minY, width: whole.width, height: whole.height - tail)
        }
    }

    /// 这条轨画在哪一块里（眼睛关着就没有）。
    static func block(of track: SubtitleTrack, in blocks: [SubtitleScreenBlock]) -> SubtitleScreenBlock? {
        blocks.first { $0.tracks.contains(track) }
    }
}

/// 预览上的字幕：每一块此刻的字、画面上点选 / 双击就地改字的那一层、轨道上选中 cue 时的拖框。
/// 字幕跟着播放头换句，所以它订阅时钟；描边文字那一块按值比较，换了句才重排。
///
/// body 直接给出这几层、不包容器：它们是预览 ZStack 的孩子（层序见
/// `VideoEditSubtitlePreviewEditor.swift` 的说明）。
struct PreviewSubtitleLayer: View {
    let project: VideoEditProject
    @ObservedObject var clock: PlayerClock
    let boxSize: CGSize
    let style: BurnInStyle
    /// 每一块字幕此刻的实测高度（定框用），由文字那几块回报。
    @Binding var blockHeights: SubtitleBlockHeights
    /// 预览里正在就地编辑的那句字幕（双击画面上的字幕进入）。
    @Binding var editingCueID: UUID?

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        // 眼睛是唯一的判据：两只都关（或没有字幕轨）就一块都没有，预览不画。
        let blocks = project.state.subtitleScreenBlocks()
        // displayTime：悬停预览时字幕要和画面显示的那一帧对上，而不是播放头。
        let time = clock.displayTime
        let scale = boxSize.height / Double(BurnInStyle.referenceHeight)
        ForEach(blocks, id: \.measureKey) { block in
            if let text = block.text(at: time) {
                PreviewSubtitleText(
                    text: text, style: style, scale: scale, boxSize: boxSize, layout: block.layout,
                    onBlockSize: { record($0.height, for: block.measureKey) }
                )
                .equatable()
                if block.isStacked, let tail = block.text(of: .translation, at: time) {
                    // 只量不画：译文那几行单独多高，拖框按它把整块切成上下两截。
                    PreviewSubtitleText(
                        text: tail, style: style, scale: scale, boxSize: boxSize, layout: block.layout,
                        onBlockSize: { record($0.height, for: block.tailMeasureKey) }
                    )
                    .equatable()
                    .opacity(0)
                }
            }
        }
        if blocks.contains(where: { $0.text(at: time) != nil }) {
            let frames = SubtitlePreviewFrames(boxSize: boxSize, style: style, heights: blockHeights, time: time)
            // 画面上的字幕：单击选中这句、双击就地改字（输入框浮在字幕下方）。
            // 夹在叠层和拖框中间 —— 见该文件的层序说明。
            SubtitlePreviewEditLayer(
                project: project, clock: clock, frames: frames, blocks: blocks, editingCueID: $editingCueID
            )
            // 轨道上点选了一句：叠出那条轨的字幕拖框（移动 / 换行宽度 / 等比字号）。
            // 放最上层 —— 有选中时字幕调整优先。
            if let cueID = project.selectedSubtitleCueID,
               let track = project.state.subtitleTrack(of: cueID),
               let block = SubtitlePreviewFrames.block(of: track, in: blocks),
               block.text(of: track, at: time) != nil {
                SubtitleFrameCanvas(
                    project: project, frames: frames, block: block, track: track,
                    // 框盖住了字幕，双击就地编辑这一路从框上补进来。
                    onDoubleClick: {
                        if clock.isPlaying { clock.togglePlayback() }
                        editingCueID = cueID
                    }
                )
            }
        }
    }

    /// 高度没变就不写：写一次根视图就重算一遍。
    private func record(_ height: Double, for key: String) {
        if blockHeights[key] != height { blockHeights[key] = height }
    }
}

/// 画面字幕的文字那一块，按值比较：描边是同一段字画九遍，跟着时钟每一跳重排一遍不便宜。
/// 文字、样式、尺寸没变就不重算；回报块高的闭包不比（它写的是根视图的 @State，永远是最新的）。
private struct PreviewSubtitleText: View, Equatable {
    let text: String
    let style: BurnInStyle
    let scale: Double
    let boxSize: CGSize
    let layout: SubtitleLayout?
    let onBlockSize: (CGSize) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.style == rhs.style && lhs.scale == rhs.scale
            && lhs.boxSize == rhs.boxSize && lhs.layout == rhs.layout
    }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        BurnInSubtitleOverlay(
            text: text,
            style: style,
            scale: scale,
            boxSize: boxSize,
            layout: layout,
            onBlockSize: onBlockSize
        )
    }
}
