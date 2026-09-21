import AVKit
import AppKit
import CoreImage
import Foundation

// 预览侧的调色：把此刻生效的滤镜栈挂到 **AVPlayerView 自己的图层**上。
//
// 为什么不进合成（AVMutableVideoComposition）：那条路要自写
// `AVVideoCompositing`，而现有的摆放/裁切/不透明度/关键帧全是靠 layer
// instruction 做的，自定义合成器会把它们**整套推倒重写**。轻量化优先
//（AGENTS.md 工程原则 1），这里选图层滤镜。
//
// 2026-09-21 实测（探针见 docs/architecture/filters.md 的「地基」一节）：
//
// 1. `contentFilters` 和 `layer.filters` **都**能染到视频画面（纯红视频挂一张
//    通道轮换 LUT 后拍屏取到的是绿）。这里用 `contentFilters` —— 它是 NSView
//    级别的正经 API，不用去碰 AVPlayerView 内部的图层结构。
// 2. **`backgroundFilters` 绝对不能用**：它染的是整个窗口的背景，实测会把同一
//    个窗口里**没挂任何滤镜**的播放器也一起染了，挂了滤镜的那些还被染两次。
// 3. 1080p 挂一张 33³ 的 LUT，播放漂移和 CPU 与不挂时**一样**（GPU 合成，
//    进程这边零成本）；按强度重算一张表 0.109ms，拖滑块 60Hz 也只多 3% CPU。
//
// 叠层（形状 / 文字 / 字幕 / 变换框）是 ZStack 里播放器**上面**的兄弟视图，
// 所以它们天然不吃滤镜 —— 与导出滤镜链里「滤镜插在画面合成之后、形状之前」
// 一字不差。

/// 此刻要挂的一串滤镜。**数组顺序就是作用顺序**（层号小的在前）。
struct FilterStack: Equatable {
    struct Entry: Equatable {
        var preset: FilterPreset
        var strength: Double
    }

    var entries: [Entry] = []

    static let empty = FilterStack()

    var isEmpty: Bool { entries.isEmpty }

    /// 强度为 0 的段直接不进栈：那是「先关掉看看」，画面应当和原片一模一样，
    /// 而不是白算一遍恒等表。导出侧有同一条短路。
    init(entries: [Entry] = []) {
        self.entries = entries.filter { $0.strength > 0.0005 }
    }

    init(in state: TimelineState, at time: Double) {
        self.init(entries: state.activeFilters(at: time).map {
            Entry(preset: $0.preset, strength: $0.strength)
        })
    }

    /// 只换了强度、没换种类和层数 —— 这一步能走「只改参数」的便宜路。
    func differsOnlyInStrength(from other: FilterStack) -> Bool {
        guard entries.count == other.entries.count else { return false }
        return zip(entries, other.entries).allSatisfy { $0.preset == $1.preset }
    }

    func ciFilters() -> [CIFilter] {
        entries.enumerated().compactMap { index, entry in
            FilterLUT.previewFilter(
                for: entry.preset, strength: entry.strength, name: FilterStack.filterName(index)
            )
        }
    }

    /// CALayer 上的滤镜名。有名字才能用 `filters.<name>.inputCubeData` 这条
    /// keypath 只改参数（实测能真的重绘），不必整条 `contentFilters` 重新赋值。
    static func filterName(_ index: Int) -> String { "srtflowGrade\(index)" }
}

/// 把一串滤镜挂到播放器视图上，并记住挂的是什么。
///
/// 独立成一个类而不是写在 `updateNSView` 里：SwiftUI 每次 body 求值都会调
/// `updateNSView`（播放中时钟 0.05s 一跳，也就是每秒 20 次），必须有个地方记住
/// 「上一次挂的是什么」，不然每一跳都要重建一整条 CI 链。
@MainActor
final class FilterStackAttachment {
    private var attached: FilterStack = .empty
    private var enabled = false

    func apply(_ stack: FilterStack, to view: NSView) {
        guard stack != attached else { return }
        defer { attached = stack }

        if stack.isEmpty {
            view.contentFilters = []
            return
        }
        if !enabled {
            // 只在**真的要挂滤镜**时才打开这个开关：它会让视图退出一部分绘制
            // 优化（见 NSView.layerUsesCoreImageFilters 文档）。一旦打开就不再
            // 关掉 —— 滤镜段被拖进拖出时来回切换那些优化路径，不值当。
            view.wantsLayer = true
            view.layerUsesCoreImageFilters = true
            enabled = true
        }
        // 只换了强度：改参数就够，比重建整条链便宜（也不会让 CA 重新建缓存）。
        if !attached.isEmpty, stack.differsOnlyInStrength(from: attached) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (index, entry) in stack.entries.enumerated() {
                view.layer?.setValue(
                    FilterLUT.cubeData(for: entry.preset, strength: entry.strength),
                    forKeyPath: "filters.\(FilterStack.filterName(index)).inputCubeData"
                )
            }
            CATransaction.commit()
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.contentFilters = stack.ciFilters()
        CATransaction.commit()
    }
}
