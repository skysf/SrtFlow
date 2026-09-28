import Foundation

// MARK: - 本机配音模型（Kokoro）的下载、安装、删除
//
// 管什么：从我们自己的 R2（`downloads.skylu.ai/Models/…`，方案第 51 条）读清单，一个文件一个文件下到临时目录、核大小和
// SHA-256，全部对上才一次换进正式目录（半截的永远不会被当成装好了）；断了再下时已经核对过的文件跳过。设置 → AI 里的
// 那一行和 AI 的 `add_voiceover download_voices` 用的是同一次下载（第 50 条：两边都能下，AI 下的时候要告诉用户）。
// 装在 `~/Library/Application Support/SrtFlow/Voices/`，测试版和正式版共用（同音乐库缓存）。
// 不管什么：清单的格式和校验（KokoroVoiceManifest）、怎么读（KokoroVoiceSpeech）。

@MainActor
final class KokoroVoicePack: ObservableObject {
    static let shared = KokoroVoicePack()

    enum State: Equatable {
        case notInstalled
        case downloading(fraction: Double)
        case installed
        case failed(String)
    }

    @Published private(set) var state: State = .notInstalled

    /// 模型文件和清单在 R2 上的文件夹。换模型版本就换一个文件夹（v2），旧版的用户照旧能用装好的那份。
    nonisolated static let baseURL = URL(string: "https://downloads.skylu.ai/Models/Kokoro-82M-CoreML/v1/")!
    /// 清单读到之前，告诉用户大概多大。
    static var approximateSize: String { AIVoiceRole.kokoroDownloadSize }

