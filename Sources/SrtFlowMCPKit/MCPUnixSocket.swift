import Darwin
import Foundation

// MARK: - Unix socket 的收发
//
// 管什么：连、听、收一行、发一行 —— 小程序（连）和 App（听）共用这一份。
// 全是**阻塞**调用：只许在自己开的线程上用（App 的 `AIBridgeServer` 每条连接一个 `Thread`，
// 小程序每次调用一个 GCD 任务）。**不许放进 Swift 并发的 Task 里** —— 阻塞会占住协作线程池，
// 道理同 docs/architecture/blocking-media-reads.md。
// 不管什么：说什么（MCPBridge）、谁来听（AIBridgeServer）。

public enum MCPUnixSocket {
    public struct SocketError: Error, CustomStringConvertible {
        public let description: String
    }

    /// 连一个 Unix socket。没人在听（App 没开、socket 是上次崩溃留下的旧文件）就抛错。
    public static func connect(path: String) throws -> Int32 {
        var address = try socketAddress(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError(description: "socket(): \(errnoText())") }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let reason = errnoText()
            close(fd)
            throw SocketError(description: "connect(\(path)): \(reason)")
        }
        disableSigPipe(fd)
        return fd
    }

    /// 在 path 上听。上次崩溃留下的旧 socket 文件先删掉；目录只有自己能进、socket 只有自己能连。
    /// **还有人在听就不抢**（同一个 App 开了两份）：删掉它的 socket 等于把正在用的那一份掐断。
    public static func listen(path: String) throws -> Int32 {
        var address = try socketAddress(path)
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        if let alive = try? connect(path: path) {
            close(alive)
            throw SocketError(description: "another process is already listening on \(path)")
        }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError(description: "socket(): \(errnoText())") }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let reason = errnoText()
            close(fd)
            throw SocketError(description: "bind(\(path)): \(reason)")
        }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 16) == 0 else {
            let reason = errnoText()
            close(fd)
            throw SocketError(description: "listen(\(path)): \(reason)")
        }
        return fd
    }

    /// 等下一条连接。出错（包括 socket 被关掉）返回 nil。
    public static func accept(_ fd: Int32) -> Int32? {
        let client = Darwin.accept(fd, nil, nil)
        guard client >= 0 else { return nil }
        disableSigPipe(client)
        return client
    }

    /// 连进来的是不是同一个用户（socket 文件已经是 0600，这是第二道）。
    public static func peerIsSameUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return false }
        return uid == getuid()
    }

    /// 收发超时。App 那头一个工具最多做几十秒（长活都转成任务号），给足余量。
    public static func setTimeouts(_ fd: Int32, seconds: Int) {
        var interval = timeval(tv_sec: seconds, tv_usec: 0)
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &interval, size)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &interval, size)
    }

    /// 发一行：数据后面补一个换行。
    public static func writeLine(_ fd: Int32, _ data: Data) throws {
        var payload = data
        payload.append(0x0A)
        try payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw SocketError(description: "write: \(errnoText())")
                }
                offset += written
            }
        }
    }

    /// 读一行（不含换行）。对方关了连接、一个字节都没读到时返回 nil。
    /// 一条连接只收一行，换行之后的字节不要。
    public static func readLine(_ fd: Int32, maxBytes: Int = 64 << 20) throws -> Data? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw SocketError(description: "read: \(errnoText())")
            }
            if count == 0 { return buffer.isEmpty ? nil : buffer }
            if let newline = chunk[0..<count].firstIndex(of: 0x0A) {
                buffer.append(contentsOf: chunk[0..<newline])
                return buffer
            }
            buffer.append(contentsOf: chunk[0..<count])
            guard buffer.count <= maxBytes else { throw SocketError(description: "message too large") }
        }
    }

    // MARK: 私有

    private static func socketAddress(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else {
            throw SocketError(description: "socket path is longer than \(capacity - 1) bytes: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    /// 对方先断开时，往这条连接里写不许把整个进程杀掉（默认的 SIGPIPE 会）。
    private static func disableSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func errnoText() -> String {
        String(cString: strerror(errno))
    }
}
