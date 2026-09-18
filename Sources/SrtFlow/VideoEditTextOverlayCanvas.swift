import AppKit
import CoreGraphics
import SrtFlowCore
import SwiftUI

// MARK: - 预览上的文字叠层
//
// 画面本身**一个像素都不在这里画** —— 全部来自 `TextRenderer.render`，和导出
// 是同一个函数。这里只负责：把那张位图摆到对的地方、收点选/拖动/把手手势、
// 挂就地编辑的输入框。
//
// 层序：`剪辑变换框 → 形状叠层 → 文字叠层 → 字幕`，与导出滤镜链一字不差
// （见 docs/architecture/text-overlays.md）。
//
// ## 为什么要按屏幕的物理像素渲染
//
// 预览画布的尺寸是**点**，Retina 上一点是两个物理像素。按点渲染再交给 SwiftUI
// 放大，文字会糊掉一档 —— 而这个功能的全部意义就是"预览里调得准"。所以渲染
// 尺寸乘 `displayScale`，显示时再用 `Image(decorative:scale:)` 折回点。

/// 渲染缓存。静止的文字在播放过程中一帧都没变，重渲一遍纯属浪费；
/// 时刻进键是因为动画 —— 同一段文字在不同帧上长得不一样。
///
/// 键是**整个 overlay 加画布尺寸** —— 任何一个字段变了就该重渲，
/// 与其枚举"哪些字段影响画面"（漏一个就是画面不更新的疑难杂症），不如整个比。
@MainActor
final class TextRenderStore {
    private struct Key: Hashable {
        var overlay: TextOverlay
        var width: Int
        var height: Int
        /// 量化到工程帧之后的**帧序号**。用整数而不是 Double 当键，
        /// 免得浮点的 -0.0 / 0.0 之类算成两个键。
        var frame: Int
    }

    private var entries: [Key: RenderedText] = [:]

    /// 上限之外整个丢掉。动画播放时每一帧都是新键，留着只会涨；
    /// LRU 在这个量级上不值得，重渲一张文字位图是毫秒级的事。
    private static let capacity = 64

    func rendered(
        _ overlay: TextOverlay, canvas: CGSize, at time: Double, frameRate: ProjectFrameRate
    ) -> RenderedText? {
        // 预览也走 `quantize` —— 和导出同一把尺子。不量化的话预览停在两帧
        // 之间、成片停在帧上，逐点比对永远差一点，而“预览所见 = 成片所得”
        // 正是这套东西的全部前提。
        let quantized = TextAnimator.quantize(time, frameRate: frameRate)
        let key = Key(
            overlay: overlay,
            width: Int(canvas.width), height: Int(canvas.height),
            frame: Int((quantized * Double(max(1, frameRate.fps))).rounded())
        )
        if let hit = entries[key] { return hit }
        let state = TextAnimator.state(
            for: overlay, at: quantized, canvas: canvas, frameRate: frameRate
        )
        guard let made = TextRenderer.render(overlay, canvas: canvas, state: state) else { return nil }
        if entries.count >= Self.capacity { entries.removeAll(keepingCapacity: true) }
        entries[key] = made
        return made
    }
}

struct TextOverlayCanvas: View {
    @ObservedObject var project: VideoEditProject
    /// 必须直接订阅时钟：播放头动了，画面上该显示哪几段文字会跟着变。
    @ObservedObject var clock: PlayerClock
    let boxSize: CGSize

    @Environment(\.displayScale) private var displayScale

    @State private var store = TextRenderStore()
    /// 移动手势起手时文字块中心在画布上的位置。
    @State private var dragOrigin: CGPoint?
    /// 角把手起手时的字号（把手只给倍数，基准要在这里冻住）。
    @State private var scaleBaseFontSize: Double?
    @State private var centerGuides = (vertical: false, horizontal: false)

    private var visible: [TextOverlay] { project.visibleTextOverlays(at: clock.displayTime) }

