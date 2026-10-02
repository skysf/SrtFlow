import Foundation
import SrtFlowMCPKit

// MARK: - 调 fal.ai 的队列接口（URLSession，不引 SDK）
//
// 管什么：方案第 14 条 —— 直接走 HTTP。fal 的队列：`POST https://queue.fal.run/<端点号>` 提交 → 回 `request_id` 和三个地址
// （`status_url` / `response_url` / `cancel_url`，**照它给的地址用**，不自己拼）→ 轮询状态（`IN_QUEUE` / `IN_PROGRESS` / `COMPLETED`）→
// 取结果；取消是对 `cancel_url` 发 PUT。认证头是 `Authorization: Key <密钥>`。接口定义是 2026-09-29 读 fal 的文档和它公开的
// OpenAPI（`https://fal.ai/api/openapi/queue/openapi.json?endpoint_id=…`）确认的。
// 不管什么：请求体怎么写（FalInputs）、结果怎么读（FalOutputs）、密钥存哪（FalKeyStore）、问不问用户（FalSpendPolicy）。
//
// 自检不碰真的网络：`session` 可以换成挂了假协议的（`checks/Fal/`），`base` 可以指到本机。

struct FalSubmission: Equatable, Sendable {
    var requestID: String
    var statusURL: URL
    var responseURL: URL
    var cancelURL: URL
}

enum FalStatus: Equatable, Sendable {
    case queued(position: Int?)
    case running
    case completed
}

enum FalError: Error, Equatable {
    case noKey
    case rejectedKey
    /// 403：余额用完 / 账号被锁。
    case noBalance(String?)
    case invalidInput(String)
    case rateLimited
    case server(Int)
    /// 任务跑完了，但 fal 说做失败了。
    case failed(String)
    case badAnswer(String)
    case timedOut
    case network(String)

    /// 写给 AI 看的（英文，它会用用户的语言转述）。
    var message: String {
        switch self {
        case .noKey:
            return "No fal.ai API key is set. Ask the user to add one in SrtFlow → Settings → AI."
        case .rejectedKey:
            return "fal.ai rejected the API key (HTTP 401). Ask the user to check the key in SrtFlow → Settings → AI."
        case .noBalance(let detail):
            return "fal.ai refused the request (HTTP 403)" + (detail.map { ": \($0)" } ?? "")
                + ". The account may be out of credit or locked; ask the user to check their fal.ai billing."
        case .invalidInput(let detail):
            return "fal.ai did not accept the request: \(detail). Fix the arguments (or options) and try again."
        case .rateLimited:
            return "fal.ai is rate limiting this key (HTTP 429). Wait a little and try again."
        case .server(let status):
            return "fal.ai had a problem on its side (HTTP \(status)). Try again in a moment."
        case .failed(let detail):
            return "fal.ai could not make it: \(detail)"
        case .badAnswer(let detail):
            return "fal.ai's answer was not what SrtFlow expected (\(detail))."
        case .timedOut:
            return "fal.ai did not finish in time. The request was cancelled; nothing was charged for an unfinished request."
        case .network(let detail):
            return "Could not reach fal.ai: \(detail)"
        }
    }

    /// 把 HTTP 的失败换成一句话。422 的 `detail` 是 `[{loc, msg, type}]` 或一句字符串。
    static func fromHTTP(status: Int, body: Data) -> FalError {
        let json = try? JSONValue.decode(body)
        let detail = json?["detail"] ?? json?["error"] ?? json?["message"]
        var text: String?
        switch detail {
        case .string(let message)?: text = message
        case .array(let items)?:
            text = items.prefix(3).compactMap { item -> String? in
                guard let message = item["msg"]?.stringValue else { return item.stringValue }
                let location = item["loc"]?.arrayValue?.compactMap { $0.stringValue ?? $0.intValue.map(String.init) }
                    .filter { $0 != "body" }.joined(separator: ".")
                return location.map { $0.isEmpty ? message : "\($0): \(message)" }
            }.joined(separator: "; ")
        default: text = nil
        }
        if text?.isEmpty == true { text = nil }
        switch status {
        case 401: return .rejectedKey
        case 402, 403: return .noBalance(text)
        case 400, 404, 409, 413, 415, 422: return .invalidInput(text ?? "HTTP \(status)")
        case 429: return .rateLimited
        case 500...599: return .server(status)
        default: return .badAnswer("HTTP \(status)" + (text.map { ": \($0)" } ?? ""))
        }
    }
}

final class FalClient: @unchecked Sendable {
    private let session: URLSession
    private let base: URL
    /// 存储（上传文件）和平台（账单）接口的地址：`https://rest.fal.ai`、`https://api.fal.ai`。
    private let rest: URL
    private let api: URL
    private let keyProvider: @Sendable () -> String?
    private let pollInterval: @Sendable (Int) -> Double

