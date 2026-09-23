import AppKit
import SwiftUI

// MARK: - 块上的音量线（Final Cut 式：常显，贴着线操作）
//
// 2026-09-23 起：音频块（以及视频块底部的波形带）上一直画着一条音量线。
//
// - 靠近线光标变 ↕；拖线 = 这一段上下（两点之间动两端，线头线尾只动端点，没有点
//   就是整段的 `volume`）；拖点 = 改它的时间和值（按住 ⇧ 只改值）。
// - ⌥ 点线加一个点（取线上此刻的值 —— 加点本身不改声音）；⌥ 点点删掉它。
// - 线以外的地方，拖动 / 裁切 / 框选 / 点选全都和以前一样：命中区**只是贴着线的一条
//   窄带**加每个点的小圆（`VolumeLineHitShape`），不是整块。
// - **拖动中不写 `TimelineState`**（时间线拖动 §0）：线画在哪只由本视图的
//   `session` 决定，声音靠 `previewAudioLive` 临时换 audioMix 当场听得见；松手才
//   `commitVolumeEdit` 落一次（一步撤销、快路径不闪画面）。
//
// 编辑规则与纵轴几何是纯值（VideoEditVolumeCurve.swift），合同见
// docs/architecture/audio-volume-curve.md。

struct VolumeCurveOverlay: View {
    let clip: EditClip
    let pps: Double
    @ObservedObject var project: VideoEditProject

    @State private var session: Session?
    @State private var hovering = false
    /// 手势还活着吗。手势被打断（模态框、窗口失活）时 `onEnded` 不会来，靠它收尾。
    @GestureState private var gestureActive = false

    /// 一轮按下：起手时的段（手势永远从它算，不在上一拍上叠加）、此刻的结果、拖的是什么。
    private struct Session {
        enum Target {
            case point(Int)
            case segment([Int])
        }
        var origin: EditClip
        var edited: EditClip
        var target: Target
        /// 按下的位置与那一刻线上的值（拖一段线用）。
        var start: CGPoint
        var startDecibels: Double
        /// 挪够 2pt 才算拖，不然松手当成一次点击。
        var isDragging = false
        var location: CGPoint
        var labelDecibels: Double
    }

    /// 此刻该画的那一份：拖动中是手势算出来的结果，平时是模型里的段。
    private var displayed: EditClip { session?.edited ?? clip }

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            if height >= VolumeCurveLayout.minimumHeight {
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        draw(in: &context, size: size)
                    }
                    .allowsHitTesting(false)

                    Color.clear
                        .contentShape(VolumeLineHitShape(
                            vertices: VolumeCurveLayout.vertices(for: displayed, pps: pps, height: height),
                            handles: VolumeCurveLayout.handles(for: displayed, pps: pps, height: height).map(\.point)
                        ))
                        .gesture(gesture(height: height))
                        .onChange(of: gestureActive) { _, active in
                            guard !active else { return }
                            // 正常松手时 onEnded 已经收过尾；等一拍再看，还挂着就是被打断了：
                            // 预览里那份临时 mix 换回真状态的，别让「听到的」和模型对不上。
                            DispatchQueue.main.async {
                                guard session != nil else { return }
                                session = nil
                                project.isDraggingVolume = false
                                project.refreshAudioMix()
                            }
                        }
                        .onHover { hovering = $0 }
                        .pointerStyle(.rowResize)
                        .instantHelp("Drag to change the volume. ⌥-click the line to add a point, ⌥-click a point to remove it.")
                        // 刀片模式下整条让路：点在线上也该落下那一刀。
                        .allowsHitTesting(project.activeTool == .select)

