import SwiftUI

// MARK: - 时间线上跟着播放头跳的东西
//
// 管什么：播放头的竖线、悬停预览的影子指针、播放时的跟随滚动。时间线的滚动内容里**只有它**
// 订阅播放器时钟（标尺上的把手是另一个小视图 `TimelinePlayheadHandle`，钉在标尺里）。
// 不管什么：播放头被挪到哪儿 —— 点标尺、点空白、扫帧的入口都在 `VideoEditTimelineView`。
//
// 为什么单独拿出来（docs/architecture/preview-perf-ratchet.md 第十二节）：这几样以前写在时间线
// 本体里，时间线为了它们订阅着时钟，播放时每 0.05 秒一跳，整条时间线（每一行、ForEach 的 diff、
// 拖动覆盖层）跟着重算一遍（docs/bugfixes/2026-09-25-playback-wakes-whole-editor.md）。

/// 播放头的竖线 + 悬停预览的影子指针；播放时让播放头留在视野里。
///
/// body 直接给出两根线、不包 ZStack：它们和以前一样是时间线滚动内容那个 ZStack 的孩子，
/// `.frame(maxHeight: .infinity)` 撑的是那个 ZStack 的高度（2026-09-20 修断线那次的同一件事）。
struct TimelinePlayheadLines: View {
    @ObservedObject var clock: PlayerClock
    let pps: Double
    /// 可见视口的宽度（跟随滚动判「快滚出去了」）。
    let viewportWidth: Double
    /// 推横向滚动的唯一入口（§5b）。持有不订阅：滚动时这两根线不用跟着重算。
    let geometry: TimelineScrollGeometry
    /// 播放跟随滚动的节流。
    @State private var lastFollowTime: Double = -1

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        // 悬停预览的影子指针：半透明细线、没有把手 —— 只说明「画面此刻在看这儿」。
        // 真播放头（白色实线 + 把手）留在用户点定的位置，点击才会把它移过来。
        if let peek = clock.peekTime {
            Rectangle()
                .fill(.white.opacity(0.5))
                .frame(width: 1)
                .frame(maxHeight: .infinity, alignment: .top)
                .offset(x: peek * pps - 0.5)
                .allowsHitTesting(false)
        }
        // 播放头的**竖线**，贯穿所有轨道，跟着内容一起纵向滚。把手不在这儿：它画在
        // `TimelinePinnedRuler` 里、跟着标尺钉在视口顶上 —— 标尺不透明，画在这里的话
        // 纵向滚下去之后把手会藏到标尺后面，用户就看不见播放头的抓手了。
        Rectangle()
            .fill(.white)
            .frame(width: 1.5)
            .shadow(radius: 0.5)
            .frame(maxHeight: .infinity, alignment: .top)
            .offset(x: clock.time * pps - 0.75)
            .allowsHitTesting(false)
            .onChange(of: clock.time) { _, newTime in
                followPlayhead(newTime)
            }
    }

    /// 播放时让播放头留在视野里：只有它快滚出去了才动一下，
    /// 平时不跟着走 —— 每帧都居中会看得人晕。
    ///
    /// **只碰横向。** 以前走 `ScrollViewProxy.scrollTo(_:anchor:)`，那个锚点是
    /// 双轴的：时间线能上下滚之后（2026-09-18），正在看下面几条轨时一按播放，
    /// 画面会被连带拽回最顶上。
    private func followPlayhead(_ time: Double) {
        guard clock.isPlaying, viewportWidth > 80 else { return }
        guard abs(time - lastFollowTime) > 0.15 else { return }
        lastFollowTime = time

        let x = time * pps
        let offset = geometry.offsetX
        let leftEdge = offset + 40
        let rightEdge = offset + viewportWidth - 80
        guard x < leftEdge || x > rightEdge else { return }
        // 挪到视野偏左的位置，后面还留着一大段能看。
        geometry.scrollHorizontally(to: x - viewportWidth * 0.15, animated: true)
    }
}
