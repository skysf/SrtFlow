import AppKit
import SwiftUI
import UniformTypeIdentifiers

// 把 Finder 里的文件拖进时间线（以及 ⌘V 粘贴进时间线）。
//
// 两条地基和滤镜 / 音频库那两套一样：**画框和落地共用一个落点函数**、
// **起手时把要落的东西记一笔**。另外两条是这一套自己的：
//
// 一、**这个代理不直接挂到视图上**，由 `TimelineDropRouter` 分派过来。时间线上
//    只许有那一个 `.onDrop`：SwiftUI 把拖放交给指针底下**最里面**那个落点，类型
//    对不上也不往外找，两个落点一里一外叠着，里面那个就会吞掉外面那个的拖入
//    （2026-09-23 探针实测，理由和证据见 `VideoEditTimelineDropRouter.swift` 的
//    文件头、docs/architecture/timeline-drag-gestures.md §5e-2）。
//
//    载荷就是 `.fileURL`，不是自定义类型。`VideoEditView` 整页那条 `.onDropOfFiles`
//    兜底原样留着：时间线的滚动区归路由器，时间线以外（预览区 / 检查器 / 库栏 /
//    轨道头列 / 空工程）仍归它。这也是转场 / 滤镜 / 音频库三套**不许**用
//    `.fileURL` 的理由（`checks/timeline-drag-wiring.sh` 钉着）。
//
// 二、**时长要探测才知道，而探测是异步的**。落点框的宽度、以及「这里撞不撞得上、
//    要不要往上抬一轨」全都依赖时长。所以：拖进来那一刻就开始探（`probeVideo` /
//    `audioDuration` 都按 URL 缓存，本地文件通常几十毫秒），没探完只画一条插入线
//    + 高亮目标轨，探完换成真实宽度的落点框。
//
//    **松手那一下不分两条路**：`performDrop` 只把「指针时间 + 目标轨」定死，
//    时长探完之后照样喂给同一个 `TimelineState.mediaImportLandings`。所以
//    「探完了再松手」和「没探完就松手」落在同一个地方，不是两套算法。
//
// 产品口径（落点、多文件接龙、类型不匹配、⌘V）见
// docs/plans/2026-09-22-media-file-drop.md；落点算法本身在
// `VideoEditMediaImport.swift`（纯值，自检够得着）。

struct MediaFileImport: Equatable {
    enum Kind: Equatable {
        case video
        case image
        case audio
    }

    var url: URL
    var kind: Kind
    var duration: Double
    /// 视频探出来的尺寸/帧率等。图片和音频没有。
    var info: MediaInfo?

    /// 喂给落点算法的那一半。落点只关心「多长、进画面轨还是声音轨」。
    var item: MediaImportItem {
        MediaImportItem(duration: duration, isAudio: kind == .audio)
    }
}

/// 第一段素材的起点从哪来。
enum MediaImportAnchor: Equatable {
    /// 指针在时间轴上的位置：第一段的**中点**对齐它（拖放）。
    /// 指针落在块中间比落在块左端更像「我要放在这儿」（同滤镜、音频库两套）。
    case pointer(Double)
    /// 第一段的**起点**就是它（⌘V 落播放头，同按 `+` 的口径）。
    case start(Double)
}

/// 这一轮拖进来的是什么。**只用来画落点框**，落地不读它（落地重新从
/// `NSItemProvider` 取 URL，探测结果按 URL 缓存，所以不会多探一遍）。
///
/// 为什么非要有这么一个静态暂存：落点框要在 `dropUpdated` 的每一拍**同步**算出来，
/// 而读 `NSItemProvider` 和探测时长都是异步的（同 `FilterDrag.preset`、
/// `AudioLibraryDrag.pending` 那两笔，理由一模一样）。
enum MediaFileDrag {
    @MainActor static var pending: Pending?
    /// 指针最后停在哪（滚动内容坐标）。探测是异步的，探完那一刻用户可能正好没动
    /// 鼠标，探测任务按它自己补画一次落点框。
    @MainActor static var lastLocation: CGPoint?
    @MainActor private static var counter = 0

