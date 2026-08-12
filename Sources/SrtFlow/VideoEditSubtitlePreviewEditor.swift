import AppKit
import SwiftUI
import SrtFlowCore

/// 预览画面上的字幕交互层：**单击选中这句、双击就地改字**（2026-08-12 用户拍板
/// 的形态 —— 输入框浮在字幕下方，画面本身的渲染不变，不假装所见即所得）。
///
/// 铺在字幕叠层之上、布局拖框之下：
/// - 在拖框**下面**，是因为拖框的框体要能拖动移动字幕，热区盖上去会把它废掉；
///   拖框盖住的那块由 `SubtitleFrameCanvas.onDoubleClick` 补上同一条路。
/// - 热区只盖字幕块本身（`SubtitleFrameGeometry` 算出来的那个矩形），别处的
///   单击照旧归画面点选（`ClipTransformCanvas`）。
///
/// 编辑哪条轨跟着眼睛走（隐藏 = 不可编辑），实际写入走
/// `SubtitleInlineEditor` 里的合同入口。
struct SubtitlePreviewEditLayer: View {
    @ObservedObject var project: VideoEditProject
    @ObservedObject var clock: PlayerClock
    let boxSize: CGSize
    let style: BurnInStyle
    /// 当前字幕文本块的实测高度（`BurnInSubtitleOverlay` 回报）。
    let blockHeight: Double
    @Binding var editingCueID: UUID?

    /// 输入框实测尺寸：决定它摆得下摆不下（摆不下就翻到字幕上方）。
    @State private var editorSize: CGSize = .zero

    /// 输入框与字幕块之间的空档。留够 14pt 是为了不和拖框的角把手（9pt 见方、
    /// 命中区再外扩 5pt）叠在一起 —— 叠上了就会出现「点输入框却抓到把手」。
    private static let gap: Double = 14

    private var geometry: SubtitleFrameGeometry {
        SubtitleFrameGeometry(
            boxSize: boxSize,
            style: style,
            layout: project.state.subtitleLayout,
            blockHeight: blockHeight
        )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            hotspot
            if let editingCueID, let cue = cue(editingCueID) {
                editor(for: cue)
            }
        }
        .frame(width: boxSize.width, height: boxSize.height, alignment: .topLeading)
        // 播放头挪出这条字幕（或字幕整个消失）时，浮层不许留在画面上对着
        // 另一句字幕 —— 关掉即提交（`SubtitleInlineEditor.onDisappear`）。
        .onChange(of: clock.displayTime) { _, _ in
            guard let editingCueID else { return }
            if !activeCues.contains(where: { $0.id == editingCueID }) { self.editingCueID = nil }
        }
        .onDisappear { editingCueID = nil }
    }

    private var hotspot: some View {
        let rect = geometry.frameRect
        return Color.clear
            .frame(width: rect.width, height: rect.height)
            .contentShape(Rectangle())
            // 单击/双击用 clickCount 分流：两个 TapGesture 并存会互相抢，
            // 单击要等系统确认「不是双击」才触发，选中就会慢半拍
            //（ScreenRecordingRegionPanel 也是这么认双击的）。
            .onTapGesture { handleTap() }
            .offset(x: rect.minX, y: rect.minY)
    }

    private func editor(for cue: SubtitleCue) -> some View {
        SubtitleInlineEditor(
            project: project,
            cueID: cue.id,
            editsOriginal: !project.state.subtitleHidden,
            editsTranslation: project.state.hasVisibleTranslation,
            onDone: { editingCueID = nil }
        )
        .padding(10)
        .frame(width: editorWidth)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: InlineEditorSizeKey.self, value: proxy.size)
            }
        }
        .onPreferenceChange(InlineEditorSizeKey.self) { editorSize = $0 }
        .offset(x: editorOrigin.x, y: editorOrigin.y)
    }

    /// 输入框宽度：贴着字幕块的宽度，但**先服从画面框**。
    /// 竖版素材或窄窗口下画面框可以窄到一百多点，钉一个下限就会被
    /// 画面框的 `clipShape` 裁掉半个输入框（复审 P2）。所以下限也让位：
    /// 画面框放不下 220 就按画面框来。
    private var editorWidth: Double {
        let available = max(boxSize.width - 16, 80)
        return min(max(geometry.frameRect.width, min(220, available)), available)
    }

    /// 摆在字幕块下面；下面塞不下（字幕本来就贴着画面底部时的常态）就翻到上面，
    /// 再不济也钳在画面里 —— 输入框跑到画面外等于没法编辑。
    private var editorOrigin: CGPoint {
        let rect = geometry.frameRect
        let size = editorSize.height > 1 ? editorSize : CGSize(width: editorWidth, height: 96)
        let maxX = max(boxSize.width - size.width - 8, 8)
        let x = min(max(rect.midX - size.width / 2, 8), maxX)
        let below = rect.maxY + Self.gap
        let above = rect.minY - Self.gap - size.height
        let y: Double
        if below + size.height + 8 <= boxSize.height {
            y = below
        } else if above >= 8 {
            y = above
        } else {
            y = max(min(boxSize.height - size.height - 8, below), 8)
        }
        return CGPoint(x: x, y: y)
    }

    /// 此刻画面上有哪几条 cue。判据用**原文轨**：译文是原文的镜像（同 ID、同
    /// 时间），只显示译文时选中/编辑的仍然是同一条 cue。
    private var activeCues: [SubtitleCue] {
        guard let doc = project.state.subtitle else { return [] }
        return SubtitleOverlap.active(at: clock.displayTime, in: doc.cues)
    }

    private func cue(_ id: UUID) -> SubtitleCue? {
        project.state.subtitle?.cues.first { $0.id == id }
    }

    /// 点中的是哪条：已经选中的那条优先（用户刚在轨道上点过它），否则取合同序
    /// 最后一条 —— 叠层把它画在最上面一行，也就是眼睛看见的那句。
    private var targetCue: SubtitleCue? {
        let active = activeCues
        if let selected = project.selectedSubtitleCueID,
           let hit = active.first(where: { $0.id == selected }) {
            return hit
        }
        return active.last
    }

    private func handleTap() {
        guard let target = targetCue else { return }
        project.selectSubtitleCue(target.id)
        guard (NSApp.currentEvent?.clickCount ?? 1) >= 2 else { return }
        // 边播边打字的话，画面和字幕都会从手底下跑掉 —— 进编辑就停下。
        if clock.isPlaying { clock.togglePlayback() }
        editingCueID = target.id
    }
}

private struct InlineEditorSizeKey: PreferenceKey {
    static let defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}