    /// 队列地址。只在自检 / 冒烟时用环境变量 `SRTFLOW_FAL_QUEUE_BASE` 指到本机的假 fal，**只认回环地址**（Key 不会因此发到别处）。
    static func configuredBase(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let text = environment["SRTFLOW_FAL_QUEUE_BASE"], let url = URL(string: text), ["127.0.0.1", "localhost"].contains(url.host ?? "") {
            return url
        }
        return URL(string: "https://queue.fal.run")!
    }

    /// 前几次问得勤一点（图片几秒就好），之后每 2 到 4 秒一次。
    static let defaultPollInterval: @Sendable (Int) -> Double = { polls in polls < 5 ? 1.0 : min(4.0, 2.0 + Double(polls - 5) * 0.25) }

    init(
        session: URLSession = .shared, base: URL = URL(string: "https://queue.fal.run")!,
        rest: URL = URL(string: "https://rest.fal.ai")!, api: URL = URL(string: "https://api.fal.ai")!,
        pollInterval: @escaping @Sendable (Int) -> Double = FalClient.defaultPollInterval,
        key: @escaping @Sendable () -> String?
    ) {
        self.session = session
        self.base = base
        self.rest = rest
        self.api = api
        self.pollInterval = pollInterval
        self.keyProvider = key
    }

    // MARK: 一次生成的四个动作

    func submit(endpoint: String, body: JSONValue) async throws -> FalSubmission {
        guard FalModels.isValidEndpoint(endpoint) else { throw FalError.invalidInput("\(endpoint) is not a fal.ai endpoint id (owner/name).") }
        var request = try authorized(URLRequest(url: base.appendingPathComponent(endpoint)))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try body.encodedData()
        let answer = try await send(request)
        guard let id = answer["request_id"]?.stringValue else { throw FalError.badAnswer("no request_id") }
        /// fal 给了地址就照它的用；没给才按端点号推（`/requests/<id>` 是结果，后面加 `/status`、`/cancel`）。
        func address(_ key: String, suffix: String) -> URL? {
            answer[key]?.stringValue.flatMap(URL.init(string:))
                ?? URL(string: base.appendingPathComponent(endpoint).absoluteString + "/requests/\(id)" + suffix)
        }
        guard let status = address("status_url", suffix: "/status"), let response = address("response_url", suffix: ""),
              let cancel = address("cancel_url", suffix: "/cancel") else { throw FalError.badAnswer("bad addresses") }
        return FalSubmission(requestID: id, statusURL: status, responseURL: response, cancelURL: cancel)
    }

    func status(_ submission: FalSubmission) async throws -> FalStatus {
        let answer = try await send(try authorized(URLRequest(url: submission.statusURL)))
        switch answer["status"]?.stringValue?.uppercased() {
        case "IN_QUEUE": return .queued(position: answer["queue_position"]?.intValue)
        case "IN_PROGRESS": return .running
        case "COMPLETED":
            // 完成了却带着 error：做失败了（取结果那一步也会报，但这里先说清楚）。
            if let failure = answer["error"], !failure.isNull {
                throw FalError.failed(failure.stringValue ?? failure.encodedString())
            }
            return .completed
        default:
            throw FalError.badAnswer("status \(answer["status"]?.encodedString() ?? "missing")")
        }
    }

    func result(_ submission: FalSubmission) async throws -> JSONValue {
        try await send(try authorized(URLRequest(url: submission.responseURL)))
    }

    /// 取消：能取消就取消，取消不了（已经做完了）也不算错。
    func cancel(_ submission: FalSubmission) async {
        guard var request = try? authorized(URLRequest(url: submission.cancelURL)) else { return }
        request.httpMethod = "PUT"
        _ = try? await session.data(for: request)
    }

    /// 在**不继承取消**的 Task 里发取消：调用者的 Task 已经被取消了，URLSession 的 async 接口一看见取消就不发请求，
    /// 直接 `await cancel` 的话 fal 那边其实没被取消（自检里逮到的）。
    private func cancelDetached(_ submission: FalSubmission) async {
        await Task.detached { await self.cancel(submission) }.value
    }

