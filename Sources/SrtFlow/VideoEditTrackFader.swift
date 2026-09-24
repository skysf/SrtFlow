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
    /// 电平表从哪儿读（nil = 这一格不画电平条）。
    var meter: TrackMeterSource?

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
        let _ = PerfCounters.body(Self.self)
        GeometryReader { proxy in
            let width = Double(proxy.size.width)
            let decibels = drag?.liveDecibels ?? AudioGain.decibels(fromLinear: value)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.black.opacity(0.45))
                    .frame(height: 6)
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                if let meter {
                    TrackMeterBars(source: meter, clock: meter.clock, width: width)
                        .frame(width: width, height: 6)
                }
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

// MARK: - 电平条（画在推子的槽里）

/// 电平表从哪儿读：引擎、哪一条、播放时钟。
struct TrackMeterSource {
    let engine: AudioMeterEngine
    let key: MeterKey
    let clock: PlayerClock
}

/// 推子槽里的立体声电平条（上 L 下 R），与推子**同一把刻度**（旋钮在 −6 dB 时，
/// −6 dB 的电平正好顶到旋钮下面）。绿 → 黄（−12 dB 起）→ 红（过 0 dBFS）；
/// 一道细线是峰值保持；过过 0 dBFS 的话槽的 0 dB 以上那一截一直红着，下一次开播才熄。
///
/// 只在播放时按 30 帧/秒去读（`TimelineView` 停播即停），停播时电平条收起、红灯留着。
struct TrackMeterBars: View {
    let source: TrackMeterSource
    @ObservedObject var clock: PlayerClock
    let width: Double

    static let green = Color(red: 0.25, green: 0.85, blue: 0.35)
    static let yellow = Color(red: 0.98, green: 0.82, blue: 0.2)
    static let red = Color(red: 1, green: 0.27, blue: 0.23)

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !clock.isPlaying)) { timeline in
            let reading = clock.isPlaying
                ? source.engine.reading(
                    for: source.key, at: clock.player.currentTime().seconds,
                    now: timeline.date.timeIntervalSinceReferenceDate
                )
                : MeterReading(left: AudioGain.minimumDB, right: AudioGain.minimumDB,
                               hold: AudioGain.minimumDB, clipped: source.engine.isClipped(source.key))
            Canvas { context, size in
                PerfCounters.canvas(Self.self)
                draw(reading, in: &context, size: size)
            }
        }
        // 红灯是「这一遍播下来爆没爆」：开播就熄掉上一遍的（总表那一条负责喊一声就够）。
        .onChange(of: clock.isPlaying) { _, playing in
            if playing, source.key == .master { source.engine.clearClips() }
        }
        .allowsHitTesting(false)
    }

    private func draw(_ reading: MeterReading, in context: inout GraphicsContext, size: CGSize) {
        let height = Double(size.height)
        let x0 = TrackFaderView.x(forDecibels: AudioGain.minimumDB, width: width)
        let yellowX = TrackFaderView.x(forDecibels: -12, width: width)
        let zeroX = TrackFaderView.x(forDecibels: 0, width: width)
        let endX = TrackFaderView.x(forDecibels: AudioGain.maximumDB, width: width)

        if reading.clipped {
            let over = CGRect(x: zeroX, y: 0, width: max(0, endX - zeroX + TrackFaderView.knob / 2), height: height)
            context.fill(Path(roundedRect: over, cornerRadius: height / 2), with: .color(Self.red.opacity(0.9)))
        }
        for (index, level) in [reading.left, reading.right].enumerated() where level > AudioGain.minimumDB + 0.5 {
            let top = 1 + Double(index) * (height - 2) / 2
            let barHeight = (height - 2) / 2 - 0.4
            let levelX = TrackFaderView.x(forDecibels: level, width: width)
            let pieces: [(from: Double, to: Double, color: Color)] = [
                (x0, min(levelX, yellowX), Self.green),
                (yellowX, min(levelX, zeroX), Self.yellow),
                (zeroX, levelX, Self.red),
            ]
            for piece in pieces where piece.to > piece.from {
                context.fill(Path(CGRect(x: piece.from, y: top, width: piece.to - piece.from, height: barHeight)),
                             with: .color(piece.color))
            }
        }
        if reading.hold > AudioGain.minimumDB + 0.5 {
            let holdX = TrackFaderView.x(forDecibels: reading.hold, width: width)
            context.fill(Path(CGRect(x: holdX - 0.5, y: 0.5, width: 1, height: height - 1)),
                         with: .color(reading.hold > 0 ? Self.red : .white.opacity(0.85)))
        }
    }
}
