import AVFoundation
import AppKit
import SwiftUI
import SrtFlowCore

/// 时间线的鼠标工具（对齐 CapCut：选择 A / 分割 B）。
enum TimelineTool: String, CaseIterable, Identifiable {
    case select
    case split

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: return "Select"
        case .split: return "Split"
        }
    }

    var icon: String {
        switch self {
        case .select: return "cursorarrow"
        case .split: return "rectangle.split.2x1"
        }
    }

    /// 菜单里展示的单键快捷键。
    var shortcutLabel: String {
        switch self {
        case .select: return "A"
        case .split: return "B"
        }
    }
}

/// 视频编辑器的全部可变状态。
///
/// 跟压缩/烧录的队列一样是全局单例：切到别的栏目视图会被销毁，时间线和
/// 正在播的预览必须留着。所有会改时间线的操作都走 `perform`，那里统一做
/// 磁吸排列、撤销登记和预览重建。
@MainActor
final class VideoEditProject: ObservableObject {
    static let shared = VideoEditProject()

    @Published private(set) var state = TimelineState() {
        // 时间线的所有写入最终都落在这里（perform / liveApply / applySnapshot
        // 都是给它赋值），所以脏标记和自动保存挂这一个点就够了。
        didSet {
            // 同一个理由：删字幕轨、外挂新 .srt、重新生成都会换掉整轨 cue 身份，
            // 选中的 cue 可能已经不存在了。收在这唯一入口，别指望每个改字幕的
            // 操作各自记得清一次（PR#22 复审 P2）。
            pruneSubtitleCueSelection()
            pruneMarkerSelection()
            documentDidChange()
        }
    }

    /// 选中的 cue 还在不在当前原文轨上；不在就摘掉选择。
    /// 只在真的选着 cue 时才遍历，拖布局框那种高频写入不额外付代价。
    private func pruneSubtitleCueSelection() {
        guard selection.subtitleCueID != nil else { return }
        selection.pruneSubtitleCue { id in
            state.subtitle?.cues.contains { $0.id == id } == true
        }
    }

    /// 选中的标记还在不在（段被删、标记被删、撤销、被裁出窗口）。同样收在这个
    /// 唯一入口，别指望每个会动到剪辑的操作各自记得清一次。
    private func pruneMarkerSelection() {
        guard selection.markerRef != nil else { return }
        selection.pruneMarker { state.isMarkerSelectable($0) }
    }

    // MARK: - 工程文档（.srtflowproj）

    // 下面几个由 VideoEditProjectDocument.swift 里的扩展维护（跨文件所以不能
    // 是 private(set)），别的地方只读。
    /// 当前工程存在哪。`nil` 表示还没落过盘的「未命名」工程。
    @Published var documentURL: URL?
    /// 有改动还没写进磁盘。自动保存开着的时候它只会亮一小会儿。
    @Published var hasUnsavedChanges = false
    /// 四层线索都没找回来的素材，界面上标红并提供重新链接。打开工程时填一次，
    /// 之后运行中也会重核对（revalidateMediaLocations）——素材在工程开着的时候
    /// 被挪走同样要亮出来，而不是等预览黑屏。
    @Published var missingMedia: [URL] = []

    /// 运行中素材核对的单飞任务（见 `revalidateMediaLocations`）。
    var mediaRevalidateTask: Task<Void, Never>?

    /// 打开/新建工程期间为真：那时候改 `state` 不该算用户的改动。
    var isLoadingDocument = false
    /// 自动保存的防抖任务。
    var autosaveTask: Task<Void, Never>?

    /// 上次读/写工程时的素材定位表（键是素材路径）。
    ///
    /// 存盘时拿它兜底：素材此刻不可达就沿用旧书签，**绝不能**把还有效的定位
    /// 信息覆盖成 nil。详见 `MediaRecord.init(url:projectDirectory:previous:)`。
    var mediaRecords: [String: MediaRecord] = [:]

    /// 工程文件自己的书签。用户在访达里把**正开着的**工程改名或挪走时，
    /// 靠它把 `documentURL` 跟过去，而不是在旧位置又造一个旧名字的文件。
    var documentBookmark: Data?

    /// 当前工程的代号，每换一个工程 +1。
    ///
    /// 后台导入（探测时长、图片转静帧）是脱手的 Task，工程切走之后它们可能才
    /// 回来。回来时对不上代号就直接丢弃，否则会把素材追加进**新**工程。
    private(set) var documentGeneration = 0

    /// 正在跑的后台导入任务，切工程时要取消。
    private var importTasks: [Task<Void, Never>] = []

    func trackImportTask(_ task: Task<Void, Never>) {
        importTasks.removeAll { $0.isCancelled }
        importTasks.append(task)
    }

    /// 切工程：作废所有还没回来的后台导入。
    func invalidateDocumentGeneration() {
        documentGeneration &+= 1
        for task in importTasks { task.cancel() }
        importTasks.removeAll()
        // 字幕生成/翻译也绑工程：切走就取消，别让旧任务白跑完整个素材、
        // 还占着串行槽挡住新工程的生成。取消对空闲任务是无害的 no-op。
        if #available(macOS 26.0, *) { TranscriptionTask.shared.cancel() }
        if #available(macOS 15.0, *) { TranslationJobCoordinator.shared.cancel() }
    }

    /// 后台任务回来时先问一句：我还是当初那个工程吗？
    func isCurrentGeneration(_ generation: Int) -> Bool {
        generation == documentGeneration
    }

