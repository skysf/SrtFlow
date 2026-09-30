import Foundation

// 时间线上所有「把播放头挪过去」的落点只有这一个入口：标尺的点 / 拖、点空白、点块本体
//（剪辑 / 文字 / 形状 / 滤镜 / 字幕句 / 转场遮罩）、刀片切完落到刀口、双击文字跳到它的起点。
//
// **夹紧只能有这一处**（2026-09-21）：两个调用点各写一份 `min(max(0, t), duration)` 迟早分叉 ——
// 标尺夹到片尾、点空白不夹的话，点右边那一大片空白就会把播放头送到工程之外：那里根本没有帧，
// 画面停在最后一帧而播放头在几十秒开外，工具栏上所有「播放头得落在片段内」才可用的按钮
//（分割、冻结、标记、删左、删右）随即全部变灰，看起来像是工具栏也坏了。
//
// 以前它是 `VideoEditTimelineView` 的方法。2026-09-30 用户拍板点块本体也要移播放头，而块只持有
// `project`、不订阅（docs/architecture/preview-perf-ratchet.md「时间线上的块」），入口就搬到了工程上。
// 纯值那一半（夹紧、块内落点）在 `TimelineSeek`（VideoEditTimelineSeek.swift），自检能单独编。
// 合同：docs/architecture/timeline-drag-gestures.md §5f；守卫：checks/timeline-drag-wiring/playhead-click.sh。
@MainActor
extension VideoEditProject {

    /// 把播放头挪到时间线上的这一刻（夹进 [0, 总长]）。
    /// - Parameter precise: 点一下给 `true`；拖标尺扫过的过程中给 `false`（链式 seek 防洪，见 `PlayerClock.seek`）。
    func seekFromTimeline(time: Double, precise: Bool = true) {
        clock.seek(to: TimelineSeek.clamped(time, duration: duration), precise: precise)
    }

    /// 点在一块上：播放头落到指针底下那一刻，但不出这一块（`TimelineSeek.timeInBlock`，最右是它的最后一帧）。
    ///
    /// `x` 是指针在块**自己**坐标系里的横坐标（`onTapGesture(coordinateSpace: .local)`）。读它的那个
    /// 点击手势必须挂在块的 `.offset` **之前**（和裁切把手同一条规矩：几何效果只挪画面、不挪布局框，
    /// 挂在后面拿到的不是块自己的坐标；剪辑块的刀片从 2026-08 起就是这么读的）。
    func seekFromTimeline(blockX x: Double, start: Double, end: Double, pps: Double) {
        seekFromTimeline(time: TimelineSeek.timeInBlock(
            x: x, start: start, end: end, pps: pps, frameDuration: state.frameRate.secondsPerFrame
        ))
    }
}
