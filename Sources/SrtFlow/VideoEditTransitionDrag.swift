import AppKit
import SwiftUI
import UniformTypeIdentifiers

// 从转场库把一张卡片拖到主轨接缝上。
//
// 时间线在这之前**一个 SwiftUI 拖放都没有**（块的移动、裁切、标尺 scrub 全是
// `DragGesture`），这是新起的一套，所以三条地基写在这儿：
//
// 一、**载荷类型不能用 `.fileURL`**。`VideoEditView` 整个挂着 `.onDropOfFiles`
//    （从访达拖素材进来靠它），同一个类型两边都认领就会打架 —— 拖卡片可能被
//    当成拖文件、或者反过来。自定义类型让两条路各走各的。
//
// 二、**必须用 `DropDelegate`，不能用 `.dropDestination`**。后者的 `isTargeted`
//    只给一个 Bool，给不了指针位置 —— 而「落在哪条缝上」的框必须跟着指针连续走。
//
// 三、**落点挂在主轨那一行上**，不是整条时间线。纵向合法性因此天然判掉（拖到
//    字幕轨、形状轨上压根不会触发），而且 `DropInfo.location.x` 就是**内容坐标**
//    （行随内容一起滚），不用再补滚动量 —— §5b 那条坑在这条路上不存在。

enum TransitionDrag {
    static let typeIdentifier = "com.srtflow.transition"
    static let type = UTType(exportedAs: typeIdentifier, conformingTo: .data)

    /// 起手时记下拖的是哪张卡。
    ///
    /// **为什么不从 `NSItemProvider` 里读**：读载荷是**异步**的，而落点框要在
    /// `dropUpdated` 里同步算出来 —— 容量与种类有关（零余料的缝上压黑能落、叠化
    /// 不能），不知道是哪张卡就判不出这条缝接不接。同进程内拖放，起手时直接
    /// 记一笔最准也最省事；载荷本身仍然照规矩带上，外部工具看得懂。
    @MainActor static var kind: ClipTransition?

    @MainActor
    static func itemProvider(for kind: ClipTransition) -> NSItemProvider {
        Self.kind = kind
        return NSItemProvider(item: kind.rawValue as NSString, typeIdentifier: typeIdentifier)
    }
}

/// 主轨那一行的落点代理。
struct TransitionDropDelegate: DropDelegate {
    let project: VideoEditProject
    let pps: Double
    /// 横向滚动量的唯一来源（§5b：现读，不缓存）。
    let geometry: TimelineScrollGeometry
    /// 拖到视口边缘时把时间线推走的那台心跳。和剪辑拖动共用同一台。
    let autoScroller: TimelineAutoScroller
    let viewport: CGSize
    /// 落点框。`nil` = 这一刻没有可落的缝（不高亮，松手也不接）。
    @Binding var preview: TransitionDropPreview?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [TransitionDrag.type])
    }

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated { preview = target(info) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        MainActor.assumeIsolated {
            // **用刚算出来的局部值判，不要回读 `preview`**：`@Binding` 的写入
            // 不是同步可见的，这一拍读回去拿到的还是上一拍的值，于是「能不能落」
            // 会整整晚一帧 —— 指针已经离开可落区，光标还显示能放。
            let next = target(info)
            preview = next
            autoScroll(contentX: info.location.x)
            // 没有可落的缝就明说不接：指针变成禁止号，松手回弹。
            // `.forbidden` 而不是 `.cancel`：后者会取消整轮拖放，之后不再有
            // dropUpdated，指针挪到能落的缝上也救不回来（见 TimelineDropRouter.dropUpdated）。
            return DropProposal(operation: next == nil ? .forbidden : .copy)
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
                TransitionDrag.kind = nil
                autoScroller.stop()
            }
            // **落地和画框走同一个函数、同一个坐标**，不读那份 @State —— 两边各
            // 算一次的话，框画在这条缝上、转场却落到另一条，是最难查的一种错。
            guard let kind = TransitionDrag.kind, let target = target(info) else { return false }
            let clips = project.state.mainClips
            guard clips.indices.contains(target.seamIndex) else { return false }
            project.applyTransition(toSeamAfter: clips[target.seamIndex].id, kind)
            return true
        }
    }

    @MainActor
    private func target(_ info: DropInfo) -> TransitionDropPreview? {
        previewAt(contentX: info.location.x)
    }

    @MainActor
    private func previewAt(contentX: Double) -> TransitionDropPreview? {
        guard let kind = TransitionDrag.kind else { return nil }
        return TimelineState.transitionDropPreview(
            atX: contentX, pps: pps, mainClips: project.state.mainClips, kind: kind
        )
    }

    /// 指针停在视口边缘时把时间线横着推走，好让它够得到屏幕外的接缝。
    ///
    /// `DropInfo.location` 是**内容坐标**（行随内容一起滚），而心跳要的是指针在
    /// **视口**里的位置 —— 差的正是当下的横向滚动量，现读（§5b：滚动量只有
    /// `TimelineScrollGeometry` 一个来源，不许再缓存一份）。
    ///
    /// 自动滚动那一拍指针在屏幕上**一动没动**，但内容被从它底下抽走了，指针底下
    /// 的内容坐标因此变了 —— 所以回调里拿「视口 x + **新的**滚动量」重算，不能
    /// 沿用上一拍那个内容坐标。这和 `ClipDragSession.update` 补 `scrolled` 是同
    /// 一件事。
    ///
    /// **只横着滚**：转场只能落在主轨那一行，纵向滚下去反而会把主轨滚出视口、
    /// 落点当场消失。传 `height: 0` 让心跳的纵向那一半整个跳过（它自己的门槛就是
    /// `viewport.height > edgeHeight * 2`），`pointer.y` 因此也不参与计算。
    @MainActor
    private func autoScroll(contentX: Double) {
        let viewportX = contentX - geometry.offsetX
        autoScroller.update(
            pointer: CGPoint(x: viewportX, y: 0),
            viewport: CGSize(width: viewport.width, height: 0)
        ) {
            preview = previewAt(contentX: viewportX + geometry.offsetX)
        }
    }
}

/// 落点框：和转场遮罩**同一套几何**（`transitionDropPreview` 内部走的就是遮罩
/// 那两个函数），所以松手之后框在哪儿、遮罩就在哪儿，宽度也一样。
///
/// 只画框不吃事件：它盖在主轨上，吃掉 hit test 的话拖到一半自己把落点挡了。
struct TransitionDropIndicator: View {
    let preview: TransitionDropPreview
    let rowHeight: Double

    var body: some View {
        let height = max(14, rowHeight - 10)
        RoundedRectangle(cornerRadius: 4)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
            .background(
                RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.18))
            )
            .frame(width: preview.width, height: height)
            .offset(x: preview.x, y: (rowHeight - height) / 2)
            .allowsHitTesting(false)
            .zIndex(7)
    }
}