    /// 「打开工程」请求的流水号。
    ///
    /// 连点两个最近工程时，慢的那个可能后回来：没有它的话，先打开的 B 会被
    /// A 的过期结果又顶掉。每次 openProject 进门 +1，await 回来对不上就作废。
    var openRequestToken = 0

    private func documentDidChange() {
        guard !isLoadingDocument else { return }
        hasUnsavedChanges = true
        scheduleAutosave()
    }

    /// 整体换掉时间线：打开工程、新建工程用。不进撤销栈，也不算用户改动。
    func replaceStateForDocument(_ next: TimelineState) {
        isLoadingDocument = true
        state = next
        isLoadingDocument = false
    }

    /// 不算用户改动的时间线修补：打开工程后补静帧、重新链接素材走这里。
    /// 这些改动不该让工程「变脏」，但预览要跟着重建。
    func applyDocumentRepair(_ mutate: (inout TimelineState) -> Void) {
        var next = state
        mutate(&next)
        guard next != state else { return }
        replaceStateForDocument(next)
        scheduleRebuild()
    }

    /// 剪辑 / 形状 / 字幕 cue 三类选择的唯一存放处。互斥规则写在
    /// `EditSelection` 里 —— 下面三个属性只是它的门面，别在任何调用点再手写
    /// 「顺便清一下另一类」。
    @Published private(set) var selection = EditSelection()

    /// 选中的剪辑们。⌘点选可多选，拖任意一个选中块整组一起动。
    var selectedClipIDs: Set<UUID> {
        get { selection.clipIDs }
        set { selection.selectClips(newValue) }
    }
    var selectedShapeID: UUID? {
        get { selection.shapeID }
        set { selection.selectShape(newValue) }
    }
    /// 轨道上选中的字幕 cue（点选出预览拖框用）。不持久化。
    var selectedSubtitleCueID: UUID? {
        get { selection.subtitleCueID }
        set { selection.selectSubtitleCue(newValue) }
    }
    /// 轨道块上选中的标记（高亮它、⌫ 删它）。不持久化。
    var selectedMarkerRef: ClipMarkerRef? {
        get { selection.markerRef }
        set { selection.selectMarker(newValue) }
    }

    /// 四类选择一起清：点预览空白、切工程。
    func clearSelection() {
        selection.clear()
    }

    /// 点选：普通点是单选，⌘/⇧点是加选或取消。
    func select(_ id: UUID, additive: Bool) {
        if additive {
            var ids = selectedClipIDs
            if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
            selectedClipIDs = ids
        } else {
            selectedClipIDs = [id]
        }
    }

    /// 时间线鼠标工具：选择（点选/拖动），或分割（刀片 —— 点哪儿切哪儿）。
    /// 单键 A/B 切换，跟工具栏 Add 旁边的下拉是同一份状态。不持久化。
    @Published var activeTool: TimelineTool = .select

    // 三个开关，对应截图里的磁吸、吸附、链接。
    @Published var magnetEnabled = true {
        didSet { if magnetEnabled { perform { $0.packMain() } } }
    }
    @Published var snappingEnabled = true
    @Published var linkageEnabled = true

    /// 时间线缩放：一秒画多少点。
    ///
    /// **写它一律经 `setPixelsPerSecond`**（或本身就受限的 Slider）。捏合曾经
    /// 直接赋值且只查 `isFinite`，能把比例压到 1 以下 —— 那时块的位移换算
    /// （`translation / pps`）会被 `max(pps, 1)` 兜底钳住，1:1 跟手当场坏掉：
    /// 鼠标走 100 点、块只走 50 点。
    @Published var pixelsPerSecond: Double = 24

    /// 缩放的合法区间。工具栏按钮、滑块、捏合共用这一份。
    static let zoomRange: ClosedRange<Double> = 4...120

    /// 唯一的缩放入口：夹进 `zoomRange`，非法值原样丢弃。
    func setPixelsPerSecond(_ value: Double) {
        guard value.isFinite else { return }
        pixelsPerSecond = min(max(value, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
    }

    // 各类轨道的行高。有时块太小看不清，在轨道头上下拖就能调，记住上次的值。
    @Published var mainRowHeight: Double {
        didSet { UserDefaults.standard.set(mainRowHeight, forKey: "editMainRowHeight") }
    }
    @Published var overlayRowHeight: Double {
        didSet { UserDefaults.standard.set(overlayRowHeight, forKey: "editOverlayRowHeight") }
    }
    @Published var audioRowHeight: Double {
        didSet { UserDefaults.standard.set(audioRowHeight, forKey: "editAudioRowHeight") }
    }

    /// 正在后台导入的素材数（图片转静帧、探测时长时给个转圈，别让人以为拖丢了）。
    @Published private(set) var importingCount = 0

    /// 定格正在跑（抽帧 → 写图 → 转码 → 提交）。单飞开关，只由
    /// `VideoEditFreezeFrame` 写：期间按钮置灰，连按 ⇧⌘F 不会并发出两段。
    @Published var isFreezing = false

    // 转圈计数的增减。`importingCount` 的 setter 是 private，别的文件里的后台
    // 流程（定格）经这两个口子记账。
    func beginBackgroundImport() { importingCount += 1 }
    func endBackgroundImport() { importingCount = max(0, importingCount - 1) }

    /// 预览播放器。0.05s 的回调间隔，字幕叠层和播放头才跟得上。
    let clock = PlayerClock(observationInterval: 0.05)

    /// 预览合成的输出尺寸（第一段主轨素材定的）。字幕叠层按它换算。
    @Published private(set) var renderSize = CGSize(width: 1920, height: 1080)
    /// 预览是否正在重建（大工程时给个转圈）。
    @Published private(set) var isRebuildingPreview = false
    /// 素材探测失败之类需要用户看见的话。
    @Published var notice: String?

    /// 撤销登记走窗口的 UndoManager，⌘Z/⇧⌘Z 和菜单原生可用。视图出现时塞进来。
    weak var undoManager: UndoManager?

    private var infoCache: [URL: MediaInfo] = [:]
    private var audioDurationCache: [URL: Double] = [:]
    private var rebuildTask: Task<Void, Never>?
    /// 预览重建的代数，旧的构建结果回来晚了就直接扔。
    private var rebuildGeneration = 0

    private init() {
        let defaults = UserDefaults.standard
        let stored = { (key: String, fallback: Double) -> Double in
            let value = defaults.double(forKey: key)
            return value > 0 ? value : fallback
        }
        mainRowHeight = stored("editMainRowHeight", 54)
        overlayRowHeight = stored("editOverlayRowHeight", 38)
        audioRowHeight = stored("editAudioRowHeight", 34)

        // 素材在工程开着的时候也可能被改名/挪走，而去访达动文件必然让 App
        // 失焦 —— 一激活就重核对，轨道块名字和丢失提示当场跟上。
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.revalidateMediaLocations() }
        }
    }