    /// 冒烟和自检用 `SRTFLOW_VOICES_DIR` 换一个地方下，不碰用户那一份（同 SRTFLOW_MCP_SOCKET 那类测试钩子）。
    nonisolated static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["SRTFLOW_VOICES_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SrtFlow/Voices/Kokoro-82M-CoreML", isDirectory: true)
    }

    nonisolated static var stagingDirectory: URL {
        directory.deletingLastPathComponent().appendingPathComponent(".Kokoro-82M-CoreML.partial", isDirectory: true)
    }

    private var installTask: Task<Void, Error>?
    private var currentDownload: URLSessionDownloadTask?

    private init() { refresh() }

    var isInstalled: Bool { state == .installed }

    var fraction: Double? {
        if case .downloading(let fraction) = state { return fraction }
        return nil
    }

    /// 按硬盘上的样子重新看一眼（设置页出现时、删掉之后）。下载中不动。
    func refresh() {
        guard installTask == nil else { return }
        state = Self.installedManifest() != nil ? .installed : .notInstalled
    }

    /// 装好的那份清单：清单在、每个文件都在、大小对得上才算装好（启动时不逐个算校验值，下载时算过）。
    nonisolated static func installedManifest() -> KokoroVoiceManifest? {
        let url = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url), let manifest = try? KokoroVoiceManifest.decode(data) else { return nil }
        for file in manifest.files {
            let path = directory.appendingPathComponent(file.path).path
            guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64, size == file.size else {
                return nil
            }
        }
        return manifest
    }

    /// 下载并装好；已经在下就等那一次，装好了直接返回。
    func install() async throws {
        if isInstalled { return }
        if let installTask { return try await installTask.value }
        let task = Task { try await self.download() }
        installTask = task
        do {
            try await task.value
            installTask = nil
            state = .installed
        } catch {
            installTask = nil
            state = task.isCancelled || error is CancellationError ? .notInstalled : .failed(error.localizedDescription)
            throw error
        }
    }

    /// 在设置里点「下载」：不等结果（出错显示在那一行上）。
    func startInstall() {
        Task { try? await install() }
    }

    func cancel() {
        installTask?.cancel()
        currentDownload?.cancel()
    }

    /// 删掉装好的模型（和下了一半的）。模型能重新下载，所以直接删、不进废纸篓。
    func remove() {
        cancel()
        KokoroVoiceSpeech.shared.unload()
        try? FileManager.default.removeItem(at: Self.directory)
        try? FileManager.default.removeItem(at: Self.stagingDirectory)
        installTask = nil
        state = .notInstalled
    }

    // MARK: 下载

    private func download() async throws {
        state = .downloading(fraction: 0)
        let manifestData = try await fetch(Self.baseURL.appendingPathComponent("manifest.json"))
        let manifest = try KokoroVoiceManifest.decode(manifestData)
        let staging = Self.stagingDirectory
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let total = Double(max(manifest.totalBytes, 1))
        var done: Int64 = 0
        for file in manifest.files {
            try Task.checkCancellation()
            let target = staging.appendingPathComponent(file.path)
            if await Self.matches(target, file) {
                done += file.size
                state = .downloading(fraction: Double(done) / total)
                continue
            }
            let finished = done
            let temporary = try await downloadFile(Self.baseURL.appendingPathComponent(file.path)) { [weak self] part in
                self?.state = .downloading(fraction: (Double(finished) + part * Double(file.size)) / total)
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: temporary, to: target)
            guard await Self.matches(target, file) else {
                try? FileManager.default.removeItem(at: target)
                throw AIToolError("A downloaded voice file was damaged (\(file.path)). Try the download again.")
            }
            done += file.size
        }
        // 清单最后写：有它才算装好。然后整个文件夹一次换进去。
        try manifestData.write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        let final = Self.directory
        try? FileManager.default.removeItem(at: final)
        try FileManager.default.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: staging, to: final)
    }

    private func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw AIToolError("SrtFlow could not reach its voice download (HTTP \(status)). Check the internet connection and try again.")
        }
        return data
    }

    /// 大小和校验值都对上（算校验值在后台队列上，三百多 MB 约一秒）。
    private static func matches(_ url: URL, _ file: KokoroVoiceManifest.File) async -> Bool {
        let path = url.path
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64, size == file.size else {
            return false
        }
        let expected = file.sha256.lowercased()
        return await MediaReadQueue.run(on: MediaReadQueue.analysis) {
            (try? KokoroVoiceManifest.sha256(of: URL(fileURLWithPath: path))) == expected
        }
    }

    /// 下一个文件到自己的临时位置，下载中按字节报进度（0…1）。
    private func downloadFile(_ url: URL, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let holder = KokoroDownloadHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let task = URLSession.shared.downloadTask(with: url) { location, response, error in
                    holder.observation = nil
                    if let error { return continuation.resume(throwing: error) }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200, let location else {
                        return continuation.resume(throwing: AIToolError("SrtFlow could not download a voice file (HTTP \(status))."))
                    }
                    // 系统给的临时文件在这个回调返回后就被删掉，先挪到自己的地方。
                    let own = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    do {
                        try FileManager.default.moveItem(at: location, to: own)
                        continuation.resume(returning: own)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                holder.observation = task.progress.observe(\.fractionCompleted) { value, _ in
                    let fraction = value.fractionCompleted
                    // 每涨 1% 才更新一次，免得一秒几百次叫醒设置页。
                    guard holder.shouldReport(fraction) else { return }
                    Task { @MainActor in progress(fraction) }
                }
                currentDownload = task
                task.resume()
            }
        } onCancel: {
            Task { @MainActor in self.currentDownload?.cancel() }
        }
    }
}

/// 一次下载的进度观察和节流（回调在别的线程上，锁住）。
private final class KokoroDownloadHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var lastReported = -1.0
    private var _observation: NSKeyValueObservation?

    var observation: NSKeyValueObservation? {
        get { lock.withLock { _observation } }
        set { lock.withLock { _observation = newValue } }
    }

    func shouldReport(_ fraction: Double) -> Bool {
        lock.withLock {
            guard fraction - lastReported >= 0.01 || fraction >= 1 else { return false }
            lastReported = fraction
            return true
        }
    }
}
