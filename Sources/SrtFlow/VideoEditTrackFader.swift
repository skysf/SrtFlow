import AppKit
import SwiftUI

// MARK: - 轨道头的推子（Logic 轨道头那一条）
//
// 2026-09-23 起每条能出声的轨（主轨、上层视频轨、音频轨）在轨道头有一个横向推子，
// 最上面的标尺行放总推子。刻度是 dB 线性的 −∞…+6 dB（`AudioGain.scaleFraction`，与
// 检查器滑杆、块上的音量线同一把尺）。
//
// - 拖 = 相对拖（不跳到指针处）；按住 ⇧ 细调（五分之一的速度）。
// - ⌥ 点 / 双击 = 回到 0 dB。
// - **拖动中不写 `TimelineState`**：推子的位置是视图状态，声音靠 `previewAudioLive`
//   当场听得见；松手才落一次（一步撤销、快路径不闪画面）。同音量线那一套。
// - 电平条画在推子的槽里（`meter`，由电平表那一层喂）。
//
// 合同见 docs/architecture/audio-mixer.md。

struct TrackFaderView: View {
    /// 存下来的值（线性 0…2，1 = 0 dB）。
    let value: Double
    /// 总推子还是轨道推子（只影响提示文案）。
    let isMaster: Bool
    /// 轨藏起来了：推子照样能调，只是灰一点（那条轨此刻不出声）。
    let isDimmed: Bool
    /// 拖动中每一拍（线性值）：调用方拿它做「当场听得见」，不许写 state。
    let onLive: (Double) -> Void
    /// 松手 / ⌥ 点 / 双击：落一次。
    let onCommit: (Double) -> Void

    @State private var drag: DragState?
    @State private var lastClick: Date?

    private struct DragState: Equatable {
        var startDecibels: Double
        var liveDecibels: Double
        var moved = false
    }

    /// 旋钮的直径，也是槽两头留的余量（旋钮不许画出推子）。
    static let knob = 10.0

    var body: some View {
        GeometryReader { proxy in
            let width = Double(proxy.size.width)
            let decibels = drag?.liveDecibels ?? AudioGain.decibels(fromLinear: value)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.black.opacity(0.45))
                    .frame(height: 6)
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                // 0 dB 的刻度：一眼看出推子在不在原样。
                Rectangle()
                    .fill(.white.opacity(0.35))
                    .frame(width: 1, height: 9)
                    .offset(x: Self.x(forDecibels: 0, width: width) - 0.5)
                Circle()
                    .fill(Color(white: 0.92))
                    .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 0.5))
                    .frame(width: Self.knob, height: Self.knob)
                    .shadow(color: .black.opacity(0.4), radius: 1, y: 0.5)
                    .offset(x: Self.x(forDecibels: decibels, width: width) - Self.knob / 2)
                if drag?.moved == true {
                    Text(verbatim: AudioGain.label(forLinear: AudioGain.linear(fromDecibels: decibels)))
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .background(.black.opacity(0.8), in: Capsule())
                        .fixedSize()
                        .offset(x: max(0, min(width - 44, Self.x(forDecibels: decibels, width: width) - 22)), y: -11)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: width, height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(gesture(width: width))
        }
        .opacity(isDimmed ? 0.45 : 1)
        // 轨道头那一行的「上下拖 = 调行高」光标不该盖到推子上。
        .pointerStyle(.default)
        .instantHelp(isMaster
                     ? "Master volume. Drag to adjust (⇧ for fine steps); ⌥-click or double-click for 0 dB."
                     : "Track volume. Drag to adjust (⇧ for fine steps); ⌥-click or double-click for 0 dB.")
    }

    /// dB → 槽里的 x（两头各留半个旋钮）。
    static func x(forDecibels decibels: Double, width: Double) -> Double {
        knob / 2 + AudioGain.scaleFraction(forDecibels: decibels) * max(1, width - knob)
    }

    private func gesture(width: Double) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                var state = drag ?? DragState(
                    startDecibels: AudioGain.decibels(fromLinear: self.value),
                    liveDecibels: AudioGain.decibels(fromLinear: self.value)
                )
                if abs(value.translation.width) >= 1 { state.moved = true }
                guard state.moved else { drag = state; return }
                // 相对拖：槽的全长 = 整个 dB 区间；⇧ 细调。
                let fine = NSEvent.modifierFlags.contains(.shift) ? 0.2 : 1
                let span = AudioGain.maximumDB - AudioGain.minimumDB
                let delta = value.translation.width / max(1, width - Self.knob) * span * fine
                state.liveDecibels = AudioGain.clampedDecibels(state.startDecibels + delta)
                drag = state
                onLive(AudioGain.linear(fromDecibels: state.liveDecibels))
            }
            .onEnded { _ in
                defer { drag = nil }
                guard let state = drag else { return }
                if state.moved {
                    onCommit(AudioGain.linear(fromDecibels: state.liveDecibels))
                    return
                }
                // 没挪动的一下：⌥ 点或双击 = 回到 0 dB。
                let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
                let now = Date()
                if flags.contains(.option) || (lastClick.map { now.timeIntervalSince($0) < 0.35 } ?? false) {
                    lastClick = nil
                    onCommit(1)
                } else {
                    lastClick = now
                }
            }
    }
}