    /// 这一轮拖放的代号。探测回来时对不上就丢掉 —— 用户可能已经拖出去又拖进来，
    /// 那时界面上等着的是另一批文件（同 `documentGeneration` 那条守卫的道理）。
    @MainActor
    static func nextToken() -> Int {
        counter += 1
        return counter
    }

    @MainActor
    static func reset() {
        pending = nil
        lastLocation = nil
    }

    struct Pending: Equatable {
        var token: Int
        /// 这一轮拖进来的文件，从**拖放剪贴板**同步读到的。
        /// 空 = 一个都没读到，那就是「还不知道」，**不是**「文件不行」。
        var urls: [URL] = []
        /// 探完时长的素材，顺序 = 用户在 Finder 里选文件的顺序。
        var media: [MediaFileImport] = []
        /// 这一批里有字幕文件。它没有落点语义（字幕挂在工程上，不占轨），
        /// 但拖进来是合法的，所以不能当成「什么都不认识」。
        var hasSubtitle = false
        /// 还在探测时长。
        var isProbing = true

        /// **确知**这一批一个都用不了：URL 读到了、探完了、没有一个能上轨
        ///（拖过来的是一堆 .pdf 之类）。这时候把落点判成不可落，指针当场变成
        /// 「不能放」，比松手之后再弹一条提示诚实。
        ///
        /// **一个 URL 都没读到时不算**（`!urls.isEmpty` 那一项）：那是我们没看见，
        /// 不是文件不行。据此拒绝的话，读不到 URL 的那一刻整条拖放就全死了 ——
        /// 而且外层 `.onDropOfFiles` 的兜底也救不回来，这个代理已经认领了这次
        /// 拖入。2026-09-22 首测就是这么死的。
        var isUnusable: Bool { !isProbing && !urls.isEmpty && media.isEmpty && !hasSubtitle }
    }
}

/// 松手之后这一批素材落在哪。
///
/// **画框和落地共用同一个落点函数**（`TimelineState.mediaImportLandings`），
/// 这里只是把它的结果配上几何。各算一次必然分叉 —— 框画在这条轨、素材落到另一条，
/// 是这个仓库反复踩的那一类错。
struct MediaFileDropPlan: Equatable {
    /// 每一段的落点 + 它的框画在哪一行。探测没完成时是空的。
    var placements: [Placement] = []
    /// 还在探测时长：只画插入线，不画框。
    var isProbing: Bool
    /// 插入线画在哪（秒），以及探测中要高亮的那一行。
    var pointerTime: Double
    var pointerRowY: Double
    var pointerRowHeight: Double
    /// 要亮的对齐参考线。
    var guides: [Double] = []

    struct Placement: Equatable {
        var start: Double
        var duration: Double
        var rowY: Double
        var rowHeight: Double

        var span: TimelineSpan { TimelineSpan(start: start, end: start + duration) }
    }
}

/// 拖文件进来时画在时间线上的落点。
///
/// 两个阶段，画的东西不一样（理由见文件头「时长要探测才知道」那一段）：
///
/// - **还在探测**：一条插入线 + 目标轨描边。框的宽度依赖时长，这时候画一个宽度是
///   假的框就是说谎。
/// - **探完了**：每一段一个虚线框，各自画在它会落进的那条轨上。**复用剪辑拖动那个
///   框**（`dropPlaceholder` 同款）—— 落下去就是普通的剪辑块，没道理让用户学第二种
///   落点语言。
struct MediaFileDropIndicator: View {
    let plan: MediaFileDropPlan
    let pps: Double
    /// 目标轨描边的宽度 = 内容区宽度。
    let fullWidth: Double