    /// 提交 → 轮询 → 取结果。Task 被取消时替 fal 也取消掉。
    func run(
        endpoint: String, body: JSONValue, maxSeconds: Double,
        onUpdate: @Sendable (FalStatus) -> Void = { _ in }
    ) async throws -> (result: JSONValue, submission: FalSubmission) {
        let submission = try await submit(endpoint: endpoint, body: body)
        do {
            let deadline = Date().addingTimeInterval(maxSeconds)
            var polls = 0
            while true {
                try Task.checkCancellation()
                let status = try await status(submission)
                onUpdate(status)
                if status == .completed { break }
                guard Date() < deadline else { throw FalError.timedOut }
                polls += 1
                try await Task.sleep(nanoseconds: UInt64(pollInterval(polls) * 1_000_000_000))
            }
            return (try await result(submission), submission)
        } catch is CancellationError {
            await cancelDetached(submission)
            throw CancellationError()
        } catch FalError.timedOut {
            await cancelDetached(submission)
            throw FalError.timedOut
        }
    }

    /// 把成品下载到 `destination`（先下到临时文件再挪过去，下到一半断了不留半个文件）。
    func download(_ url: URL, to destination: URL) async throws {
        do {
            let (temporary, response) = try await session.download(from: url)
            defer { try? FileManager.default.removeItem(at: temporary) }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw FalError.badAnswer("the file download answered HTTP \(http.statusCode)")
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? Int) ?? 0
            guard size > 0 else { throw FalError.badAnswer("the downloaded file was empty") }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch let error as FalError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw FalError.network(error.localizedDescription)
        }
    }

    // MARK: 上传文件（视频太大，不能像图片那样当 data URI 内嵌）

    /// fal 的存储：`POST <rest>/storage/upload/initiate?storage_type=fal-cdn-v3` 拿到 `upload_url` / `file_url`，把字节 `PUT` 到
    /// `upload_url`（这一步不带 Key：那是存储桶的签名地址），`file_url` 就是能填进 `video_url` 的地址。
    /// 2026-10-02 实测：旧 SDK / 旧文档写的 `storage_type=gcs` 已经被拒（400 Invalid storage type）。
    func upload(fileURL: URL, contentType: String, fileName: String? = nil) async throws -> URL {
        let bytes: Data
        do {
            bytes = try Data(contentsOf: fileURL)
        } catch {
            throw FalError.network("could not read \(fileURL.lastPathComponent): \(error.localizedDescription)")
        }
        var components = URLComponents(url: rest.appendingPathComponent("storage/upload/initiate"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "storage_type", value: "fal-cdn-v3")]
        guard let initiateURL = components?.url else { throw FalError.badAnswer("bad upload address") }
        var initiate = try authorized(URLRequest(url: initiateURL))
        initiate.httpMethod = "POST"
        initiate.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let name = fileName ?? fileURL.lastPathComponent
        initiate.httpBody = try JSONValue.object(["file_name": .string(name), "content_type": .string(contentType)]).encodedData()
        let answer = try await send(initiate)
        guard let uploadURL = answer["upload_url"]?.stringValue.flatMap(URL.init(string:)),
              let fileLink = answer["file_url"]?.stringValue.flatMap(URL.init(string:)) else {
            throw FalError.badAnswer("no upload_url / file_url")
        }
        var put = URLRequest(url: uploadURL)
        put.httpMethod = "PUT"
        put.timeoutInterval = 600
        put.setValue(contentType, forHTTPHeaderField: "Content-Type")
        put.httpBody = bytes
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: put)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw FalError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw FalError.badAnswer("not an HTTP answer") }
        guard (200..<300).contains(http.statusCode) else { throw FalError.fromHTTP(status: http.statusCode, body: data) }
        return fileLink
    }

    // MARK: 账单明细（要 ADMIN 权限的 Key；只有 API 权限会 401 / 403，调用方当作查不到）

    func billingEvents(requestIDs: [String], since: Date) async throws -> [FalBillingEvent] {
        var components = URLComponents(url: api.appendingPathComponent(FalBilling.path), resolvingAgainstBaseURL: false)
        components?.queryItems = FalBilling.query(requestIDs: requestIDs, since: since)
        guard let url = components?.url else { throw FalError.badAnswer("bad billing address") }
        return FalBilling.events(from: try await send(try authorized(URLRequest(url: url))))
    }

    // MARK: 私有

    private func authorized(_ request: URLRequest) throws -> URLRequest {
        guard let key = keyProvider(), !key.isEmpty else { throw FalError.noKey }
        var request = request
        request.timeoutInterval = 60
        request.setValue("Key \(key)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send(_ request: URLRequest) async throws -> JSONValue {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw FalError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw FalError.badAnswer("not an HTTP answer") }
        guard (200..<300).contains(http.statusCode) else { throw FalError.fromHTTP(status: http.statusCode, body: data) }
        guard let json = try? JSONValue.decode(data) else { throw FalError.badAnswer("not JSON") }
        return json
    }
}
