import Foundation
import SrtFlowCore

/// 主窗口侧边栏上的小角标。切到别的栏目时，靠它知道某个队列还在忙。
enum SidebarActivity: Equatable {
    case running(fraction: Double)
    case finished(count: Int)
    case failed
}

/// 每个视频各自对应的字幕。样式是整批共用的，放在 `EncodeQueue` 上。
struct BurnInRequest: Sendable {
    var subtitleURL: URL?
    var cues: [SubtitleCue]
}

struct EncodeItem: Identifiable {
    enum Status: Equatable {
        case waiting, probing, running, finished, failed, cancelled
    }

    let id = UUID()
    var inputURL: URL
    var outputURL: URL
    var info: MediaInfo?
    var status: Status = .waiting
    var progress: Double = 0
    var speed: Double?
    var etaSeconds: Double?
    var outputBytes: Int64?
    var errorMessage: String?
    var burnIn: BurnInRequest?

    var isActive: Bool { status == .probing || status == .running }
    var isDone: Bool { status == .finished || status == .failed || status == .cancelled }

    /// 体积缩小了多少。负数表示反而变大了。
    var savingFraction: Double? {
        guard let outputBytes, let info, info.fileBytes > 0, status == .finished else { return nil }
        return 1 - Double(outputBytes) / Double(info.fileBytes)
    }
}

/// 串行跑编码任务。
///
/// 刻意不做并行：`libx264 -preset slow` 本身就会吃满所有性能核，同时跑两个只会
/// 互相抢核，总时间不会变短，还让进度看起来忽快忽慢。硬件编码器同理，只有一个。
@MainActor
final class EncodeQueue: ObservableObject {

    @Published private(set) var items: [EncodeItem] = []
    @Published private(set) var isRunning = false

    /// 输出目录。nil 表示跟源文件放一起。
    @Published var outputDirectory: URL?
    @Published var settings: VideoEncodeSettings = .default

    // 烧字幕相关：样式和字体是整批共用的，每个条目只带自己的字幕内容。
    @Published var burnInStyle: BurnInStyle = .default
    @Published var burnInFontURL: URL?
    /// 除了烧进画面，再额外挂一条可开关的软字幕轨。
    @Published var attachSoftSubtitleTrack = false

    /// 输出文件名的后缀，用来区分压缩产物和烧字幕产物。
    let outputSuffix: String
    /// 这个队列是不是必须给每个视频配字幕。
    let requiresSubtitles: Bool

    private var currentProcess: FFmpegProcess?
    private var currentItemID: EncodeItem.ID?

    init(outputSuffix: String, requiresSubtitles: Bool = false) {
        self.outputSuffix = outputSuffix
        self.requiresSubtitles = requiresSubtitles
    }

    // MARK: - 全局唯一的两个队列

    /// 压缩队列。
    ///
    /// 刻意做成全局的，而不是压缩界面自己的 `@StateObject`：主窗口是侧边栏切换，
    /// 切走那一栏的视图会被销毁。队列要是跟着视图走，正在跑的编码就会被中断。
    /// 放在这里，压缩可以在后台一直跑，用户同时去调字幕样式或转格式。
    static let compress = EncodeQueue(outputSuffix: "_compressed")

    /// 烧字幕队列。理由同上。
    static let burnIn = EncodeQueue(outputSuffix: "_sub", requiresSubtitles: true)

    /// 侧边栏那一行要显示的状态：正在跑就报进度，跑完了报个完成数。
    var sidebarActivity: SidebarActivity? {
        if let running = items.first(where: { $0.status == .running }) {
            return .running(fraction: running.progress)
        }
        let finished = items.filter { $0.status == .finished }.count
        if finished > 0, !isRunning { return .finished(count: finished) }
        if items.contains(where: { $0.status == .failed }) { return .failed }
        return nil
    }

    // MARK: - 队列维护

    func add(urls: [URL], burnIn: BurnInRequest? = nil) {
        for url in urls {
            // 同一个文件不重复排队。
            guard !items.contains(where: { $0.inputURL == url && !$0.isDone }) else { continue }
            var item = EncodeItem(
                inputURL: url,
                outputURL: proposedOutputURL(for: url),
                burnIn: burnIn
            )
            item.status = .waiting
            items.append(item)
            probeInfo(for: item.id)
        }
    }

