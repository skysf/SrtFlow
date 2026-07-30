import Foundation
import SrtFlowCore

enum FFmpegProcessError: LocalizedError {
    case launchFailed(String)
    case exited(code: Int32, stderr: String)
    /// 被系统信号杀掉。几乎总是下载隔离标记导致的（macOS 会直接 SIGKILL 包内
    /// 未公证的可执行文件），而且 stderr 一个字都不留，光看错误信息完全看不懂。
    case killedBySystem(signal: Int32, fixCommand: String?)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .launchFailed(let detail):
            return String(format: L10n("Could not start ffmpeg: %@"), detail)
        case .exited(let code, let stderr):
            let detail = stderr.isEmpty
                ? String(format: L10n("ffmpeg exited with code %d."), code)
                : stderr
            return detail
        case .killedBySystem(let signal, let fixCommand):
            if let fixCommand {
                return String(
                    format: L10n("macOS stopped the bundled ffmpeg because the app was downloaded from the internet. Open System Settings → Privacy & Security, click “Open Anyway” for SrtFlow, then reopen it. If it still fails, paste this line into Terminal:\n%@"),
                    fixCommand
                )
            }
            return String(format: L10n("ffmpeg was stopped by the system (signal %d)."), signal)
        case .cancelled:
            return L10n("Cancelled.")
        }
    }
}

/// 跑一次 ffmpeg，边跑边报进度，可以中途取消。
///
/// 可变状态只有 `isCancelled`，由 `lock` 保护；`Process` 自身的 terminate /
/// waitUntilExit 是线程安全的，所以这里标 `@unchecked Sendable` 是成立的。
final class FFmpegProcess: @unchecked Sendable {

    private let process = Process()
    private let lock = NSLock()
    private var isCancelled = false

    /// - Parameters:
    ///   - workingDirectory: 烧字幕时设成任务的临时目录，滤镜里就能只写相对
    ///     文件名，绕开 ffmpeg 滤镜图里的路径转义规则。
    ///   - onProgress: 在主线程回调。
    func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL?,
        onProgress: (@MainActor (FFmpegProgress) -> Void)? = nil
    ) async throws {
        process.executableURL = executable
        process.arguments = arguments
        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // 不给 ffmpeg 留 stdin，配合 -nostdin 保证它绝不会停下来等输入。
        process.standardInput = FileHandle.nullDevice

        // 三件事各占一个后台线程：读 stdout、读 stderr、等进程退出。
        // 用阻塞读 + DispatchGroup 是最稳的写法，不会像 readabilityHandler
        // 那样在进程退出后还漏数据或重复回调。
        let group = DispatchGroup()
        let stderrBuffer = StderrBuffer()

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            var parser = FFmpegProgressParser()
            let handle = stdoutPipe.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                guard let chunk = String(data: data, encoding: .utf8) else { continue }
                if parser.consume(chunk), let onProgress {
                    let snapshot = parser.progress
                    Task { @MainActor in onProgress(snapshot) }
                }
            }
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let handle = stderrPipe.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                stderrBuffer.append(String(data: data, encoding: .utf8) ?? "")
            }
            group.leave()
        }

        do {
            try process.run()
        } catch {
            throw FFmpegProcessError.launchFailed(error.localizedDescription)
        }

        // 取消可能发生在 run() 之前，补一次检查。
        if cancelRequested { process.terminate() }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                self.process.waitUntilExit()
                group.leave()
            }
            group.notify(queue: .global(qos: .utility)) {
                continuation.resume()
            }
        }

        if cancelRequested { throw FFmpegProcessError.cancelled }

        // 被信号杀掉要单独报：这种情况 stderr 是空的，当成普通退出码报出来
        // 就是一条谁也看不懂的信息。
        if process.terminationReason == .uncaughtSignal {
            throw FFmpegProcessError.killedBySystem(
                signal: process.terminationStatus,
                fixCommand: Quarantine.fixCommandIfFlagged
            )
        }

        guard process.terminationStatus == 0 else {
            throw FFmpegProcessError.exited(code: process.terminationStatus, stderr: stderrBuffer.text)
        }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()
        if process.isRunning { process.terminate() }
    }

    /// 包成同步属性再读。直接在 async 函数里调 NSLock.lock() 在 Swift 6 下是错误。
    private var cancelRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }
}

/// 只留最后若干行 stderr。ffmpeg 出错时有用的信息都在末尾，前面全是噪音。
private final class StderrBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var pending = ""
    private let maxLines = 12

    func append(_ chunk: String) {
        lock.lock()
        defer { lock.unlock() }
        pending += chunk
        while let newline = pending.firstIndex(of: "\n") {
            let line = String(pending[pending.startIndex..<newline]).trimmingCharacters(in: .whitespaces)
            pending = String(pending[pending.index(after: newline)...])
            if !line.isEmpty {
                lines.append(line)
                if lines.count > maxLines { lines.removeFirst() }
            }
        }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        var all = lines
        let trailing = pending.trimmingCharacters(in: .whitespaces)
        if !trailing.isEmpty { all.append(trailing) }
        return all.suffix(maxLines).joined(separator: "\n")
    }
}
