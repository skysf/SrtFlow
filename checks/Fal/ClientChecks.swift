import Foundation
import SrtFlowMCPKit

// 第五组：FalClient 调 fal 的队列接口。
// 不碰真的网络：URLSession 挂一个假协议（`FalStub`），按脚本回话、把每个请求（方法、地址、头、体）记下来。
// 验的是：提交的路径 / 头 / 体，照 fal 给的三个地址走（不自己拼），状态 → 结果的流程，
// 每种失败换成什么话，取消（Task 被取消 / 超时）时替 fal 也取消，下载的收尾，没有 Key 时一个请求也不发。

/// 进度回调是 @Sendable 的：攒到一个带锁的小盒子里。
private final class StatusLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [FalStatus] = []
    func add(_ status: FalStatus) {
        lock.lock()
        items.append(status)
        lock.unlock()
    }
    var all: [FalStatus] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

private let endpoint = "minimax/h3-max/text-to-video"
private let queue = "https://queue.fal.run/" + endpoint
private let submitted = #"{"request_id":"req-1","status_url":"\#(queue)/requests/req-1/status","response_url":"\#(queue)/requests/req-1","cancel_url":"\#(queue)/requests/req-1/cancel"}"#

private func makeClient(key: String? = "id:secret", interval: Double = 0.005) -> FalClient {
    FalClient(session: FalStub.session, pollInterval: { _ in interval }, key: { key })
}

/// 这段异步代码应该抛这个 FalError。
private func expect(_ expected: FalError, _ message: String, line: Int = #line, _ body: () async throws -> Void) async {
    do {
        try await body()
        check(false, "\(message): expected \(expected), got no error", line: line)
    } catch let error as FalError {
        checkEqual(error, expected, message, line: line)
    } catch {
        check(false, "\(message): expected \(expected), got \(error)", line: line)
    }
}

private func seenCount(_ method: String, containing part: String) -> Int {
    FalStub.log.filter { $0.method == method && $0.url.contains(part) }.count
}

