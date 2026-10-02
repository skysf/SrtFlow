import Foundation

// MARK: - 带进度的上传 / 下载（URLSession 任务的代理）
//
// 管什么：`FalClient` 传文件的那两步怎么拿到字节进度。上传用 `uploadTask(with:fromFile:)`：文件流着发、不整个读进内存
// （以前是 `Data(contentsOf:)` 一口气读完再发，整个原片直接上传时可能是几个 GB），`didSendBodyData` 报发了多少；
// 下载用 `downloadTask`：`didWriteData` 报收了多少，`didFinishDownloadingTo` 那一拍把系统的临时文件挪到自己的地方
// （回调一返回系统就删它）。两个都包成 async：Task 被取消就取消 URLSession 的任务（它报 URLError.cancelled，调用方换成
// CancellationError）。比例只在服务器说了总长时才报（没有 Content-Length 就不报），按 1% 一格、没变不报。
// 不管什么：地址、认证头、HTTP 状态怎么换话、最后那一下「100%」（FalClient）。
//
// 只有 FalClient 用它（checks/fal-wiring.sh：`URLSession` 只许出现在 FalClient.swift 和这里）。

enum FalTransfer {
    /// 跑一个上传 / 下载任务到结束。
    static func perform(_ task: URLSessionTask, delegate: FalTransferDelegate) async throws {
        try Task.checkCancellation()
        task.delegate = delegate
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.install(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

/// 一个上传 / 下载任务的代理：攒答复的正文、报进度、下载完当场把文件挪走、结束时叫醒等着的 continuation。
final class FalTransferDelegate: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let moveDestination: URL?
    private let onProgress: @Sendable (Double) -> Void
    private var received = Data()
    private var movedTo: URL?
    private var moveError: Error?
    private var lastStep = -1
    private var continuation: CheckedContinuation<Void, Error>?

    /// `moveDestination`：下载完挪到哪（上传传 nil）。`onProgress`：0…1，按 1% 一格。
    init(moveDestination: URL?, onProgress: @escaping @Sendable (Double) -> Void) {
        self.moveDestination = moveDestination
        self.onProgress = onProgress
    }

    /// 答复的正文（上传时是存储桶回的话；下载时正文进了文件，这里是空的）。
    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    /// 下载完挪到 `moveDestination` 的那个文件；没下成、或挪不动（`downloadMoveError`）就是 nil。
    var downloadedFile: URL? {
        lock.lock()
        defer { lock.unlock() }
        return movedTo
    }

    var downloadMoveError: Error? {
        lock.lock()
        defer { lock.unlock() }
        return moveError
    }

    func install(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    /// 按 1% 一格报，没变不报。
    private func report(_ done: Int64, of total: Int64) {
        guard total > 0 else { return }
        let step = min(100, Int((Double(done) / Double(total) * 100).rounded(.down)))
        lock.lock()
        let changed = step > lastStep
        if changed { lastStep = step }
        lock.unlock()
        if changed { onProgress(Double(step) / 100) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        received.append(data)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        report(totalBytesSent, of: totalBytesExpectedToSend)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        report(totalBytesWritten, of: totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // 这个回调一返回，系统就删 `location`：当场挪走。
        guard let destination = moveDestination else { return }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            lock.lock()
            movedTo = destination
            lock.unlock()
        } catch {
            lock.lock()
            moveError = error
            lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        if let error {
            waiting?.resume(throwing: error)
        } else {
            waiting?.resume()
        }
    }
}
