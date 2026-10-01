import Combine
import Foundation

// MARK: - 优化媒体：后台转码队列 + 转好之后停着时换进预览
//
// 管什么：预览窗口的「优化媒体 / 原片」（UserDefaults，不进工程）；每次预览重建落地之后按这份时间线算还差哪些块
//（OptimizedMediaPlan），一块一块在 `MediaReadQueue.proxy` 上转（OptimizedMediaTranscoder），转好记在内存里的那张表
//（builder 重建时拿它换源，OptimizedMediaLookup）；某一段用到的块齐了就请一次重建 —— **只在停着的时候**（播放中
// `replaceCurrentItem` 画面会闪一下，等暂停再换）；老工程缺关键帧间隔的先补探；这台机器的解码速度第一次用到时量一次。
// 不管什么：判据和分块（OptimizedMediaPolicy）、块怎么转（OptimizedMediaTranscoder）、缓存目录（OptimizedMediaStore）、
// 合成里怎么插（CompositionClipInsert）。长期约束见 docs/architecture/optimized-media.md。
//
// 为什么是 `ObservableObject` 而不是工程上的属性：只有工具栏那一个小菜单订阅它（模式、还有几块要转），转码的进度
// 不许叫醒整个编辑器（docs/architecture/preview-perf-ratchet.md 第十节）。

@MainActor
final class OptimizedMediaCoordinator: ObservableObject {
    enum Mode: String {
        case optimized, original
    }

    static let modeDefaultsKey = "optimizedMedia.previewMode"
    /// 块一块块到，停着时最多隔这么久换一次源（每块都换的话长录屏转码期间预览每两秒闪一下）。
    static let swapInterval: TimeInterval = 3

    /// 预览窗口选的：优化媒体（默认）还是原片。
    @Published private(set) var mode: Mode
    /// 还有几块要转（工具栏的小进度）。
    @Published private(set) var pendingCount = 0

    weak var project: VideoEditProject?

    /// 转好的块：源 → 块号 → 块文件。
    private var ready: [URL: [Int: URL]] = [:]
    /// 转不了的源（编码器拒绝、10-bit / HDR……）：这次运行里不再试，照用原片。
    private var failed: Set<URL> = []
    /// 已经从缓存目录读过索引的源。
    private var scanned: Set<URL> = []
    /// 关键帧间隔补探过的源（探不出来也不再探）。
    private var probed: Set<URL> = []
    private var sources: [URL: OptimizedMediaTranscoder.Source] = [:]
    private var decodeFPS: Double?
    private var measuringDecodeSpeed = false
    private var queue: [OptimizedMediaPlan.Job] = []
    private var worker: Task<Void, Never>?
    private var cancelFlag = CancelFlag()
    /// 切工程 +1：路上的转码 / 探测回来对不上就扔。
    private var generation = 0
    private var swapPending = false
    private var lastSwap = Date.distantPast
    private var pauseObserver: AnyCancellable?
    private var swapTimer: Task<Void, Never>?

    final class CancelFlag: @unchecked Sendable {
        var cancelled = false
    }

    init(defaults: UserDefaults = .standard) {
        mode = Mode(rawValue: defaults.string(forKey: Self.modeDefaultsKey) ?? "") ?? .optimized
    }