func runClientChecks() async {
    let request: JSONValue = ["prompt": "a fox", "duration": 5]

    // ---- 一次完整的生成：提交 → 排队 → 在做 → 完成 → 取结果
    var polls = 0
    FalStub.reset { seen in
        switch (seen.method, seen.url) {
        case ("POST", queue): return .init(200, submitted)
        case ("GET", queue + "/requests/req-1/status"):
            polls += 1
            switch polls {
            case 1: return .init(200, #"{"status":"IN_QUEUE","queue_position":2}"#)
            case 2: return .init(200, #"{"status":"IN_PROGRESS"}"#)
            default: return .init(200, #"{"status":"COMPLETED"}"#)
            }
        case ("GET", queue + "/requests/req-1"): return .init(200, #"{"video":{"url":"https://v3b.fal.media/files/x/clip.mp4"}}"#)
        default: return .init(404, #"{"detail":"unexpected \#(seen.method) \#(seen.url)"}"#)
        }
    }
    let updates = StatusLog()
    do {
        let (result, submission) = try await makeClient().run(endpoint: endpoint, body: request, maxSeconds: 30) { status in
            updates.add(status)
        }
        checkEqual(result["video"]?["url"]?.stringValue, "https://v3b.fal.media/files/x/clip.mp4", "the result is what fal answered")
        checkEqual(submission.requestID, "req-1", "the request id")
        checkEqual(updates.all, [.queued(position: 2), .running, .completed], "progress is reported in order")
    } catch {
        check(false, "a full generation failed: \(error)")
    }
    let log = FalStub.log
    checkEqual(log.map(\.method), ["POST", "GET", "GET", "GET", "GET"], "submit, three status polls, then the result")
    checkEqual(log.first?.url, queue, "the submit goes to queue.fal.run/<endpoint>")
    check(log.allSatisfy { $0.authorization == "Key id:secret" }, "every call carries `Authorization: Key <key>`")
    let submitBody = log.first?.body.flatMap { try? JSONValue.decode($0) }
    checkEqual(submitBody, request, "the request body is sent as JSON")

    // ---- fal 给的三个地址照它的用（不按端点号自己拼）
    FalStub.reset { seen in
        switch (seen.method, seen.url) {
        case ("POST", "https://queue.fal.run/fal-ai/kling-video/v9/pro/x"):
            return .init(200, #"{"request_id":"r2","status_url":"https://queue.fal.run/fal-ai/kling-video/requests/r2/status","response_url":"https://queue.fal.run/fal-ai/kling-video/requests/r2","cancel_url":"https://queue.fal.run/fal-ai/kling-video/requests/r2/cancel"}"#)
        case ("GET", "https://queue.fal.run/fal-ai/kling-video/requests/r2/status"): return .init(200, #"{"status":"COMPLETED"}"#)
        case ("GET", "https://queue.fal.run/fal-ai/kling-video/requests/r2"): return .init(200, #"{"ok":true}"#)
        default: return .init(404, "{}")
        }
    }
    if let (result, _) = try? await makeClient().run(endpoint: "fal-ai/kling-video/v9/pro/x", body: request, maxSeconds: 5) {
        checkEqual(result["ok"], true, "addresses that differ from the endpoint path are used as given")
    } else {
        check(false, "a sub-path endpoint whose queue address is shorter did not work")
    }

    // ---- 答复里没有地址：按端点号推
    FalStub.reset { seen in
        seen.method == "POST" ? .init(200, #"{"request_id":"r3"}"#) : .init(404, "{}")
    }
    if let derived = try? await makeClient().submit(endpoint: endpoint, body: request) {
        checkEqual(derived.statusURL.absoluteString, queue + "/requests/r3/status", "the status address is derived when fal gives none")
        checkEqual(derived.cancelURL.absoluteString, queue + "/requests/r3/cancel", "the cancel address is derived when fal gives none")
        checkEqual(derived.responseURL.absoluteString, queue + "/requests/r3", "the result address is derived without a trailing slash")
    } else {
        check(false, "a submit answer without addresses was refused")
    }
    FalStub.reset { _ in .init(200, #"{"nothing":1}"#) }
    await expect(.badAnswer("no request_id"), "a submit answer without a request id") { _ = try await makeClient().submit(endpoint: endpoint, body: request) }

    // ---- 每种失败换成什么话
    let failures: [(Int, String, FalError)] = [
        (401, #"{"detail":"Unauthorized"}"#, .rejectedKey),
        (403, #"{"detail":"User is locked. Reason: Exhausted balance. Top up your balance at fal.ai/dashboard/billing."}"#,
         .noBalance("User is locked. Reason: Exhausted balance. Top up your balance at fal.ai/dashboard/billing.")),
        (422, #"{"detail":[{"loc":["body","duration"],"msg":"ensure this value is less than or equal to 15","type":"value_error"}]}"#,
         .invalidInput("duration: ensure this value is less than or equal to 15")),
        (422, #"{"detail":[{"loc":["body","resolution"],"msg":"bad","type":"x"},{"loc":["body","seed"],"msg":"worse","type":"y"}]}"#,
         .invalidInput("resolution: bad; seed: worse")),
        (400, #"{"detail":"Bad input"}"#, .invalidInput("Bad input")),
        (429, "{}", .rateLimited),
        (503, "gateway down", .server(503)),
        (418, "{}", .badAnswer("HTTP 418"))
    ]
    for (status, body, expected) in failures {
        FalStub.reset { _ in .init(status, body) }
        await expect(expected, "HTTP \(status) is reported as \(expected)") { _ = try await makeClient().submit(endpoint: endpoint, body: request) }
    }
    FalStub.reset { _ in .init(200, "not json") }
    await expect(.badAnswer("not JSON"), "an answer that is not JSON") { _ = try await makeClient().submit(endpoint: endpoint, body: request) }
    for error in [FalError.noKey, .rejectedKey, .noBalance(nil), .invalidInput("x"), .rateLimited, .server(500), .failed("x"), .badAnswer("x"), .timedOut, .network("x")] {
        check(!error.message.isEmpty, "\(error) has a message for the AI")
    }
    check(FalError.noKey.message.contains("Settings") && FalError.rejectedKey.message.contains("Settings"), "key problems say where to fix them")
    check(FalError.noBalance(nil).message.contains("billing"), "an empty balance points at fal's billing")

    // ---- 完成了却带着 error
    FalStub.reset { seen in
        seen.method == "POST" ? .init(200, submitted)
            : .init(200, #"{"status":"COMPLETED","error":"the model crashed","error_type":"runtime_error"}"#)
    }
    await expect(.failed("the model crashed"), "COMPLETED with an error is a failure") { _ = try await makeClient().run(endpoint: endpoint, body: request, maxSeconds: 5) }
    FalStub.reset { seen in seen.method == "POST" ? .init(200, submitted) : .init(200, #"{"status":"WHATEVER"}"#) }
    await expect(.badAnswer(#"status "WHATEVER""#), "an unknown status") { _ = try await makeClient().run(endpoint: endpoint, body: request, maxSeconds: 5) }

    // ---- 没有 Key：一个请求也不发
    FalStub.reset { _ in .init(200, submitted) }
    await expect(.noKey, "no key") { _ = try await makeClient(key: nil).submit(endpoint: endpoint, body: request) }
    await expect(.noKey, "an empty key") { _ = try await makeClient(key: "").submit(endpoint: endpoint, body: request) }
    checkEqual(FalStub.log.count, 0, "nothing was sent without a key")
    // 端点号不合规：也不发
    await expect(.invalidInput("https://fal.run/x is not a fal.ai endpoint id (owner/name)."), "a bad endpoint id") {
        _ = try await makeClient().submit(endpoint: "https://fal.run/x", body: request)
    }
    checkEqual(FalStub.log.count, 0, "nothing was sent for a bad endpoint id")

    // ---- Task 被取消：替 fal 也取消
    FalStub.reset { seen in
        switch seen.method {
        case "POST": return .init(200, submitted)
        case "PUT": return .init(202, #"{"status":"CANCELLATION_REQUESTED"}"#)
        default: return .init(200, #"{"status":"IN_PROGRESS"}"#)
        }
    }
    let running = Task { try await makeClient().run(endpoint: endpoint, body: request, maxSeconds: 60) }
    for _ in 0..<400 where seenCount("GET", containing: "/status") < 2 { try? await Task.sleep(nanoseconds: 10_000_000) }
    running.cancel()
    do {
        _ = try await running.value
        check(false, "a cancelled generation should not return")
    } catch is CancellationError {
        check(true, "cancelling the task cancels the run")
    } catch {
        check(false, "a cancelled generation threw \(error)")
    }
    checkEqual(seenCount("PUT", containing: "/requests/req-1/cancel"), 1, "fal is asked to cancel the request too")

    // ---- 超时：也替 fal 取消
    FalStub.reset { seen in
        switch seen.method {
        case "POST": return .init(200, submitted)
        case "PUT": return .init(202, "{}")
        default: return .init(200, #"{"status":"IN_QUEUE","queue_position":9}"#)
        }
    }
    await expect(.timedOut, "a generation that never finishes") { _ = try await makeClient().run(endpoint: endpoint, body: request, maxSeconds: 0.05) }
    checkEqual(seenCount("PUT", containing: "/cancel"), 1, "a timed-out request is cancelled at fal")

    // ---- 下载
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fal-client-check-\(getpid())")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("out.mp4")
    let payload = Data((0..<5000).map { UInt8($0 % 251) })
    FalStub.reset { _ in .init(status: 200, data: payload) }
    do {
        try await makeClient().download(URL(string: "https://v3b.fal.media/files/x/clip.mp4")!, to: file)
        checkEqual(try? Data(contentsOf: file), payload, "the file arrives whole")
    } catch {
        check(false, "the download failed: \(error)")
    }
    check(FalStub.log.allSatisfy { $0.authorization == nil }, "the key is not sent to the file host")
    // 已经有同名文件：换成新的（调用方负责起不撞名的名字，这里不该失败）
    try? Data("old".utf8).write(to: file)
    try? await makeClient().download(URL(string: "https://v3b.fal.media/files/x/clip.mp4")!, to: file)
    checkEqual(try? Data(contentsOf: file), payload, "an existing file is replaced")
    // 空文件、HTTP 错误：报错，也不留半个文件
    let missing = folder.appendingPathComponent("missing.mp4")
    FalStub.reset { _ in .init(status: 200, data: Data()) }
    await expect(.badAnswer("the downloaded file was empty"), "an empty download") { try await makeClient().download(URL(string: "https://x.test/a")!, to: missing) }
    FalStub.reset { _ in .init(404, "{}") }
    await expect(.badAnswer("the file download answered HTTP 404"), "a failed download") { try await makeClient().download(URL(string: "https://x.test/a")!, to: missing) }
    check(!FileManager.default.fileExists(atPath: missing.path), "a failed download leaves no file")

    // ---- HTTP 错误体的几种写法
    checkEqual(FalError.fromHTTP(status: 422, body: Data(#"{"detail":[]}"#.utf8)), .invalidInput("HTTP 422"), "an empty detail list falls back to the status")
    checkEqual(FalError.fromHTTP(status: 500, body: Data()), .server(500), "an empty body")
    checkEqual(FalError.fromHTTP(status: 402, body: Data(#"{"error":"payment required"}"#.utf8)), .noBalance("payment required"), "an `error` field is read too")
}