    /// 恰好选中一个时的那一个（检查器只在单选时展示细节）。
    var selectedClip: EditClip? {
        guard selectedClipIDs.count == 1, let id = selectedClipIDs.first else { return nil }
        return state.clip(with: id)
    }

    var selectedShape: ShapeAnnotation? {
        selectedShapeID.flatMap { id in state.shapes.first { $0.id == id } }
    }

    var duration: Double { state.duration }

    // MARK: - 所有修改的必经之路

    /// 一步到位的修改：登记撤销、磁吸排列、重建预览。
    /// `rebuildsPreview: false` 给只影响叠层（形状）不影响 AV 合成的改动。
    func perform(rebuildsPreview: Bool = true, _ mutate: (inout TimelineState) -> Void) {
        // 有连续编辑挂着（比如滑块拖到一半直接点了按钮）就先把它结成一步。
        endLiveEdit(rebuildsPreview: false)
        let before = state
        var next = state
        mutate(&next)
        if magnetEnabled { next.packMain() }
        guard next != before else { return }
        registerUndo(before)
        state = next
        if rebuildsPreview { scheduleRebuild() }
    }

    // MARK: - 连续修改（拖动、滑块）

    /// 拖动或拖滑块这类连续动作：开始时抓一份快照，过程中**每次都从快照重放**
    /// （绝对增量，幂等），结束时才把整个动作登记成一步撤销。
    private var liveEditSnapshot: TimelineState?

    /// 手势开始时的状态，拖动回调里读原始值用。
    var liveEditOrigin: TimelineState? { liveEditSnapshot }

    func beginLiveEdit() {
        if liveEditSnapshot == nil { liveEditSnapshot = state }
    }

    /// 从快照出发应用一次完整修改。反复调用不会叠加。
    func liveApply(_ mutate: (inout TimelineState) -> Void) {
        beginLiveEdit()
        guard var next = liveEditSnapshot else { return }
        mutate(&next)
        if magnetEnabled { next.packMain() }
        state = next
    }

    func endLiveEdit(rebuildsPreview: Bool = true) {
        guard let snapshot = liveEditSnapshot else { return }
        liveEditSnapshot = nil
        guard state != snapshot else { return }
        registerUndo(snapshot)
        if rebuildsPreview { scheduleRebuild() }
    }

    /// 放弃连续编辑，回到手势开始前。跨轨拖动落地时用：水平的预挪先回滚，
    /// 让 relocate 独立成完整的一步撤销。
    func cancelLiveEdit() {
        guard let snapshot = liveEditSnapshot else { return }
        liveEditSnapshot = nil
        state = snapshot
    }

    /// 拖动剪辑**落地**：把这一组块整体挪到 `proposed`，一步撤销、一次预览重建。
    ///
    /// 拖动**过程**中一个字都不写进 `state` —— 块的位置在拖动期间只是渲染偏移
    /// （见 `ClipDragSession`）。每一拍改 state 会连带整个编辑器视图树（预览区、
    /// 检查器、所有剪辑块）重建、还要重挂一次自动保存，mouseDragged 随即积压，
    /// 块就追不上光标了。
    ///
    /// 多选时拖任何一个选中块，其余选中的和链接的伙伴保持相对错位一起动。
    /// 主轨磁吸开着时按中心插空，插入位置与拖动中那条指示线走同一个函数。
    func commitDrag(_ plan: ClipDragPlan, resolution: DragResolution, crossTrack target: RowTarget?) {
        let magnet = magnetEnabled
        // 水平平移、跨轨搬运、磁吸插空全都收在**一次** perform 里：一步撤销，
        // 也不会出现「视频换了轨、链接音频还留在旧时刻」的 A/V 错位。
        // 状态变换本身是纯值的（`TimelineState.applyDrag`），自检够得着。
        perform { state in
            state.applyDrag(plan, resolution: resolution, crossTrack: target, magnet: magnet)
        }
        if target != nil { selectedClipIDs = [plan.draggedID] }
    }