    var body: some View {
        ZStack(alignment: .topLeading) {
            if plan.isProbing {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.teal, lineWidth: 2)
                    .frame(width: fullWidth, height: plan.pointerRowHeight)
                    .offset(y: plan.pointerRowY)
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.teal)
                    .frame(width: 2, height: plan.pointerRowHeight)
                    .offset(x: plan.pointerTime * pps - 1, y: plan.pointerRowY)
            } else {
                ForEach(Array(plan.placements.enumerated()), id: \.offset) { _, spot in
                    TimelineDropPlaceholder(
                        span: spot.span, pps: pps, y: spot.rowY, height: spot.rowHeight
                    )
                }
            }
        }
        // 落点框只画不吃事件：它盖在轨道上，吃掉 hit test 就会把落点自己挡住
        //（同「块内装饰不吃事件」那条）。
        .allowsHitTesting(false)
    }
}

/// 时间线那块滚动内容的文件落点。
///
/// 由 `TimelineDropRouter` 分派过来，**不直接挂到视图上**（时间线只许有那一个
/// `.onDrop`，理由见路由器的文件头）。`DropInfo.location` 是滚动内容坐标，
/// 和 `rowLayouts` 同一套，不用补滚动量。
struct MediaFileDropDelegate: DropDelegate {
    let project: VideoEditProject
    let pps: Double
    /// 每一行的纵向位置。指针落在哪一行 → 落进哪条轨。
    let rowLayouts: [VideoEditTimelineView.RowLayout]
    /// 横向滚动量的唯一来源（§5b：现读，不缓存）。
    let geometry: TimelineScrollGeometry
    let autoScroller: TimelineAutoScroller
    let viewport: CGSize
    @Binding var preview: MediaFileDropPlan?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    /// 拖进时间线：起手探时长，并把第一拍的落点画出来。
    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            beginProbe()
            track(info.location)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        MainActor.assumeIsolated {
            track(info.location)
            // **确知**一个都用不了（一堆 .pdf）才说不接：指针当场变成禁止号，比松手
            // 之后再弹提示诚实。还在探测、或者读不到 URL 时一律照接（见 `isUnusable`）。
            let unusable = MediaFileDrag.pending?.isUnusable == true
            return DropProposal(operation: unusable ? .cancel : .copy)
        }
    }

    func dropExited(info: DropInfo) {
        MainActor.assumeIsolated { finish() }
    }

    /// 松手。**落点这一拍就定死，和探测进度无关**：时间和目标轨只由指针决定，
    /// 时长探完之后喂给同一个 `mediaImportLandings` —— 所以「探完了再松手」和
    /// 「没探完就松手」走的是同一条落地路径。
    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            let pending = MediaFileDrag.pending?.urls ?? []
            defer { finish() }
            // 落点只从**这一拍的指针**算，不回读 `preview`：`@Binding` 的写入不是
            // 同步可见的，回读会和画框那一拍脱节（同另外三套拖放）。
            let anchor = MediaImportAnchor.pointer(max(0, info.location.x / pps))
            let target = trackTarget(at: info.location)
            // 松手这一刻 `itemProviders` 一般是给得出来的；给不出来就退回进场时从拖放
            // 剪贴板读到的那一批，再不行就现读一次。**三条路都不通才放弃。**
            let providers = info.itemProviders(for: [.fileURL])
            if !providers.isEmpty {
                project.importFiles(providers: providers, anchor: anchor, preferring: target)
                return true
            }
            let urls = pending.isEmpty ? MediaFileDrag.draggedURLs() : pending
            guard !urls.isEmpty else { return false }
            project.importFiles(urls: urls, anchor: anchor, preferring: target)
            return true
        }
    }

    /// 指针到了 `location`：记下来、重画落点框、推一下自动滚动。
    ///
    /// **暂存为空就不画**（`plan` 返回 nil）：那是这一轮已经收尾了。别在这儿
    /// 「补探一次」—— SwiftUI 松手之后还会补发一拍 `dropUpdated`，补探会把落点框
    /// 按落地之后的状态重新画出来、挂着不走（2026-09-23 实测踩过）。
    @MainActor
    private func track(_ location: CGPoint) {
        MediaFileDrag.lastLocation = location
        // **用刚算出来的局部值**，不要回读 `preview`（理由同 `performDrop`）。
        preview = plan(at: location)
        autoScroll(contentX: location.x, contentY: location.y)
    }

    /// 拖出去，或者这一轮拖放结束。
    @MainActor
    private func finish() {
        preview = nil
        autoScroller.stop()
        MediaFileDrag.reset()
    }

    // MARK: - 探测

    /// 拖进来那一刻就开始读 URL、探时长。结果进 `MediaFileDrag.pending`，
    /// 落点框从那儿取。
    /// **每次进场都重新探**，不看上一笔还在不在。
    ///
    /// 「没有就探」那种写法会留一个真空子：`dropExited` 没被调到（拖放被取消、
    /// 焦点被抢走），上一批文件就一直挂在 `pending` 上，下一次拖进来直接拿它画框 ——
    /// 框说的是上一批素材的长度。探测结果按 URL 缓存，重探一次几乎不要钱。
    @MainActor
    private func beginProbe() {
        let token = MediaFileDrag.nextToken()
        // **同步**从拖放剪贴板读（`draggedURLs` 里写了为什么不用 itemProviders）。
        let urls = MediaFileDrag.draggedURLs()
        MediaFileDrag.pending = MediaFileDrag.Pending(
            token: token,
            urls: urls,
            hasSubtitle: urls.contains(where: MediaFileTypes.isSubtitle),
            isProbing: !urls.isEmpty
        )
        // 一个 URL 都没读到：**不探，也不拒绝**。落点框退化成一条插入线，
        // 松手那一下照样从 `performDrop` 拿到真东西。
        guard !urls.isEmpty else { return }
        Task { @MainActor in
            let probed = await project.probeImports(urls)
            // 探测期间用户可能已经拖出去又拖进来，那时等着的是另一批文件。
            guard MediaFileDrag.pending?.token == token else { return }
            MediaFileDrag.pending?.media = probed
            MediaFileDrag.pending?.isProbing = false
            // 探完这一刻用户可能正好没动鼠标：`dropUpdated` 未必马上再来一拍，
            // 不补的话落点框会停在「一条线」上。按上一次的指针位置自己补画一次。
            if let location = MediaFileDrag.lastLocation {
                preview = plan(at: location)
            }
        }
    }

    // MARK: - 落点

    /// 指针在这个位置时，这一批素材落在哪。
    @MainActor
    private func plan(at location: CGPoint) -> MediaFileDropPlan? {
        // 没有暂存 = 这一轮已经收尾（见 `track`）；确知一个都用不了也不画
        // （`isUnusable` 的注释写了为什么只认「确知」）。其余一律给得出落点：
        // 最不济是一条插入线。
        guard let pending = MediaFileDrag.pending, !pending.isUnusable else { return nil }
        let pointerTime = max(0, location.x / pps)
        let target = trackTarget(at: location)
        // 探测中那条插入线画在哪一行：指到了就是那一行，指不到就按这一批的第一段
        // 会去的那条默认轨（画面 → 主轨）。反正探完就换成真的落点框。
        let pointerRow = rowGeometry(for: target ?? .main)

        guard !pending.isProbing, let first = pending.media.first else {
            return MediaFileDropPlan(
                isProbing: true,
                pointerTime: pointerTime,
                pointerRowY: pointerRow.y,
                pointerRowHeight: pointerRow.height
            )
        }

        let resolved = project.importFirstStart(
            anchor: .pointer(pointerTime),
            firstDuration: first.duration
        )
        let landings = project.state.mediaImportLandings(
            pending.media.map(\.item),
            firstStart: resolved.start,
            preferring: target
        )
        return MediaFileDropPlan(
            placements: landings.map { landing in
                let row = rowGeometry(for: landing.target)
                return MediaFileDropPlan.Placement(
                    start: landing.start,
                    duration: landing.duration,
                    rowY: row.y,
                    rowHeight: row.height
                )
            },
            isProbing: false,
            pointerTime: pointerTime,
            pointerRowY: pointerRow.y,
            pointerRowHeight: pointerRow.height,
            guides: resolved.guides
        )
    }

    /// 指针在哪一行 → 想落进哪条轨。
    ///
    /// 指到标尺、字幕 / 形状 / 文字 / 滤镜行，或者指到一条**隐藏**的轨，都返回
    /// `nil` —— 横向照用指针的 x，纵向由 `mediaImportLandings` 退回这一类的默认轨
    /// （2026-09-22 用户拍板）。"类型不匹配"不用在这儿判：把 mp4 指到音频轨时
    /// 这里给的是 `.audio(n)`，而它不在画面梯子上，落点算法自己会退回主轨。
    @MainActor
    private func trackTarget(at location: CGPoint) -> TrackDropTarget? {
        let row = rowLayouts.first { location.y >= $0.minY && location.y <= $0.maxY }
        guard let row, !row.spec.isHidden else { return nil }
        switch row.spec.slot {
        case .main: return .main
        case .overlay(let index): return .overlay(index)
        case .audio(let index): return .audio(index)
        case nil: return nil
        }
    }

    /// 一条轨的行画在哪。
    ///
    /// 新开的轨还没有行，框画在它**将来会长出来**的位置上：最上面那条轨行的上方 /
    /// 最下面那一行的下方，和跨轨拖动开新轨时的占位框（`crossTrackGhost`）**完全
    /// 同一套几何**（`TimelineDropPlaceholder.newLaneY`）。
    ///
    /// 那儿画不下一整条轨高的框（标尺到 28、最上面那条轨行从 33 起），所以缩到
    /// 22pt 骑在插入线上 —— 按 54pt 的视频行高去画，框会整个跑到视口外面，而
    /// 「主轨占着、往上开一条新轨」恰恰是最常见的那一种落点。
    @MainActor
    private func rowGeometry(for target: TrackDropTarget) -> (y: Double, height: Double) {
        let slot: TrackSlot?
        switch target {
        case .main: slot = .main
        case .overlay(let index): slot = .overlay(index)
        case .audio(let index): slot = .audio(index)
        case .newOverlayTop, .newAudioBottom: slot = nil
        }
        if let slot, let row = rowLayouts.first(where: { $0.spec.slot == slot }) {
            return (row.minY, row.maxY - row.minY)
        }
        if case .newAudioBottom = target {
            return (
                TimelineDropPlaceholder.newLaneY(below: rowLayouts.last?.maxY ?? 30),
                TimelineDropPlaceholder.newLaneHeight
            )
        }
        // 新的上层视频轨，以及「指到的轨号已经不存在了」这种兜底。
        let top = rowLayouts.first { $0.spec.slot != nil }?.minY ?? (rowLayouts.last?.maxY ?? 30)
        return (
            TimelineDropPlaceholder.newLaneY(above: top),
            TimelineDropPlaceholder.newLaneHeight
        )
    }

    /// 指针停在视口边缘时把时间线推走。**只横着滚**：纵向滚会把目标行滚出视口、
    /// 落点当场变掉（同另外三套，传 `height: 0` 让心跳的纵向那一半跳过）。
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

