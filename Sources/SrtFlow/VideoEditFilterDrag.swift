import AppKit
import SwiftUI
import UniformTypeIdentifiers

// 从滤镜库把一张卡片拖到时间线上。
//
// 三条地基和转场那套一字不差（理由见 `VideoEditTransitionDrag.swift` 的文件头，
// 这里不再重复）：**自定义载荷类型**（别和 `.onDropOfFiles` 打架）、
// **必须用 `DropDelegate`**（`.dropDestination` 给不了指针位置）、
// **起手时记一笔拖的是哪张卡**（读载荷是异步的，落点框要同步算出来）。
//
// 和转场唯一的结构差别：**落点挂在整块滚动内容上，不是某一行**。转场只能落在
// 主轨那一条缝上，挂一行就够；滤镜落在哪一**层**由指针的纵向位置决定，所以要
// 拿到 y。代价是纵向合法性得自己判 —— `rowLayouts()` 把 y 翻成行，规则在
// `FilterDropPlan` 里。

enum FilterDrag {
    static let typeIdentifier = FilterPayloadType.drag
    static let type = UTType(exportedAs: typeIdentifier, conformingTo: .data)

    /// 起手时记下拖的是哪一款。理由同转场：落点框要**同步**算出来，
    /// 而读 `NSItemProvider` 是异步的。
    @MainActor static var preset: FilterPreset?

    @MainActor
    static func itemProvider(for preset: FilterPreset) -> NSItemProvider {
        Self.preset = preset
        return NSItemProvider(item: preset.rawValue as NSString, typeIdentifier: typeIdentifier)
    }
}

/// 松手之后这一段落在哪：起点、时长、层号。
///
/// **画框和落地走同一个 plan**，不各算一次 —— 转场那边踩过这条（框画在这条缝上、
/// 转场却落到另一条，是最难查的一种错）。
struct FilterDropPlan: Equatable {
    var start: Double
    var duration: Double
    var layer: Int
    /// 落点框画在哪个 y。`nil` = 这一层还没有行（要新开一行），由调用方决定画哪儿。
    var rowY: Double?
    /// 要亮的对齐参考线。
    var guides: [Double]

    var end: Double { start + duration }
}

/// 时间线上那块滚动内容的落点代理。
struct FilterDropDelegate: DropDelegate {
    let project: VideoEditProject
    let pps: Double
    /// 每一行的纵向位置。指针落在哪一行 → 落在哪一层。
    let rowLayouts: [VideoEditTimelineView.RowLayout]
    /// 横向滚动量的唯一来源（§5b：现读，不缓存）。
    let geometry: TimelineScrollGeometry
    /// 拖到视口边缘时把时间线推走的那台心跳。和剪辑拖动共用同一台。
    let autoScroller: TimelineAutoScroller
    let viewport: CGSize
    @Binding var preview: FilterDropPlan?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [FilterDrag.type])
    }

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated { preview = plan(at: info.location) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        MainActor.assumeIsolated {
            // **用刚算出来的局部值判，不要回读 `preview`**：`@Binding` 的写入不是
            // 同步可见的，回读会让「能不能落」整整晚一帧（同转场那条）。
            let next = plan(at: info.location)
            preview = next
            autoScroll(contentX: info.location.x, contentY: info.location.y)
            return DropProposal(operation: next == nil ? .cancel : .copy)
        }
    }

    func dropExited(info: DropInfo) {
        MainActor.assumeIsolated {
            preview = nil
            autoScroller.stop()
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            defer {
                preview = nil
                FilterDrag.preset = nil
                autoScroller.stop()
            }
            guard let preset = FilterDrag.preset, let plan = plan(at: info.location) else {
                return false
            }
            project.addFilter(preset, at: plan.start, duration: plan.duration, layer: plan.layer)
            return true
        }
    }

    @MainActor
    private func plan(at location: CGPoint) -> FilterDropPlan? {
        guard FilterDrag.preset != nil else { return nil }
        let duration = FilterClip.defaultDuration
        // 指针落在块的中间比落在块的左端更像「我要放在这儿」。
        let proposed = max(0, location.x / pps - duration / 2)
        let resolved = TimelineSnap.resolve(
            proposedStart: proposed,
            duration: duration,
            candidates: project.snapCandidates(moving: []),
            pixelsPerSecond: pps
        )
        let start = resolved.start
        let end = start + duration

        // 指针在哪一行 → 从哪一层往上找空层。不在滤镜行上（视频轨、音频轨、
        // 标尺……）就按「最低空层」落，和按 `+` 完全一致。
        let row = rowLayouts.first { location.y >= $0.minY && location.y <= $0.maxY }
        let layer: Int
        if let hovered = row?.spec.filterLayer {
            layer = project.state.freeFilterLayer(from: hovered, start: start, end: end)
        } else {
            layer = project.state.lowestFreeFilterLayer(start: start, end: end)
        }

        // 这一层已经有行就画在那一行上；是新开的层就交给调用方画在最上面。
        let rowY = rowLayouts.first { $0.spec.filterLayer == layer }?.minY
        return FilterDropPlan(
            start: start, duration: duration, layer: layer, rowY: rowY, guides: resolved.guides
        )
    }

    /// 指针停在视口边缘时把时间线推走。**只横着滚**：纵向滚会把滤镜行滚出视口、
    /// 落点当场消失（同转场那条，传 `height: 0` 让心跳的纵向那一半整个跳过）。
    @MainActor
    private func autoScroll(contentX: Double, contentY: Double) {
        let viewportX = contentX - geometry.offsetX
        autoScroller.update(
            pointer: CGPoint(x: viewportX, y: 0),
            viewport: CGSize(width: viewport.width, height: 0)
        ) {
            preview = plan(at: CGPoint(x: viewportX + geometry.offsetX, y: contentY))
        }
    }
}

/// 落点框。只画框不吃事件：它盖在行上，吃掉 hit test 的话拖到一半自己把落点挡了。
struct FilterDropIndicator: View {
    let plan: FilterDropPlan
    let pps: Double
    /// 这一层还没有行时画在哪（最上面那条非标尺行的位置）。松手之后新行就长在
    /// 那儿，所以框先画在那儿是诚实的。
    let fallbackY: Double

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
            .background(
                RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.18))
            )
            .frame(
                width: max(FilterBlockMetrics.minimumWidth, plan.duration * pps),
                height: FilterBlockMetrics.height
            )
            .offset(
                x: plan.start * pps,
                y: (plan.rowY ?? fallbackY) + FilterBlockMetrics.topInset
            )
            .allowsHitTesting(false)
            .zIndex(7)
    }
}