    /// 手势开始时冻结这一轮拖动的全部输入。之后每一拍只喂一个 `desiredDelta`，
    /// 渲染和落地都走 `plan.resolve` —— 落点只有这一份算法。
    func dragPlan(draggedID id: UUID, slot: TrackSlot) -> ClipDragPlan? {
        let movingIDs = movingClipIDs(draggedID: id)
        return ClipDragPlan.make(
            in: state,
            draggedID: id,
            movingIDs: movingIDs,
            candidates: snapCandidates(moving: movingIDs),
            magnetMain: slot.isMain && magnetEnabled
        )
    }

    /// 形状块的拖动会话。形状行允许重叠，所以没有障碍；其余（冻结候选、
    /// 自由落点、边缘自动滚动）与剪辑走**同一套**。
    func shapeDragPlan(shapeID id: UUID) -> ClipDragPlan? {
        guard let shape = state.shapes.first(where: { $0.id == id }) else { return nil }
        let span = TimelineSpan(start: shape.timelineStart, end: shape.timelineEnd)
        return ClipDragPlan(
            draggedID: id,
            draggedSpan: span,
            members: [ClipDragPlan.Member(id: id, span: span, obstacles: [])],
            candidates: snapCandidates(moving: [id]),
            magnet: nil
        )
    }

    /// 形状拖动落地：一步撤销，不重建预览（叠层是 SwiftUI 画的）。
    func commitShapeDrag(_ plan: ClipDragPlan, resolution: DragResolution) {
        perform(rebuildsPreview: false) { state in
            for member in plan.members {
                state.updateShape(member.id) { $0.timelineStart = max(0, member.span.start + resolution.delta) }
            }
        }
    }

    /// 拖 `id` 时会跟着一起动的块（含它自己）：链接组的伙伴 + 多选的其他块。
    ///
    /// 吸附候选、渲染偏移、落地三处必须用**同一份**名单：谁在动谁就不能同时
    /// 当别人的对齐参考点。
    func movingClipIDs(draggedID id: UUID) -> Set<UUID> {
        var ids: Set<UUID> = [id]
        if linkageEnabled { ids.formUnion(state.linkedClipIDs(of: id)) }
        if selectedClipIDs.contains(id) { ids.formUnion(selectedClipIDs) }
        return ids
    }

    /// 拖剪辑两端裁切（实时版本）。`deltaSeconds` 是手势开始以来的总位移。
    func liveTrim(_ id: UUID, leading: Bool, deltaSeconds: Double) {
        beginLiveEdit()
        liveApply { state in
            state.update(id) { clip in
                if leading {
                    let maxExtend = clip.sourceStart / clip.speed
                    let maxShrink = clip.timelineDuration - 0.1
                    let delta = min(max(deltaSeconds, -maxExtend), maxShrink)
                    clip.sourceStart += delta * clip.speed
                    clip.sourceDuration -= delta * clip.speed
                    clip.timelineStart += delta
                } else {
                    let maxExtend = (clip.assetDuration - clip.sourceStart - clip.sourceDuration) / clip.speed
                    let maxShrink = -(clip.timelineDuration - 0.1)
                    let delta = min(max(deltaSeconds, maxShrink), maxExtend)
                    clip.sourceDuration += delta * clip.speed
                }
            }
        }
    }

    /// 视图给的 UndoManager 首次出现时常常还是 nil，注册进去就全丢了。
    /// 兜底拿键窗口的，⌘Z 才靠得住。
    var effectiveUndoManager: UndoManager? {
        undoManager ?? NSApp.keyWindow?.undoManager
    }