    func remove(id: EncodeItem.ID) {
        if currentItemID == id { cancel(id: id) }
        items.removeAll { $0.id == id }
    }

    func clearFinished() {
        items.removeAll { $0.isDone }
    }

    func removeAll() {
        cancelAll()
        items.removeAll()
    }

    func updateBurnIn(_ burnIn: BurnInRequest?, for id: EncodeItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].burnIn = burnIn
        items[index].errorMessage = nil
    }

    /// 显示一条与执行无关的错误（比如字幕文件读不出来）。
    func setError(_ message: String, for id: EncodeItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].errorMessage = message
    }

    /// 设置变了要重算输出名（比如从压缩切到烧字幕），但只动还没跑的。
    func refreshOutputPaths() {
        for index in items.indices where items[index].status == .waiting {
            items[index].outputURL = proposedOutputURL(for: items[index].inputURL)
        }
    }

    private func proposedOutputURL(for input: URL) -> URL {
        let directory = outputDirectory ?? input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent
        var candidate = directory.appendingPathComponent("\(base)\(outputSuffix).mp4")

        // 绝不能写到源文件上：ffmpeg 同时读写一个文件会把源文件毁掉。
        var counter = 2
        while candidate.standardizedFileURL == input.standardizedFileURL
            || FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)\(outputSuffix) \(counter).mp4")
            counter += 1
            if counter > 999 { break }
        }
        return candidate
    }

    private func probeInfo(for id: EncodeItem.ID) {
        Task {
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            let url = items[index].inputURL
            let result = await MediaProbe.probe(url: url, ffmpeg: MediaToolchain.shared.runtime?.url)
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            switch result {
            case .success(let info):
                items[index].info = info
            case .failure(let error):
                items[index].status = .failed
                items[index].errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - 执行

    var waitingCount: Int { items.filter { $0.status == .waiting }.count }
    var canStart: Bool { !isRunning && waitingCount > 0 && MediaToolchain.shared.runtime != nil }

    func start() {
        guard canStart else { return }
        Task { await runLoop() }
    }

    private func runLoop() async {
        isRunning = true
        defer {
            isRunning = false
            currentItemID = nil
            currentProcess = nil
        }
        // 按 id 找下一个，因为跑的过程中用户可能删掉某几行。
        while let next = items.first(where: { $0.status == .waiting })?.id {
            await run(id: next)
        }
    }

    private func run(id: EncodeItem.ID) async {
        guard let runtime = MediaToolchain.shared.runtime else { return }
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }

        // 信息可能还没探测完，这里等一下。
        if items[index].info == nil {
            items[index].status = .probing
            let url = items[index].inputURL
            let result = await MediaProbe.probe(url: url, ffmpeg: runtime.url)
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            switch result {
            case .success(let info):
                items[index].info = info
            case .failure(let error):
                items[index].status = .failed
                items[index].errorMessage = error.localizedDescription
                return
            }
        }

        guard let index = items.firstIndex(where: { $0.id == id }), let info = items[index].info else { return }
        let item = items[index]

        items[index].status = .running
        items[index].progress = 0
        items[index].errorMessage = nil
        currentItemID = id

        // 烧字幕的临时工作目录：ASS 和字体都放进去，进程的工作目录设成它。
        var jobDirectory: URL?
        var burnInPaths: FFmpegCommand.BurnIn?
        var softSubtitlePath: String?

        if let burnIn = item.burnIn {
            do {
                let prepared = try prepareBurnInDirectory(burnIn, info: info)
                jobDirectory = prepared.directory
                burnInPaths = prepared.paths
                softSubtitlePath = prepared.softSubtitlePath
            } catch {
                items[index].status = .failed
                items[index].errorMessage = error.localizedDescription
                return
            }
        }
        defer {
            if let jobDirectory { try? FileManager.default.removeItem(at: jobDirectory) }
        }

        var command = FFmpegCommand(
            inputPath: item.inputURL.path,
            outputPath: item.outputURL.path,
            settings: settings,
            burnIn: burnInPaths,
            softSubtitlePath: softSubtitlePath,
            hasAudio: info.hasAudio,
            audioCanCopy: info.audioCanCopyToMP4,
            useHardwareDecode: true,
            sourceHeight: info.height,
            sourceFrameRate: info.frameRate > 0 ? info.frameRate : nil
        )

        var lastError: Error?
        // 硬件解码偶尔会在某些奇怪的编码上失败，那就退回纯软解再试一次。
        for attempt in 0..<2 {
            if attempt == 1 {
                guard command.useHardwareDecode else { break }
                command.useHardwareDecode = false
            }
            do {
                try await execute(command: command, runtime: runtime, jobDirectory: jobDirectory, id: id, duration: info.duration)
                lastError = nil
                break
            } catch FFmpegProcessError.cancelled {
                finish(id: id, status: .cancelled, message: nil)
                removePartialOutput(at: item.outputURL)
                return
            } catch {
                lastError = error
            }
        }

        if let lastError {
            finish(id: id, status: .failed, message: lastError.localizedDescription)
            removePartialOutput(at: item.outputURL)
        } else {
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            items[index].outputBytes = MediaProbe.byteSize(of: items[index].outputURL)
            items[index].progress = 1
            items[index].speed = nil
            items[index].etaSeconds = nil
            items[index].status = .finished
        }
    }

    private func execute(
        command: FFmpegCommand,
        runtime: FFmpegRuntime,
        jobDirectory: URL?,
        id: EncodeItem.ID,
        duration: Double
    ) async throws {
        let process = FFmpegProcess()
        currentProcess = process
        defer { currentProcess = nil }

        try await process.run(
            executable: runtime.url,
            arguments: FFmpegArgumentBuilder.arguments(for: command),
            workingDirectory: jobDirectory
        ) { [weak self] progress in
            guard let self, let index = self.items.firstIndex(where: { $0.id == id }) else { return }
            if let fraction = progress.fraction(duration: duration) {
                self.items[index].progress = fraction
            }
            self.items[index].speed = progress.speed
            self.items[index].etaSeconds = progress.remainingSeconds(duration: duration)
        }
    }

    private func finish(id: EncodeItem.ID, status: EncodeItem.Status, message: String?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = status
        items[index].errorMessage = message
        items[index].speed = nil
        items[index].etaSeconds = nil
    }

    /// 失败或取消后留下的半截文件没有意义，直接删掉，免得被当成成品。
    private func removePartialOutput(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - 取消

    func cancel(id: EncodeItem.ID) {
        if currentItemID == id {
            currentProcess?.cancel()
        } else if let index = items.firstIndex(where: { $0.id == id }), items[index].status == .waiting {
            items[index].status = .cancelled
        }
    }

    func cancelAll() {
        for index in items.indices where items[index].status == .waiting {
            items[index].status = .cancelled
        }
        currentProcess?.cancel()
    }

    // MARK: - 烧字幕的准备工作

    private struct PreparedBurnIn {
        var directory: URL
        var paths: FFmpegCommand.BurnIn
        var softSubtitlePath: String?
    }

    private func prepareBurnInDirectory(_ request: BurnInRequest, info: MediaInfo) throws -> PreparedBurnIn {
        let prepared = try BurnInWorkspace.create(
            cues: request.cues,
            style: burnInStyle,
            fontFileURL: burnInFontURL,
            aspectRatio: info.aspectRatio,
            title: request.subtitleURL?.deletingPathExtension().lastPathComponent ?? "SrtFlow"
        )
        let directory = prepared.directory
        let paths = prepared.paths

        var softSubtitlePath: String?
        if attachSoftSubtitleTrack {
            // 软字幕轨用 SRT 喂给 mov_text，样式信息本来也带不进 mp4。
            let srtURL = directory.appendingPathComponent("soft.srt")
            var document = SubtitleDocumentModel(cues: request.cues, format: .srt)
            document.reindex()
            let srt = SubtitleSerializer.serialize(document, format: .srt)
            try Data(srt.utf8).write(to: srtURL)
            softSubtitlePath = srtURL.path
        }

        return PreparedBurnIn(directory: directory, paths: paths, softSubtitlePath: softSubtitlePath)
    }
}
