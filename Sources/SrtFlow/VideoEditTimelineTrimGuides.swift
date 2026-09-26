import Combine
import SwiftUI

// MARK: - 裁切时的对齐线：谁发、谁画
//
// 管什么：拉把手裁切时要亮的那几根黄线（时刻）放在哪、画在哪。
// 不管什么：线该不该亮、亮在哪（`TrimSnapPlan`，纯值，VideoEditTimelineTrimSnap.swift）。
//
// 为什么是工程持有的一个小 ObservableObject（同 `PreviewRebuildStatus` 那一条，preview-perf-ratchet.md 第十节）：
// 裁切走的是工程的 `liveTrim` / `endLiveEdit`，五种块的把手都从那儿进；线只有拖动覆盖层里的
// `TimelineTrimGuides` 这一个小视图关心。放进工程的被观察属性的话，读它的视图每一拍都被叫醒；
// 放进时间线的拖动盒子的话，五处把手的回调都得各自接一遍（漏一处那种块就不亮线）。

/// 裁切时要亮的对齐线。工程用 `let` 持有（不被观察），只有 `TimelineTrimGuides` 订阅。
@MainActor
final class TrimGuideState: ObservableObject {
    @Published private(set) var times: [Double] = []

    /// 只在变了时才发：裁切每一拍都写，但线很少变。
    func show(_ next: [Double]) {
        if times != next { times = next }
    }
}

/// 拖动覆盖层里的那几根线（和拖动的对齐线同一个样子：`TimelineAlignmentGuides`）。
struct TimelineTrimGuides: View {
    @ObservedObject var state: TrimGuideState
    let pixelsPerSecond: Double

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        TimelineAlignmentGuides(times: state.times, pixelsPerSecond: pixelsPerSecond)
    }
}