extension MediaFileDrag {
    /// 把一串 `NSItemProvider` 读成文件 URL，顺序不变。
    @MainActor
    static func loadURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            guard let url = await provider.loadFileURL() else { continue }
            urls.append(url)
        }
        return urls
    }

    /// 系统剪贴板上此刻有没有文件。⌘V 的菜单项亮不亮看它，所以必须是**同步**的
    /// （`validateMenuItem` 等不了异步）。
    static func pasteboardURLs() -> [URL] {
        urls(from: .general)
    }

    /// 这一轮拖放里的文件，从**拖放剪贴板**同步读。
    ///
    /// **不要用 `DropInfo.itemProviders(for:)` 做这件事**：松手之前它在 macOS 上
    /// 经常返回空数组。2026-09-22 首测就栽在这儿 —— 读不到 URL → 探测结果「一个
    /// 能用的都没有」→ 全程 `.cancel`，而且外层 `.onDropOfFiles` 的兜底也轮不到
    /// （这个代理已经认领了这次拖入），表现就是**拖进时间线彻底没反应**。
    ///
    /// 拖放剪贴板在整个拖动期间都活着，而且是同步的 —— 落点框正好要同步算。
    static func draggedURLs() -> [URL] {
        urls(from: NSPasteboard(name: .drag))
    }

    private static func urls(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
    }
}

