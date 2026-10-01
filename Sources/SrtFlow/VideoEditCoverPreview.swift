import AVFoundation
import AppKit
import CoreImage
import SwiftUI

// MARK: - 预览上的「盖一块」（模糊 / 马赛克）
//
// 管什么：预览画面上此刻该盖的那几块（`CoverStack`，按值比较）和怎么盖：**同一个 AVPlayer 再开一层 AVPlayerLayer**，
// 只露那一块、加模糊 / 马赛克的图层滤镜。
// 为什么不进合成：同调色（docs/architecture/filters.md）—— 预览不走自写的 `AVVideoCompositing`，那会把现有的摆放 / 裁切 / 关键帧
// 全部推倒重写，轻量化优先；这里的做法和调色一样只靠图层。
// 2026-09-29 窗口探针实测的地基（docs/architecture/cover-blur-mosaic.md）：
// 1. 同一个 AVPlayer 上挂第二个 AVPlayerLayer，两层同步显示，不多解码；
// 2. `CALayer.filters` 对 AVPlayerLayer 生效（CIGaussianBlur / CIPixellate），半径 / 格子的单位是点；
// 3. **蒙版和滤镜别挂在同一层再靠 mask 裁**（实测蒙版边上会和透明混出灰框）：外层只有这一块那么大、`masksToBounds`，里面的播放器层平移对齐，
//    滤镜挂在外层上 —— 滤镜的输入就是这一块自己，边缘用 CIAffineClamp 往外延（和导出的 crop → gblur → overlay 一个算法）；
// 4. 调色（`FilterStack`）挂在播放器视图上，这一层看不到：这一层的滤镜链要**先带上调色**，再盖 —— 盖的是调完色的画面（导出同序）。
// 叠层（形状 / 文字 / 字幕 / 变换框）是它上面的兄弟视图，不被盖 —— 和导出「盖一块在形状之前」一字不差。
// 不管什么：模型（VideoEditShapeModels）、导出（VideoEditCoverExport）、CI 滤镜的参数（VideoEditCoverFilters）。
// 已知差异：盖的是整幅合成（含上层视频轨），导出也是；预览的 CIPixellate 格子边长和导出一样，取样方式不同（格子里的颜色略有差别）。

/// 此刻要盖的几块，按数组顺序（先加的先盖）。
struct CoverStack: Equatable {
    struct Entry: Equatable {
        var kind: ShapeKind
        /// 画布上的一块，0…1 归一化、左上原点。
        var rect: CGRect
        /// 1080p 基准的力度。
        var amount: Double
    }

    var entries: [Entry] = []

    static let empty = CoverStack()

    var isEmpty: Bool { entries.isEmpty }

    init(entries: [Entry] = []) { self.entries = entries }

    init(in state: TimelineState, at time: Double) {
        self.init(entries: state.renderedCovers.filter { $0.contains(time: time) }.map {
            Entry(kind: $0.kind, rect: $0.frame(in: CGSize(width: 1, height: 1)), amount: $0.coverAmount)
        })
    }
}

/// 第二层：同一个播放器的另一个 AVPlayerLayer，一块一层（外层裁出这一块，里面是整幅画面平移对齐）。
struct CoverPreviewLayer: NSViewRepresentable {
    let player: AVPlayer
    let covers: CoverStack
    /// 此刻的调色：挂在播放器视图上的那串滤镜这一层看不到，要自己带上（调色在前、盖在后）。
    let grade: FilterStack

    func makeNSView(context: Context) -> CoverHostView { CoverHostView(player: player) }

    func updateNSView(_ nsView: CoverHostView, context: Context) {
        PerfCounters.update(Self.self)
        nsView.apply(covers, grade: grade)
    }
}

final class CoverHostView: NSView {
    private final class Region {
        let container = CALayer()
        let effect = CALayer()
        let playerLayer: AVPlayerLayer

        init(player: AVPlayer) {
            playerLayer = AVPlayerLayer(player: player)
            playerLayer.videoGravity = .resizeAspect   // 和 PlayerLayerView 同一个放法：画布正好铺满时两层的画面重合
            container.masksToBounds = true
            container.addSublayer(effect)
            effect.addSublayer(playerLayer)
        }
    }

    private let player: AVPlayer
    private var regions: [Region] = []
    private var applied = CoverStack.empty
    private var appliedGrade = FilterStack.empty
    private var laidOut = CGSize.zero

    init(player: AVPlayer) {
        self.player = player
        super.init(frame: .zero)
        wantsLayer = true
        // 图层滤镜要开这个开关（同 FilterStackAttachment）；只在真有盖一块时才建这个视图，没有就不付这份钱。
        layerUsesCoreImageFilters = true
        layer = CALayer()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 这一层只是看的：不吃事件，下面的播放器控件和上面的叠层照常。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        relayout()
    }

    func apply(_ covers: CoverStack, grade: FilterStack) {
        guard covers != applied || grade != appliedGrade else { return }
        applied = covers
        appliedGrade = grade
        relayout(force: true)
    }

    private func relayout(force: Bool = false) {
        guard force || bounds.size != laidOut, let root = layer else { return }
        laidOut = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        while regions.count < applied.entries.count {
            let region = Region(player: player)
            root.addSublayer(region.container)
            regions.append(region)
        }
        while regions.count > applied.entries.count, let region = regions.popLast() {
            region.playerLayer.player = nil
            region.container.removeFromSuperlayer()
        }
        let width = bounds.width, height = bounds.height
        guard width > 0, height > 0 else { return }
        let scale = height / Double(1080)
        for (region, entry) in zip(regions, applied.entries) {
            // CA 的原点在左下：归一化的框是左上原点，换一下。
            let rect = CGRect(
                x: entry.rect.minX * width, y: height - entry.rect.maxY * height,
                width: entry.rect.width * width, height: entry.rect.height * height
            )
            region.container.frame = rect
            region.effect.frame = CGRect(x: -rect.minX, y: -rect.minY, width: width, height: height)
            region.playerLayer.frame = region.effect.bounds
            region.container.filters = appliedGrade.ciFilters()
                + CoverFilters.ciFilters(kind: entry.kind, amount: entry.amount * scale, regionHeight: rect.height)
        }
    }
}