                    if let session, session.isDragging {
                        valueLabel(session)
                    }
                }
            }
        }
    }

    // MARK: 画

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let height = Double(size.height)
        let visible = context.clipBoundingRect
        let vertices = VolumeCurveLayout.vertices(for: displayed, pps: pps, height: height)
        guard vertices.count >= 2 else { return }
        // 只取看得见的那一段折线（块能有几百万点宽，同波形那条约束）。
        let first = max(0, (vertices.lastIndex { $0.x <= visible.minX } ?? 0))
        let last = min(vertices.count - 1, vertices.firstIndex { $0.x >= visible.maxX } ?? vertices.count - 1)
        guard last > first else { return }
        var line = Path()
        line.addLines(Array(vertices[first...last]))
        let emphasised = hovering || session != nil
        let dim = clip.isMuted ? 0.4 : 1.0
        context.stroke(line, with: .color(.black.opacity(0.45 * dim)), lineWidth: emphasised ? 3.5 : 2.75)
        context.stroke(line, with: .color(Self.lineColor.opacity(dim)), lineWidth: emphasised ? 2 : 1.25)

        for handle in VolumeCurveLayout.handles(for: displayed, pps: pps, height: height)
        where handle.point.x >= visible.minX - 8 && handle.point.x <= visible.maxX + 8 {
            let rect = CGRect(x: handle.point.x - 3.5, y: handle.point.y - 3.5, width: 7, height: 7)
            context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(dim)))
            context.stroke(Path(ellipseIn: rect), with: .color(Self.lineColor.opacity(dim)), lineWidth: 1.5)
        }
    }

    static let lineColor = Color(red: 1, green: 0.82, blue: 0.3)

    private func valueLabel(_ session: Session) -> some View {
        Text(verbatim: Self.label(forDecibels: session.labelDecibels))
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.black.opacity(0.75), in: Capsule())
            .fixedSize()
            .offset(x: session.location.x + 10, y: max(0, session.location.y - 20))
            .allowsHitTesting(false)
    }

    /// 标签：−60 dB 以下写 −∞（同检查器）。
    static func label(forDecibels decibels: Double) -> String {
        AudioGain.label(forLinear: AudioGain.linear(fromDecibels: decibels))
    }

    // MARK: 手势

    private func timelineTime(atX x: Double) -> Double {
        clip.timelineStart + min(max(0, x), clip.timelineDuration * pps) / pps
    }

    /// 一个手势管三件事：拖（线或点）、⌥ 点（加点 / 删点）、普通点击（选中这一段，
    /// 同块本体的点击）。`minimumDistance: 0` 让它从按下那一刻就接管 —— 靠「子手势
    /// 失败了再落到父级」去分流，点击和拖动的归属就说不清了。
    private func gesture(height: Double) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($gestureActive) { _, active, _ in active = true }
            .onChanged { value in
                if session == nil { begin(at: value.startLocation, height: height) }
                guard var current = session else { return }
                let moved = hypot(value.translation.width, value.translation.height)
                if !current.isDragging {
                    guard moved >= 2 else { return }
                    current.isDragging = true
                    project.isDraggingVolume = true
                    project.clock.endPeek()
                }
                update(&current, location: value.location, height: height)
                session = current
                let edited = current.edited
                project.previewAudioLive { state in
                    state.update(edited.id) { clip in
                        clip.volume = edited.volume
                        clip.volumeCurve = edited.volumeCurve
                    }
                }
            }
            .onEnded { value in
                defer {
                    session = nil
                    project.isDraggingVolume = false
                }
                guard let current = session else { return }
                if current.isDragging {
                    project.commitVolumeEdit(clip.id, edited: current.edited)
                } else {
                    click(at: value.location, height: height)
                }
            }
    }

    private func begin(at location: CGPoint, height: Double) {
        let origin = project.state.clip(with: clip.id) ?? clip
        let time = timelineTime(atX: location.x)
        let target: Session.Target
        if let index = VolumeCurveLayout.handle(at: location, clip: origin, pps: pps, height: height) {
            target = .point(index)
        } else {
            target = .segment(origin.volumeSegmentIndices(atTimeline: time))
        }
        let startDecibels = origin.volumeLineDecibels(atTimeline: time)
        session = Session(
            origin: origin, edited: origin, target: target, start: location,
            startDecibels: startDecibels, location: location, labelDecibels: startDecibels
        )
    }

    private func update(_ session: inout Session, location: CGPoint, height: Double) {
        var edited = session.origin
        switch session.target {
        case .point(let index):
            guard session.origin.volumeCurve.keys.indices.contains(index) else { return }
            // 跟着指针挪同样的量，不是瞬移到指针底下（偏着抓一个点时不跳）。
            // ⇧：只改值，时间钉在原处（精细地压一个点时手一抖就横着跑了）。
            edited = VolumeCurveLayout.dragging(
                session.origin, point: index,
                by: CGSize(width: location.x - session.start.x, height: location.y - session.start.y),
                pps: pps, height: height, lockTime: NSEvent.modifierFlags.contains(.shift)
            )
            session.labelDecibels = edited.volumeCurve.keys[index].value
        case .segment(let indices):
            // 纵轴是 dB 线性的：指针挪多少点，就是多少 dB。
            let span = AudioGain.maximumDB - AudioGain.minimumDB
            let delta = (session.start.y - location.y) / max(1, height - 2 * VolumeCurveLayout.inset) * span
            edited.shiftVolume(indices: indices, byDecibels: delta)
            session.labelDecibels = AudioGain.clampedDecibels(session.startDecibels + delta)
        }
        session.edited = edited
        session.location = location
    }

    /// 没挪动的一下：⌥ 点 = 加点 / 删点；普通点击 = 选中这一段（同块本体）。
    private func click(at location: CGPoint, height: Double) {
        let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        guard flags.contains(.option) else {
            project.select(clip.id, additive: flags.contains(.command) || flags.contains(.shift))
            return
        }
        let current = project.state.clip(with: clip.id) ?? clip
        if let index = VolumeCurveLayout.handle(at: location, clip: current, pps: pps, height: height) {
            project.removeVolumePoint(clip.id, at: index)
        } else {
            project.addVolumePoint(clip.id, atTimeline: timelineTime(atX: location.x))
        }
    }
}

/// 音量线的命中区：贴着线的一条窄带 + 每个点的小圆。**不是整块** —— 线以外的地方
/// 拖动 / 裁切 / 框选 / 点选必须原样归块和容器。
struct VolumeLineHitShape: Shape {
    let vertices: [CGPoint]
    let handles: [CGPoint]

    /// 窄带与小圆必须**并**起来（`VolumeCurveLayout.hitPath`），不能 append：
    /// 重叠处环绕数互相抵消，点的正中间会点不中（2026-09-23 案例）。
    func path(in rect: CGRect) -> Path {
        Path(VolumeCurveLayout.hitPath(vertices: vertices, handles: handles))
    }
}