// MARK: - 导入

@MainActor
extension VideoEditProject {

    /// 第一段素材的起点。**落点框和落地共用这一个** —— 拖放要把素材的中点对齐
    /// 指针，⌘V 直接落在播放头上，两种锚点在这里收口，之后就是同一条路。
    func importFirstStart(anchor: MediaImportAnchor, firstDuration: Double) -> TimelineSnap.Result {
        let proposed: Double
        switch anchor {
        case .pointer(let time): proposed = max(0, time - firstDuration / 2)
        case .start(let time): proposed = max(0, time)
        }
        return TimelineSnap.resolve(
            proposedStart: proposed,
            duration: firstDuration,
            candidates: snapCandidates(moving: []),
            pixelsPerSecond: pixelsPerSecond
        )
    }

    /// 探测一批文件，顺序不变。认不出来、或者读不出时长的会被丢掉。
    ///
    /// 两个探测函数都按 URL 缓存，所以拖动中探过一遍之后，松手这次是白捡的。
    func probeImports(_ urls: [URL]) async -> [MediaFileImport] {
        var result: [MediaFileImport] = []
        for url in urls {
            if MediaFileTypes.isSubtitle(url) { continue }
            // 判断顺序和 `addMedia` 一致（视频 → 图片 → 声音）。两边分类不同的话，
            // 同一个文件拖到时间线上和拖到预览区会变成两种东西。
            if MediaFileTypes.isVideo(url) {
                guard let info = await probeVideo(url), info.duration > 0 else { continue }
                result.append(
                    MediaFileImport(url: url, kind: .video, duration: info.duration, info: info)
                )
            } else if MediaFileTypes.isImage(url) {
                // 图片不用探：时长是产品定的 5 秒（`Self.importedImageDuration`，
                // `addImages` 用的是同一个常量）。
                result.append(
                    MediaFileImport(url: url, kind: .image, duration: Self.importedImageDuration)
                )
            } else if Self.looksLikeAudio(url) {
                guard let duration = await audioDuration(url), duration > 0 else { continue }
                result.append(MediaFileImport(url: url, kind: .audio, duration: duration))
            }
        }
        return result
    }