    /// 渲染用的画布（物理像素）。
    private var renderCanvas: CGSize {
        CGSize(width: boxSize.width * displayScale, height: boxSize.height * displayScale)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 底噪：不拦事件，否则点画面空白就再也选不中底下的剪辑了。
            Color.clear.allowsHitTesting(false)

            ForEach(visible) { overlay in
                image(for: overlay)
            }
            ForEach(visible) { overlay in
                hitArea(for: overlay)
            }

            if let selected = project.selectedTextOverlay, selected.contains(time: clock.displayTime) {
                frameBox(for: selected)
            }

            if let id = project.textEditingRequest,
               let overlay = visible.first(where: { $0.id == id }) {
                editor(for: overlay)
            }

            CenterGuideLines(
                canvas: boxSize,
                showVertical: centerGuides.vertical,
                showHorizontal: centerGuides.horizontal
            )
        }
        .frame(width: boxSize.width, height: boxSize.height)
        // 把手的手势坐标系钉在这块不动的画布上（理由见 TextFrameBox 的文件头）。
        .coordinateSpace(name: TextFrameBox.space)
    }

    // MARK: - 画

    @ViewBuilder
    private func image(for overlay: TextOverlay) -> some View {
        if let rendered = store.rendered(
            overlay, canvas: renderCanvas,
            at: clock.displayTime, frameRate: project.state.frameRate
        ) {
            let size = CGSize(
                width: rendered.size.width / displayScale,
                height: rendered.size.height / displayScale
            )
            Image(decorative: rendered.image, scale: displayScale)
                .frame(width: size.width, height: size.height)
                .position(
                    x: rendered.origin.x / displayScale + size.width / 2,
                    y: rendered.origin.y / displayScale + size.height / 2
                )
                .allowsHitTesting(false)
        }
    }

    // MARK: - 点选与移动

    /// 命中范围就是**版面框**（转过之后的）。用渲染包络的话，投影和模糊会让
    /// 可点区域比看得见的字大出一大圈，点旁边的空白就选中了。
    private func hitArea(for overlay: TextOverlay) -> some View {
        let frame = TextRenderer.layoutFrame(overlay, canvas: boxSize)
        return Rectangle()
            .fill(.white.opacity(0.001))
            .frame(width: frame.width, height: frame.height)
            .rotationEffect(.degrees(overlay.rotationDegrees))
            .position(x: frame.midX, y: frame.midY)
            // 数字元件没有"打字"这一步，内容全在检查器里调 ——
            // 给它弹一个输入框只会让人对着一个不显示的 `text` 字段瞎改。
            .onTapGesture(count: 2) {
                guard overlay.number == nil else { return }
                project.textEditingRequest = overlay.id
            }
            .onTapGesture {
                let flags = NSEvent.modifierFlags
                project.selectText(
                    overlay.id,
                    additive: flags.contains(.command) || flags.contains(.shift)
                )
            }
            .gesture(moveGesture(overlay, frameSize: frame.size))
    }

    private func moveGesture(_ overlay: TextOverlay, frameSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(TextFrameBox.space))
            .onChanged { value in
                if dragOrigin == nil {
                    dragOrigin = CGPoint(
                        x: overlay.centerX * boxSize.width,
                        y: overlay.centerY * boxSize.height
                    )
                    project.selectText(overlay.id, additive: false)
                    project.beginLiveEdit()
                }
                guard let origin = dragOrigin else { return }
                let moved = TextFrameBox.movedCenter(
                    from: origin, translation: value.translation,
                    frameSize: frameSize, canvas: boxSize
                )
                centerGuides = moved.guides
                project.liveUpdateTextOverlay(overlay.id) {
                    $0.centerX = moved.center.x / max(boxSize.width, 1)
                    $0.centerY = moved.center.y / max(boxSize.height, 1)
                }
            }
            .onEnded { _ in
                dragOrigin = nil
                centerGuides = (false, false)
                project.endLiveEdit(rebuildsPreview: false)
            }
    }

    // MARK: - 选中框

    private func frameBox(for overlay: TextOverlay) -> some View {
        TextFrameBox(
            frame: TextRenderer.layoutFrame(overlay, canvas: boxSize),
            rotationDegrees: overlay.rotationDegrees,
            canvas: boxSize,
            onScale: { factor in
                project.beginLiveEdit()
                if scaleBaseFontSize == nil { scaleBaseFontSize = overlay.style.fontSize }
                guard let base = scaleBaseFontSize else { return }
                project.liveUpdateTextOverlay(overlay.id) { $0.style.fontSize = base * factor }
            },
            onResizeWidth: { width in
                project.beginLiveEdit()
                project.liveUpdateTextOverlay(overlay.id) { $0.boxWidth = width }
            },
            onRotate: { degrees in
                project.beginLiveEdit()
                project.liveUpdateTextOverlay(overlay.id) { $0.rotationDegrees = degrees }
            },
            onEnd: {
                scaleBaseFontSize = nil
                project.endLiveEdit(rebuildsPreview: false)
            }
        )
    }

    // MARK: - 就地编辑

    /// 输入框浮在文字块**下方**（贴着底边），与预览里改字幕同一个位置约定 ——
    /// 浮在上面会挡住正在编辑的那行字。
    private func editor(for overlay: TextOverlay) -> some View {
        let frame = TextRenderer.layoutFrame(overlay, canvas: boxSize)
        return TextInlineEditor(project: project, overlayID: overlay.id)
            .frame(width: min(max(240, frame.width), boxSize.width - 16))
            .position(
                x: min(max(frame.midX, 130), boxSize.width - 130),
                y: min(frame.maxY + 46, boxSize.height - 40)
            )
    }
}
