import Foundation

// fal 自检共用的假 URLSession 协议（FalStub）：按脚本回话、把每个请求（方法、地址、头、体）记下来。
// 从 ClientChecks.swift 搬出来（2026-10-02）：视频 upscale 的流水线自检（checks/Upscale）也用它。

/// 一次被记下的请求。
struct FalSeen {
    var method: String
    var url: String
    var authorization: String?
    var body: Data?
}

final class FalStub: URLProtocol {
    struct Reply {
        var status = 200
        var body = Data()
        init(_ status: Int = 200, _ body: String = "{}") {
            self.status = status
            self.body = Data(body.utf8)
        }
        init(status: Int = 200, data: Data) {
            self.status = status
            self.body = data
        }
    }

    static var handler: (FalSeen) -> Reply = { _ in Reply() }
    static var seen: [FalSeen] = []
    private static let lock = NSLock()

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FalStub.self]
        return URLSession(configuration: configuration)
    }()

    static func reset(_ handler: @escaping (FalSeen) -> Reply) {
        lock.lock()
        seen = []
        self.handler = handler
        lock.unlock()
    }

    static var log: [FalSeen] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body: Data?
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            body = data
        } else {
            body = request.httpBody
        }
        let seen = FalSeen(
            method: request.httpMethod ?? "GET", url: request.url?.absoluteString ?? "",
            authorization: request.value(forHTTPHeaderField: "Authorization"), body: body
        )
        Self.lock.lock()
        Self.seen.append(seen)
        let handler = Self.handler
        Self.lock.unlock()
        let reply = handler(seen)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