    /// 拖放 / 粘贴进时间线：读 URL → 探测 → 算落点 → 一次性落地。
    ///
    /// 和 `addMedia` 的分工：那边是**没有落点**的入口（工具栏按钮、拖到时间线
    /// 以外的地方、冒烟钩子），画面接主轨末尾、声音落播放头；这边是**有落点**的
    /// 入口。两边的差别只有「第一段从哪开始、允许落哪条轨」，插进时间线那一步都
    /// 走 `TimelineState.insertImported`。
    func importFiles(
        providers: [NSItemProvider],
        anchor: MediaImportAnchor,
        preferring target: TrackDropTarget?
    ) {
        let generation = documentGeneration
        trackImportTask(Task { [weak self] in
            guard let self else { return }
            let urls = await MediaFileDrag.loadURLs(from: providers)
            guard self.isCurrentGeneration(generation) else { return }
            self.importFiles(urls: urls, anchor: anchor, preferring: target, generation: generation)
        })
    }

    /// 同上，但 URL 已经在手上（⌘V 走这条）。
    func importFiles(
        urls: [URL],
        anchor: MediaImportAnchor,
        preferring target: TrackDropTarget?,
        generation: Int? = nil
    ) {
        let generation = generation ?? documentGeneration
        guard !urls.isEmpty else { return }
        // 字幕没有落点语义（它挂在工程上，不占轨），和落点那条路分开走。
        if let subtitle = urls.first(where: MediaFileTypes.isSubtitle) {
            attachSubtitle(subtitle)
        }
        let media = urls.filter { !MediaFileTypes.isSubtitle($0) }
        guard !media.isEmpty else { return }

        trackImportTask(Task { [weak self] in
            guard let self else { return }
            self.beginBackgroundImport()
            defer { self.endBackgroundImport() }
            var imports = await self.probeImports(media)
            // 探测期间用户可能已经换了工程，这份素材是上一个工程的。
            guard self.isCurrentGeneration(generation), !Task.isCancelled else { return }
            // 引擎没准备好就**一个图片占位块都别放**（同 `addImages` 那道门）：
            // 放了立刻又被 `convertStillClip` 撤掉，用户看到的是块闪一下就没了。
            var blamedEngine = false
            if !self.canConvertStills, imports.contains(where: { $0.kind == .image }) {
                imports.removeAll { $0.kind == .image }
                self.notice = L10n("The video engine is not ready yet.")
                blamedEngine = true
            }
            // 认出来几个报几个：三个视频里有一个坏的，另外两个照样进去。
            // 引擎那条已经报过了就别再盖一遍 —— 后报的会把前一条顶掉，
            // 而「引擎没好」才是用户要看的那条。
            if imports.count < media.count, !blamedEngine {
                self.noticeForUnusable(media.filter { url in !imports.contains { $0.url == url } })
            }
            guard let first = imports.first else { return }

            let start = self.importFirstStart(anchor: anchor, firstDuration: first.duration).start
            let landings = self.state.mediaImportLandings(
                imports.map(\.item),
                firstStart: start,
                preferring: target
            )
            let clips = imports.map { self.clip(for: $0) }
            self.perform { $0.insertImported(clips, at: landings) }

            // 图片是**先上轨再转静帧**（占位块马上能拖能剪），转完无感替换。
            // 逐个 await：和 `addImages` 同一条路，任务活到全部转完为止，
            // 这样它才在 `trackImportTask` 的登记里，切工程时能被取消。
            for (clip, media) in zip(clips, imports) where media.kind == .image {
                await self.convertStillClip(clip.id, from: media.url, generation: generation)
            }
        })
    }

