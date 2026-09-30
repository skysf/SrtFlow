import Foundation

/// 时间线上「点一下把播放头挪过去」的纯值规则。
///
/// 管什么：落点怎么算 —— 全局夹进 [0, 工程总长]（2026-09-21 点非素材处）；点在块上时落在
/// 指针底下那一刻、但不出这一块（2026-09-30 点块本体）。
/// 不管什么：谁来调、seek 之后播放器做什么 —— 唯一的入口是 `VideoEditProject.seekFromTimeline`
///（VideoEditProject+Seek.swift），标尺、空白、每一种块都走它。
/// 自检：checks/TimelineSnap/Seek.swift；接线守卫：checks/timeline-drag-wiring/playhead-click.sh。
/// 合同：docs/architecture/timeline-drag-gestures.md §5f。
enum TimelineSeek {
    /// 全局夹紧：[0, duration]。空工程（总长 0）落在 0。
    static func clamped(_ time: Double, duration: Double) -> Double {
        min(max(0, time), max(0, duration))
    }

    /// 点在块上落到哪一刻：块的起点 + 指针在块里的 x 换成秒，但**不出这一块** ——
    /// 最右夹到块的最后一帧（`end − frameDuration`），块比一帧还短就落在起点。
    ///
    /// 为什么不许落到 `end`：那一刻已经是下一段的第一帧，工具栏上「播放头得落在片段内」才
    /// 可用的按钮（分割、冻结、标记）会认成隔壁那段 —— 用户明明点的是这一块。
    static func timeInBlock(x: Double, start: Double, end: Double, pps: Double, frameDuration: Double) -> Double {
        guard pps > 0 else { return start }
        let lastFrame = max(start, end - frameDuration)
        let pointer = start + max(0, x) / pps
        return min(max(start, pointer), lastFrame)
    }
}
