import SwiftUI

// MARK: - 「预览正在重建」这一个开关，和读它的那个小转圈
//
// 管什么：预览重建（`VideoEditProject.scheduleRebuild`）进行中的标记，以及工具栏上显示它的转圈。
// 不管什么：重建本身（`scheduleRebuild` / `VideoEditCompositionBuilder`）。
//
// 为什么单独一个小对象（docs/bugfixes/2026-09-25-rebuild-reopens-every-asset.md）：它以前是
// `VideoEditProject` 上的 `@Published`，每次重建开始、结束各发一次 `objectWillChange`，订阅工程的
// 整个编辑器（提示修饰器、轨道头、工具栏、检查器、转场库）就各重算一轮 —— 只为了一个转圈。结束那
// 一轮单独占一拍、是白算的。现在只有转圈订阅它；工程里的判断（快路径让路、冒烟的「落定」）直接读值。

/// 预览正在重建吗。只在变了时发。
@MainActor
final class PreviewRebuildStatus: ObservableObject {
    @Published private(set) var isRebuilding = false

    func set(_ rebuilding: Bool) {
        if isRebuilding != rebuilding { isRebuilding = rebuilding }
    }
}

/// 工具栏上「预览正在重建」的小转圈。**只订阅 `PreviewRebuildStatus`**，不订阅工程。
struct PreviewRebuildSpinner: View {
    @ObservedObject var status: PreviewRebuildStatus

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        if status.isRebuilding {
            ProgressView().controlSize(.mini)
        }
    }
}