    /// ⌘V：把剪贴板上的文件落到播放头上。
    ///
    /// 落点口径和拖放共用一套（撞上了就往上抬一轨），差别只有锚点 ——
    /// 没有指针，所以第一段的**起点**就是播放头（同按 `+`）。
    @discardableResult
    func pasteMediaFiles() -> Bool {
        let urls = MediaFileDrag.pasteboardURLs()
        guard !urls.isEmpty else { return false }
        importFiles(urls: urls, anchor: .start(clock.time), preferring: nil)
        return true
    }

    /// 探测好的素材 → 时间线上的一段。起点由 `insertImported` 按落点写。
    private func clip(for media: MediaFileImport) -> EditClip {
        switch media.kind {
        case .video:
            return EditClip(
                sourceURL: media.url,
                sourceDuration: media.duration,
                info: media.info
            )
        case .audio:
            return EditClip(
                sourceURL: media.url,
                isAudioOnly: true,
                sourceDuration: media.duration,
                audioAssetDuration: media.duration
            )
        case .image:
            var clip = EditClip(
                sourceURL: media.url,
                sourceDuration: media.duration,
                stillImageURL: media.url
            )
            clip.needsStillConversion = true
            return clip
        }
    }

    /// 一个都认不出来 / 有几个读不出来时的提示。
    ///
    /// **不能不吭声**：静默丢掉的话，「其实不支持这种文件」和「支持但落在你看不见
    /// 的地方」在界面上长得一模一样，用户只会觉得拖放坏了。
    private func noticeForUnusable(_ urls: [URL]) {
        guard let first = urls.first else { return }
        if urls.count == 1 {
            notice = String(format: L10n("Could not use %@ as a clip."), first.lastPathComponent)
        } else {
            notice = String(
                format: L10n("Could not use %d of the dropped files as clips."), urls.count
            )
        }
    }
}