    private func registerUndo(_ snapshot: TimelineState) {
        let manager = effectiveUndoManager
        manager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.applySnapshot(snapshot)
            }
        }
        manager?.setActionName(L10n("Edit Timeline"))
    }

    private func applySnapshot(_ snapshot: TimelineState) {
        let current = state
        effectiveUndoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.applySnapshot(current)
            }
        }
        state = snapshot
        // 撤销/重做可能把选中的剪辑整个撤没（cue 那一侧由 state 的 didSet 收）。
        selection.pruneClips { state.clip(with: $0) != nil }
        // 撤销可能把「还在转静帧」的占位块带回来，转换要是早就完成了，当场补上。
        repairPendingStills()
        scheduleRebuild()
    }

    /// 把已经转完静帧的占位图片块补成真素材（不进撤销栈）。
    private func repairPendingStills() {
        var next = state
        var changed = false
        for clip in next.allClips where clip.needsStillConversion {
            // 查缓存要带上这一段自己的分辨率政策，见 `needsNativeResolution` 的注释。
            guard let image = clip.stillImageURL,
                  let video = StillImageClipFactory.cachedStillVideo(
                    for: image,
                    nativeResolution: StillImageClipFactory.needsNativeResolution(for: clip.info?.displaySize)
                  ) else { continue }
            let info = infoCache[video]
            next.update(clip.id) { pending in
                pending.sourceURL = video
                pending.needsStillConversion = false
                if let info { pending.info = info }
            }
            changed = true
        }
        if changed { state = next }
    }

    // MARK: - 添加素材

    /// 按类型分流：字幕进字幕轨，音频进音频轨，图片先转成静帧视频，
    /// 视频上主轨（或画中画轨）。
    func addMedia(urls: [URL], videosToOverlay: Bool = false) {
        let subtitles = urls.filter(MediaFileTypes.isSubtitle)
        let videos = urls.filter(MediaFileTypes.isVideo)
        let images = urls.filter(MediaFileTypes.isImage)
        let audios = urls.filter { url in
            !MediaFileTypes.isVideo(url) && !MediaFileTypes.isSubtitle(url)
                && !MediaFileTypes.isImage(url) && Self.looksLikeAudio(url)
        }

        if let subtitle = subtitles.first { attachSubtitle(subtitle) }
        // 这三个都是脱手的后台任务，登记下来好在切工程时取消。
        // 工程代号要在**创建 Task 之前**抓：Task 创建后未必立刻跑，等它跑起来
        // 时用户可能已经切了工程 —— 那时在任务体里读到的就是新工程的代号，
        // 守卫形同虚设，旧素材照样进新工程。
        let generation = documentGeneration
        if !videos.isEmpty {
            trackImportTask(Task { await addVideos(videos, toOverlay: videosToOverlay, generation: generation) })
        }
        if !images.isEmpty {
            trackImportTask(Task { await addImages(images, toOverlay: videosToOverlay, generation: generation) })
        }
        if !audios.isEmpty {
            trackImportTask(Task { await addAudios(audios, generation: generation) })
        }
    }

    static func looksLikeAudio(_ url: URL) -> Bool {
        ["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "ogg", "opus", "wma", "caf"]
            .contains(url.pathExtension.lowercased())
    }

    /// 视频素材：探测完再上轨，时长、尺寸一步到位。
    /// `generation` 是**发起导入那一刻**的工程代号（默认取当前的，给冒烟钩子
    /// 之类的同步调用方用）。任务体里各处都要拿它复核。
    func addVideos(_ urls: [URL], toOverlay: Bool, generation: Int? = nil) async {
        let generation = generation ?? documentGeneration
        guard isCurrentGeneration(generation), !Task.isCancelled else { return }
        importingCount += urls.count
        defer { importingCount = max(0, importingCount - urls.count) }
        for url in urls {
            guard let info = await probeVideo(url) else {
                // 失败提示也要验代号：报的是旧工程素材的错，别写到新工程脸上。
                if isCurrentGeneration(generation) {
                    notice = String(format: L10n("Could not read video information from %@."), url.lastPathComponent)
                }
                continue
            }
            // 探测期间用户可能已经换了工程，这份素材是上一个工程的，别往新的里塞。
            guard isCurrentGeneration(generation) else { return }
            let playhead = clock.time
            perform { state in
                var clip = EditClip(sourceURL: url, sourceDuration: info.duration, info: info)
                if toOverlay {
                    // 画中画：落在播放头上，直觉就是「现在看到的地方叠一个」。
                    clip.timelineStart = playhead
                    _ = state.place(clip, intoAudio: false)
                } else {
                    clip.timelineStart = state.mainClips.last?.timelineEnd ?? 0
                    state.mainClips.append(clip)
                }
            }
        }
    }

    func addAudios(_ urls: [URL], generation: Int? = nil) async {
        let generation = generation ?? documentGeneration
        guard isCurrentGeneration(generation), !Task.isCancelled else { return }
        importingCount += urls.count
        defer { importingCount = max(0, importingCount - urls.count) }
        for url in urls {
            guard let duration = await audioDuration(url), duration > 0 else {
                if isCurrentGeneration(generation) {
                    notice = String(format: L10n("Could not read %@."), url.lastPathComponent)
                }
                continue
            }
            guard isCurrentGeneration(generation) else { return }
            let playhead = clock.time
            perform { state in
                let clip = EditClip(
                    sourceURL: url,
                    isAudioOnly: true,
                    sourceDuration: duration,
                    timelineStart: playhead,
                    audioAssetDuration: duration
                )
                _ = state.place(clip, intoAudio: true)
            }
        }
    }

    /// 图片：**立即**上轨（占位块马上能拖能剪），ffmpeg 在后台把它转成静帧
    /// 循环视频，转完无感替换 —— 之后转场、变速、画中画全都不用特判。
    func addImages(_ urls: [URL], toOverlay: Bool, generation: Int? = nil) async {
        guard let ffmpeg = MediaToolchain.shared.runtime?.url else {
            notice = L10n("The video engine is not ready yet.")
            return
        }
        let generation = generation ?? documentGeneration
        guard isCurrentGeneration(generation), !Task.isCancelled else { return }
        importingCount += urls.count
        defer { importingCount = max(0, importingCount - urls.count) }
        for url in urls {
            guard isCurrentGeneration(generation) else { return }
            let clipID = UUID()
            let playhead = clock.time
            perform(rebuildsPreview: false) { state in
                var clip = EditClip(
                    id: clipID,
                    sourceURL: url,
                    sourceDuration: 5,
                    stillImageURL: url
                )
                clip.needsStillConversion = true
                if toOverlay {
                    clip.timelineStart = playhead
                    _ = state.place(clip, intoAudio: false)
                } else {
                    clip.timelineStart = state.mainClips.last?.timelineEnd ?? 0
                    state.mainClips.append(clip)
                }
            }

            do {
                let still = try await StillImageClipFactory.stillVideo(for: url, ffmpeg: ffmpeg)
                let info = await probeVideo(still)
                // 转换期间可能已经换了工程，或者这个占位块被撤销掉了。
                // 不加这两道判断的话，`state = next` 会把新工程平白标脏。
                guard isCurrentGeneration(generation), state.clip(with: clipID) != nil else { return }
                // 直接替换，不占撤销栈 —— 用户没做任何操作。
                var next = state
                next.update(clipID) { clip in
                    clip.sourceURL = still
                    clip.needsStillConversion = false
                    if let info { clip.info = info }
                }
                state = next
                scheduleRebuild()
            } catch {
                guard isCurrentGeneration(generation) else { return }
                notice = error.localizedDescription
                perform(rebuildsPreview: false) { $0.remove(clipID) }
            }
        }
    }

    /// 要导出的时间线：完整的，或只含选中内容（逻辑在
    /// `TimelineState.selectionForExport`，纯值变换，工程文件自检里有回归）。
    func stateForExport(selectionOnly: Bool) -> TimelineState {
        guard selectionOnly, !selectedClipIDs.isEmpty else { return state }
        return state.selectionForExport(ids: selectedClipIDs)
    }

    func attachSubtitle(_ url: URL) {
        do {
            let document = try SubtitleLoader.load(url)
            perform { state in
                state.subtitle = document
                state.subtitleURL = url
                // 换了原文轨（新 cue ID），旧译文/cueMeta 全部失锚，同一事务清掉。
                state.subtitleCompanion = nil
            }
        } catch {
            notice = error.localizedDescription
        }
    }

    func removeSubtitle() {
        perform { state in
            state.subtitle = nil
            state.subtitleURL = nil
            state.subtitleCompanion = nil
        }
    }

    // MARK: - 剪辑操作

    /// 播放头落在主轨哪一段上（分割、裁切的默认对象）。
    func mainClipAtPlayhead() -> EditClip? {
        state.mainClips.first { $0.contains(time: clock.time) }
    }

    /// 分割：优先选中的、且被播放头穿过的那些段；没选就分播放头下的主轨段。
    /// 链接开着时同组一起分。
    func splitAtPlayhead() {
        let time = clock.time
        var seed: [UUID] = selectedClipIDs
            .compactMap { state.clip(with: $0) }
            .filter { $0.contains(time: time) }
            .map(\.id)
        if seed.isEmpty, let main = mainClipAtPlayhead() {
            seed = [main.id]
        }
        var targets = Set(seed)
        if linkageEnabled {
            for id in seed { targets.formUnion(state.linkedClipIDs(of: id)) }
        }
        guard !targets.isEmpty else { return }

        perform { state in
            for id in targets {
                state.split(clipID: id, at: time)
            }
        }
    }

    /// 刀片工具：在指定时刻切开指定的段（链接开着时同组一起切）。
    func splitClip(_ id: UUID, at time: Double) {
        guard let clip = state.clip(with: id), clip.contains(time: time) else { return }
        let targets = linkageEnabled ? state.linkedClipIDs(of: id) : [id]
        perform { state in
            for member in targets {
                state.split(clipID: member, at: time)
            }
        }
    }


    /// 裁掉播放头左边（或右边）的部分。作用于选中段，其次是播放头下的主轨段。
    func trimToPlayhead(keepRight: Bool) {
        let time = clock.time
        var targetID: UUID?
        if let selected = selectedClip, selected.contains(time: time) {
            targetID = selected.id
        } else if let main = mainClipAtPlayhead() {
            targetID = main.id
        }
        guard let targetID else { return }
        let ids = linkageEnabled ? state.linkedClipIDs(of: targetID) : [targetID]

        perform { state in
            for id in ids {
                state.update(id) { clip in
                    guard clip.contains(time: time) else { return }
                    let cut = (time - clip.timelineStart) * clip.speed
                    if keepRight {
                        clip.sourceStart += cut
                        clip.sourceDuration -= cut
                        clip.timelineStart = time
                    } else {
                        clip.sourceDuration = cut
                    }
                }
            }
        }
    }

    /// ⌫ 与工具栏垃圾桶的唯一入口。
    ///
    /// 分支顺序不重要（四类选择本来就互斥，见 `EditSelection`），但标记必须在
    /// 这里出现 —— 单独给标记接一条删除路径的话，两条路径迟早会对「现在选中的
    /// 是什么」给出不同答案。
    func deleteSelected() {
        if let ref = selectedMarkerRef {
            deleteMarker(ref)
            return
        }
        if let shapeID = selectedShapeID {
            deleteShape(shapeID)
            return
        }
        guard !selectedClipIDs.isEmpty else { return }
        var ids = selectedClipIDs
        if linkageEnabled {
            for id in selectedClipIDs { ids.formUnion(state.linkedClipIDs(of: id)) }
        }
        perform { state in
            for member in ids { state.remove(member) }
        }
        selectedClipIDs = []
    }

    func setSpeed(_ id: UUID, speed: Double) {
        let clamped = min(max(speed, 0.1), 8)
        let ids = linkageEnabled ? state.linkedClipIDs(of: id) : [id]
        perform { state in
            for member in ids {
                state.update(member) { $0.speed = clamped }
            }
        }
    }

    func setTransition(after id: UUID, _ transition: ClipTransition, duration: Double? = nil) {
        perform { state in
            state.update(id) { clip in
                clip.transitionAfter = transition
                if let duration { clip.transitionDuration = min(max(duration, 0.1), 3) }
            }
        }
    }

    /// 把这一段的转场（类型 + 时长）套到主轨的每一个接缝上。
    func applyTransitionToAll(like id: UUID) {
        guard let clip = state.clip(with: id), clip.transitionAfter != .none else { return }
        let transition = clip.transitionAfter
        let duration = clip.transitionDuration
        perform { state in
            for index in state.mainClips.indices.dropLast() {
                state.mainClips[index].transitionAfter = transition
                state.mainClips[index].transitionDuration = duration
            }
        }
    }

    /// 清掉主轨上的所有转场。
    func clearAllTransitions() {
        perform { state in
            for index in state.mainClips.indices {
                state.mainClips[index].transitionAfter = .none
            }
        }
    }

    /// 主轨上还有没有任何转场（Clear all 的可用状态）。
    var hasAnyTransition: Bool {
        state.mainClips.contains { $0.transitionAfter != .none }
    }

    func setVolume(_ id: UUID, volume: Double) {
        perform { state in
            state.update(id) { $0.volume = min(max(volume, 0), 2) }
        }
    }

    func setMuted(_ id: UUID, muted: Bool) {
        perform { state in
            state.update(id) { $0.isMuted = muted }
        }
    }

    func setOverlayLayout(_ id: UUID, fraction: Double? = nil, anchor: OverlayAnchor? = nil) {
        perform { state in
            state.update(id) { clip in
                if let fraction { clip.overlayFraction = min(max(fraction, 0.1), 1) }
                if let anchor { clip.overlayAnchor = anchor }
                // 九宫格和自由摆放是两套模型：点了停靠位就回到九宫格。
                clip.placement = nil
            }
        }
    }

    /// 把视频段的声音分离成音频轨上的一段，两边用链接组绑在一起。
    func detachAudio(from id: UUID) {
        guard let clip = state.clip(with: id), !clip.isAudioOnly, clip.hasAudio, !clip.isMuted else { return }
        perform { state in
            let group = clip.linkGroup ?? UUID()
            // 源还是那个视频文件，isAudioOnly 只表示这段只取它的声音。
            let detached = EditClip(
                sourceURL: clip.sourceURL,
                isAudioOnly: true,
                sourceStart: clip.sourceStart,
                sourceDuration: clip.sourceDuration,
                speed: clip.speed,
                timelineStart: clip.timelineStart,
                volume: clip.volume,
                linkGroup: group,
                info: clip.info,
                audioAssetDuration: clip.info?.duration
            )
            state.update(id) { original in
                original.isMuted = true
                original.linkGroup = group
            }
            _ = state.place(detached, intoAudio: true)
        }
    }

    /// 垂直拖动的落点：某条现有轨，或者在最上/最下开一条新轨。
    /// 垂直拖动能落到的行。定义在 `VideoEditTimelineEdits.swift`（纯值变换，
    /// 自检够得着），这里留个别名给视图沿用旧名字。
    typealias RowTarget = TrackDropTarget


    /// 整轨隐藏/显示（快捷键 V）。隐藏的轨灰显不可编辑，预览和导出都跳过。
    func toggleLaneHidden(_ slot: TrackSlot) {
        perform { state in
            switch slot {
            case .main:
                state.mainHidden.toggle()
            case .overlay(let index):
                if state.overlayTracks.indices.contains(index) {
                    state.overlayTracks[index].isHidden.toggle()
                }
            case .audio(let index):
                if state.audioTracks.indices.contains(index) {
                    state.audioTracks[index].isHidden.toggle()
                }
            }
        }
    }

    /// **原文**字幕轨的眼睛。语义与其他轨道一致：预览和烧录都跳过。
    /// 字幕不参与 AV 合成，不用重建预览播放器。
    func toggleSubtitleHidden() {
        perform(rebuildsPreview: false) { $0.subtitleHidden.toggle() }
    }

    /// **译文**字幕轨的眼睛。一个语言一条轨，两只眼睛推导出预览/烧录内容
    /// （`TimelineState.visibleSubtitleChoice`）—— 没有额外的模式选择器。
    func toggleTranslationHidden() {
        perform(rebuildsPreview: false) { $0.translationHidden.toggle() }
    }

    /// 预览拖框实时写入工程级字幕布局（liveApply 连续编辑，松手
    /// endLiveEdit(rebuildsPreview: false) 合成一步撤销；字幕不参与 AV 合成）。
    func liveSetSubtitleLayout(_ layout: SubtitleLayout) {
        liveApply { $0.subtitleLayout = layout }
    }

    /// 点选字幕 cue：与剪辑、形状选择都互斥（互斥规则在 `EditSelection`）。
    func selectSubtitleCue(_ id: UUID) {
        selectedSubtitleCueID = id
    }

    /// 画布**被用户改过多少次**。
    ///
    /// 录屏导入要判断「能不能自动套用录制比例」。只比对比例**值**不够：
    /// 用户在录制期间改成 16:9 又改回 auto，值没变但他其实动过 —— 那就不该
    /// 再被自动覆盖（计划 §20 点名的用例）。所以值和这个代号都没变才算数。
    /// 不持久化：只在本次会话内有意义。
    @Published private(set) var canvasEditGeneration = 0

    /// 画布比例：预览和导出共用，改动可撤销。
    func setCanvasRatio(_ ratio: CanvasRatio) {
        canvasEditGeneration += 1
        perform { $0.canvasRatio = ratio }
        // 立刻更新预览框的形状，不等合成重建。
        renderSize = VideoEditCompositionBuilder.renderSize(for: state)
    }

    /// 工程帧率：预览合成、两条导出管线、预渲染、关键帧容差的唯一事实来源。
    /// 改动可撤销。`perform` 默认就会 scheduleRebuild —— 必须重建，否则
    /// videoComposition 还停在旧的 frameDuration 上。
    func setFrameRate(_ rate: ProjectFrameRate) {
        // 帧率在 request 生成后冻结：录制中改它会让已冻结的捕获配置与工程不一致
        // （计划 §11.3）。菜单已置灰，这里是**执行入口**的二道闸。
        if #available(macOS 15.0, *), ScreenRecordingCoordinator.shared.isBusy {
            notice = L10n("The frame rate is locked while recording.")
            return
        }
        guard rate != state.frameRate else { return }
        perform { $0.frameRate = rate }
    }

    /// V 键：切换选中剪辑所在的轨；什么都没选就切主轨。
    func toggleHiddenForSelectionLane() {
        if let id = selectedClipIDs.first, let location = state.location(of: id) {
            toggleLaneHidden(location.track)
        } else {
            toggleLaneHidden(.main)
        }
    }

    /// 主轨 ↔ 画中画轨。
    func toggleOverlay(_ id: UUID) {
        guard let location = state.location(of: id), let clip = state.clip(with: id), !clip.isAudioOnly else { return }
        perform { state in
            state.remove(id)
            var moved = clip
            switch location.track {
            case .main:
                _ = state.place(moved, intoAudio: false)
            case .overlay:
                moved.transitionAfter = .none
                state.mainClips.append(moved)
                if !magnetEnabled {
                    moved.timelineStart = state.mainClips.dropLast().map(\.timelineEnd).max() ?? 0
                    state.mainClips[state.mainClips.count - 1] = moved
                }
            case .audio:
                break
            }
        }
    }

    // MARK: - 形状标注

    /// 在播放头处放一个形状，默认 3 秒，放完就选中它好接着调。
    func addShape(_ kind: ShapeKind) {
        let start = clock.time
        let shape: ShapeAnnotation
        switch kind {
        case .line:
            shape = ShapeAnnotation(kind: kind, timelineStart: start, width: 0.3, height: 0)
        case .rectangle:
            shape = ShapeAnnotation(kind: kind, timelineStart: start, width: 0.3, height: 0.22)
        case .square:
            shape = ShapeAnnotation(kind: kind, timelineStart: start, width: 0.2, height: 0.2)
        }
        perform(rebuildsPreview: false) { $0.shapes.append(shape) }
        selectedShapeID = shape.id
    }

    /// 形状不参与 AV 合成（叠层是 SwiftUI 画的），改它不用重建预览。
    func updateShape(_ id: UUID, _ change: @escaping (inout ShapeAnnotation) -> Void) {
        perform(rebuildsPreview: false) { $0.updateShape(id, change) }
    }

    func deleteShape(_ id: UUID) {
        perform(rebuildsPreview: false) { state in
            state.shapes.removeAll { $0.id == id }
        }
        if selectedShapeID == id { selectedShapeID = nil }
    }

    /// 此刻画面上该显示的形状。
    func visibleShapes(at time: Double) -> [ShapeAnnotation] {
        state.shapes.filter { $0.contains(time: time) }
    }

    // MARK: - 吸附

    /// 这一轮拖动的吸附参考点（0、播放头、时间线末尾、不动的块的两端）。
    ///
    /// **手势开始时算一次就冻住**，拖动中别再重算 —— 理由见
    /// `TimelineSnap.candidates`。吸附关掉时返回空表：`TimelineSnap.resolve`
    /// 拿到空候选就原样返回，既不吸也不亮线。
    func snapCandidates(moving movingIDs: Set<UUID>) -> [Double] {
        guard snappingEnabled else { return [] }
        return TimelineSnap.candidates(in: state, moving: movingIDs, playhead: clock.time)
    }

    // MARK: - 素材探测

    /// 定格（`VideoEditFreezeFrame`）也要探测生成出来的静帧视频，所以不是 private。
    func probeVideo(_ url: URL) async -> MediaInfo? {
        if let cached = infoCache[url] { return cached }
        let result = await MediaProbe.probe(url: url, ffmpeg: MediaToolchain.shared.runtime?.url)
        if case .success(let info) = result {
            infoCache[url] = info
            return info
        }
        return nil
    }

    private func audioDuration(_ url: URL) async -> Double? {
        if let cached = audioDurationCache[url] { return cached }
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite else { return nil }
        audioDurationCache[url] = duration
        return duration
    }

    // MARK: - 预览重建

    /// 时间线一变就（去抖后）重建预览合成。播放头位置和播放状态都要还原，
    /// 不然每改一刀就跳回 0:00 没法干活。
    func scheduleRebuild() {
        // 重建按旧路径开素材，文件被挪走的话对应时段会静默变黑（builder 对
        // 加载失败的 clip 只能跳过）——先把素材位置重核对一遍，跟得上的当场
        // 改引用再重建一次，跟不上的亮出丢失提示。单飞 + 无变化即收敛，
        // 核对触发的重建不会和这里循环。
        revalidateMediaLocations()
        rebuildGeneration += 1
        let generation = rebuildGeneration
        rebuildTask?.cancel()
        isRebuildingPreview = true
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            let snapshot = self.state
            let built = await VideoEditCompositionBuilder.build(from: snapshot)
            guard !Task.isCancelled, generation == self.rebuildGeneration else { return }
            self.isRebuildingPreview = false
            guard let built else {
                self.clock.detach()
                return
            }
            self.renderSize = built.renderSize
            let wasPlaying = self.clock.isPlaying
            let time = self.clock.time
            let item = AVPlayerItem(asset: built.composition)
            item.videoComposition = built.videoComposition
            item.audioMix = built.audioMix
            // 变速片段保持音调，跟导出时 atempo 的听感一致。
            item.audioTimePitchAlgorithm = .spectral
            self.clock.attachItem(item)
            self.clock.seek(to: min(time, snapshot.duration), precise: true)
            if wasPlaying { self.clock.player.play() }
        }
    }
}