    /// 预览窗口切「优化媒体 / 原片」：记住，重建一次。
    func setMode(_ mode: Mode) {
        guard mode != self.mode else { return }
        self.mode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.modeDefaultsKey)
        project?.scheduleRebuild()
    }

    /// 重建时问：哪些块能换进合成。「原片」模式什么都不换。
    func lookup(for state: TimelineState) -> OptimizedMediaLookup {
        guard mode == .optimized else { return .none }
        return OptimizedMediaLookup(chunks: ready)
    }

    /// 每次预览重建落地之后：按这份时间线算还差哪些块，排队去转；缺关键帧间隔的源先补探；解码速度没量过先量。
    func sync(state: TimelineState, playhead: Double) {
        guard let project else { return }
        guard mode == .optimized else {
            queue = []
            pendingCount = 0
            return
        }
        probeUnknownKeyframeIntervals(in: state, project: project)
        guard let decodeFPS = ensureDecodeSpeed(sample: OptimizedMediaPlan.pictureClips(in: state).first?.sourceURL) else { return }
        for url in OptimizedMediaPlan.proxySources(in: state, decodeFPS: decodeFPS) where scanned.insert(url).inserted {
            if let index = OptimizedMediaStore.index(for: url), let directory = OptimizedMediaStore.SourceIdentity(url: url).map(OptimizedMediaStore.directory(for:)) {
                var chunks: [Int: URL] = [:]
                for (chunk, record) in index.chunks { chunks[chunk] = directory.appendingPathComponent(record.fileName) }
                if !chunks.isEmpty { ready[url] = chunks }
            }
        }
        touchUsedChunks(in: state)
        queue = OptimizedMediaPlan.jobs(
            in: state, playhead: playhead, decodeFPS: decodeFPS,
            ready: ready.mapValues { Set($0.keys) }, excluded: failed
        )
        pendingCount = queue.count
        startWorkerIfNeeded()
    }

    /// 切工程：路上的全部作废，表清空（块还在磁盘上，下一个工程用到再读索引）。
    func reset() {
        generation += 1
        cancelFlag.cancelled = true
        cancelFlag = CancelFlag()
        worker?.cancel()
        worker = nil
        swapTimer?.cancel()
        swapTimer = nil
        pauseObserver = nil
        queue = []
        pendingCount = 0
        ready = [:]
        failed = []
        scanned = []
        probed = []
        sources = [:]
        swapPending = false
    }

    // MARK: - 探

    private func probeUnknownKeyframeIntervals(in state: TimelineState, project: VideoEditProject) {
        for url in OptimizedMediaPlan.unknownKeyframeIntervals(in: state) where probed.insert(url).inserted {
            let generation = generation
            Task { [weak self] in
                PerfCounters.backgroundReadBegan()
                let interval = await MediaKeyframeProbe.interval(of: url)
                PerfCounters.backgroundReadEnded()
                guard let self, self.generation == generation, let interval else { return }
                // 不算用户改动（不标脏）；写回之后 scheduleRebuild → sync 再来算要不要转。
                project.applyDocumentRepair { state in
                    for clip in state.allClips where clip.sourceURL == url && clip.info != nil && clip.info?.keyframeInterval == nil {
                        state.update(clip.id) { $0.info?.keyframeInterval = interval }
                    }
                }
            }
        }
    }

    /// 这台机器的解码速度：记过就用记的；没有就拿第一段素材量一次（在后台），量完再 sync 一遍。
    private func ensureDecodeSpeed(sample: URL?) -> Double? {
        if let decodeFPS { return decodeFPS }
        if let remembered = DecodeSpeedProbe.remembered() {
            decodeFPS = remembered
            return remembered
        }
        guard !measuringDecodeSpeed, let sample else { return nil }
        measuringDecodeSpeed = true
        let generation = generation
        Task { [weak self] in
            PerfCounters.backgroundReadBegan()
            let measured = await DecodeSpeedProbe.measure(sample: sample)
            PerfCounters.backgroundReadEnded()
            guard let self else { return }
            self.measuringDecodeSpeed = false
            guard let measured else { return }
            DecodeSpeedProbe.remember(measured)
            self.decodeFPS = measured
            guard self.generation == generation, let project = self.project else { return }
            self.sync(state: project.state, playhead: project.clock.time)
        }
        return nil
    }

    // MARK: - 转

    private func startWorkerIfNeeded() {
        guard worker == nil, !queue.isEmpty else { return }
        let generation = generation
        let flag = cancelFlag
        worker = Task { [weak self] in
            while let self, !Task.isCancelled, !flag.cancelled, self.generation == generation, !self.queue.isEmpty {
                let job = self.queue.removeFirst()
                await self.transcode(job, flag: flag, generation: generation)
                guard self.generation == generation else { return }
                self.pendingCount = self.queue.count
            }
            guard let self, self.generation == generation else { return }
            self.worker = nil
            self.pendingCount = queue.count
            self.requestSwapIfIdle(force: true)
        }
    }

    private func transcode(_ job: OptimizedMediaPlan.Job, flag: CancelFlag, generation: Int) async {
        guard let source = await loadSource(job.url) else {
            guard self.generation == generation else { return }
            giveUp(on: job.url, reason: nil)
            return
        }
        guard self.generation == generation, !flag.cancelled else { return }
        PerfCounters.backgroundReadBegan()
        let result = await MediaReadQueue.run(on: MediaReadQueue.proxy) {
            OptimizedMediaTranscoder.transcode(source, chunk: job.chunk, isCancelled: { flag.cancelled })
        }
        PerfCounters.backgroundReadEnded()
        guard self.generation == generation else { return }
        switch result {
        case .success(let url):
            let completesAClip = completesSomeClip(url: job.url, chunk: job.chunk)
            ready[job.url, default: [:]][job.chunk] = url
            if completesAClip { swapPending = true }
            requestSwapIfIdle(force: false)
        case .failure(.cancelled):
            break
        case .failure(let failure):
            giveUp(on: job.url, reason: failure)
        }
    }

    private func loadSource(_ url: URL) async -> OptimizedMediaTranscoder.Source? {
        if let source = sources[url] { return source }
        guard case .success(let source) = await OptimizedMediaTranscoder.load(url) else { return nil }
        sources[url] = source
        return source
    }

    private func giveUp(on url: URL, reason: OptimizedMediaTranscoder.Failure?) {
        failed.insert(url)
        queue.removeAll { $0.url == url }
        pendingCount = queue.count
        guard let project else { return }
        // 一个源转不了就用原片，提示条说一句，不反复重试（同一次运行里不再报）。
        project.notice = String(format: L10n("Couldn’t prepare optimized media for %@; the preview uses the original file."), url.lastPathComponent)
        _ = reason
    }

    /// 这一块转好之后，有没有哪一段用到的块刚好齐了（之前差它）。
    private func completesSomeClip(url: URL, chunk: Int) -> Bool {
        guard let project else { return false }
        var after = ready
        after[url, default: [:]][chunk] = url
        let before = OptimizedMediaLookup(chunks: ready), now = OptimizedMediaLookup(chunks: after)
        return OptimizedMediaPlan.pictureClips(in: project.state).contains { clip in
            clip.sourceURL == url && before.readyChunks(for: clip) == nil && now.readyChunks(for: clip) != nil
        }
    }

    /// 用到的块：最后用到的时间改成现在（LRU 的依据）。写索引走 proxy 队列，和转码串着、不在主线程上。
    private func touchUsedChunks(in state: TimelineState) {
        var used: [URL: Set<Int>] = [:]
        let lookup = OptimizedMediaLookup(chunks: ready)
        for clip in OptimizedMediaPlan.pictureClips(in: state) {
            guard let chunks = lookup.readyChunks(for: clip) else { continue }
            used[clip.sourceURL, default: []].formUnion(chunks.keys)
        }
        guard !used.isEmpty else { return }
        MediaReadQueue.proxy.addOperation {
            for (url, chunks) in used { OptimizedMediaStore.touch(url, chunks: Array(chunks)) }
        }
    }

    // MARK: - 换进预览（只在停着时）

    /// 有段的块齐了就请一次重建；播放中等暂停；块一块块到时最多隔 `swapInterval` 换一次，队列空了（`force`）马上换。
    private func requestSwapIfIdle(force: Bool) {
        guard swapPending, let project else { return }
        if project.clock.isPlaying {
            observePause(project)
            return
        }
        let since = Date().timeIntervalSince(lastSwap)
        if !force, since < Self.swapInterval {
            guard swapTimer == nil else { return }
            swapTimer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((Self.swapInterval - since) * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.swapTimer = nil
                self.requestSwapIfIdle(force: true)
            }
            return
        }
        swapPending = false
        lastSwap = Date()
        project.scheduleRebuild()
    }

    private func observePause(_ project: VideoEditProject) {
        guard pauseObserver == nil else { return }
        pauseObserver = project.clock.$isPlaying
            .filter { !$0 }
            .first()
            .sink { [weak self] _ in
                self?.pauseObserver = nil
                self?.requestSwapIfIdle(force: true)
            }
    }
}
