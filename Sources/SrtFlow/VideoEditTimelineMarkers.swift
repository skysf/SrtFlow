import SwiftUI

// 轨道块上标记的画法与交互。数据模型在 VideoEditClipMarker.swift，
// 长期约束见 docs/architecture/clip-markers.md。

extension MarkerColor {
    /// 用系统语义色，不写死 RGB：深色/浅色外观、增强对比度都由系统跟着变。
    var swiftUIColor: Color {
        switch self {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        }
    }

    var title: String {
        switch self {
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        case .purple: return "Purple"
        }
    }
}

/// 一段素材上的全部标记。挂在剪辑块的 overlay 上。
///
/// **命中区只有顶上那顶小帽子**，底下那道竖线一律 `allowsHitTesting(false)`。
/// 这是刻意的：标记如果整条竖着吃事件，一段素材上打几枚标记就等于在块上凿出
/// 几道拖不动的死缝 —— 从那儿按下去既拖不走整段，也扫不了帧。
struct ClipMarkerStrip: View {
    let clip: EditClip
    let width: Double
    let height: Double
    let pps: Double
    @ObservedObject var project: VideoEditProject
    /// 指针进出标记时报一声（带上标记所在的时间线时刻）。块拿它接管扫帧 peek，
    /// 见 `ClipBlockView.markerHover`。
    let onHoverMarker: (Double?) -> Void

    /// 正开着编辑气泡的那枚（换色 / 写文字 / 删除）。
    @State private var editing: UUID?
    /// 指针正悬着的那枚（显示备注气泡）。
    @State private var hovered: UUID?

    private let capSize: Double = 9
    /// 命中区比帽子大一圈，不然 9pt 的目标太难点。
    private let hitWidth: Double = 14

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(clip.visibleMarkers) { marker in
                pin(marker)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }

    private func ref(_ marker: ClipMarker) -> ClipMarkerRef {
        ClipMarkerRef(clipID: clip.id, markerID: marker.id)
    }

    @ViewBuilder
    private func pin(_ marker: ClipMarker) -> some View {
        let x = (clip.timelineTime(of: marker) - clip.timelineStart) * pps
        let isSelected = project.selectedMarkerRef == ref(marker)
        ZStack(alignment: .top) {
            // 竖线：块缩得再矮也一眼看出标的是哪一帧。不吃事件。
            Rectangle()
                .fill(marker.color.swiftUIColor.opacity(0.85))
                .frame(width: 1.5, height: height)
                .shadow(color: .black.opacity(0.55), radius: 0.7)
                .allowsHitTesting(false)
            cap(marker, isSelected: isSelected)
        }
        .frame(width: hitWidth, height: height, alignment: .top)
        .overlay(alignment: .top) { bubble(marker) }
        .offset(x: x - hitWidth / 2)
        // 帽子之外的区域必须让路：`.contentShape` 只画在帽子上（见 cap）。
        .zIndex(hovered == marker.id || editing == marker.id ? 2 : 1)
    }

    private func cap(_ marker: ClipMarker, isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(marker.color.swiftUIColor)
            .overlay {
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(isSelected ? .white : .black.opacity(0.45), lineWidth: isSelected ? 1.5 : 0.5)
            }
            // 有备注的标记加一个白点，不用把鼠标一枚枚试过去才知道哪枚写了字。
            .overlay {
                if marker.hasText {
                    Circle()
                        .fill(.white.opacity(0.95))
                        .frame(width: 3, height: 3)
                }
            }
            .frame(width: capSize, height: capSize)
            .frame(width: hitWidth, height: hitWidth)
            .contentShape(Rectangle())
            .onTapGesture {
                project.selectedMarkerRef = ref(marker)
                editing = marker.id
            }
            .onHover { inside in
                if inside {
                    hovered = marker.id
                    onHoverMarker(clip.timelineTime(of: marker))
                } else if hovered == marker.id {
                    hovered = nil
                    onHoverMarker(nil)
                }
            }
            .popover(
                isPresented: Binding(
                    get: { editing == marker.id },
                    set: { if !$0, editing == marker.id { editing = nil } }
                ),
                arrowEdge: .bottom
            ) {
                ClipMarkerEditor(
                    marker: marker,
                    onColor: { project.setMarkerColor(ref(marker), $0) },
                    onText: { project.setMarkerText(ref(marker), $0) },
                    onDelete: {
                        editing = nil
                        project.deleteMarker(ref(marker))
                    }
                )
            }
    }

    /// 备注气泡：指针一进帽子就出现，一离开就没，没有系统 tooltip 那一秒延迟。
    ///
    /// 画在帽子**下方**而不是上方 —— 上方会被轨道行的上边界切掉半截。
    /// `fixedSize` 让它按文字的自然宽度铺开（可以盖到邻块上），
    /// `allowsHitTesting(false)` 保证它自己永远不会把指针从帽子上抢走
    ///（抢走就会立刻触发 onHover(false)，气泡开始闪烁）。
    @ViewBuilder
    private func bubble(_ marker: ClipMarker) -> some View {
        if hovered == marker.id, editing != marker.id, marker.hasText {
            Text(marker.text)
                .font(.system(size: 10))
                .foregroundStyle(.white)
                .lineLimit(3)
                .frame(maxWidth: 220, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 4))
                .fixedSize(horizontal: false, vertical: true)
                .offset(y: capSize + 5)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }
}

/// 点开标记后的小面板：换色、写备注、删除。
private struct ClipMarkerEditor: View {
    let marker: ClipMarker
    let onColor: (MarkerColor) -> Void
    let onText: (String) -> Void
    let onDelete: () -> Void

    /// 编辑中的草稿。**收工时才提交**（回车、或者气泡关掉），中间值不进 state ——
    /// 每敲一个字提交一次的话，撤销栈会被一串单字符状态塞满。
    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(MarkerColor.allCases) { color in
                    Button {
                        onColor(color)
                    } label: {
                        Circle()
                            .fill(color.swiftUIColor)
                            .frame(width: 16, height: 16)
                            .overlay {
                                Circle().strokeBorder(
                                    color == marker.color ? Color.primary : .black.opacity(0.25),
                                    lineWidth: color == marker.color ? 2 : 0.5
                                )
                            }
                    }
                    .buttonStyle(.plain)
                    .help(color.title)
                }
            }

            TextField("Note", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .frame(width: 200)
                .onSubmit { onText(draft) }

            Divider()

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete Marker", systemImage: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
        }
        .padding(10)
        .onAppear { draft = marker.text }
        // 气泡被点外面关掉时也要落盘：只认回车的话，用户写完直接点开别处就白写了。
        .onDisappear { onText(draft) }
    }
}
