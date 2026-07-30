import Foundation

/// 解析 `-progress pipe:1` 的输出。
///
/// ffmpeg 会一行一个 `key=value` 地吐，每批以 `progress=continue` 或
/// `progress=end` 收尾：
///
/// ```
/// frame=90
/// out_time_us=3000000
/// total_size=3900841
/// speed=9.25x
/// progress=continue
/// ```
public struct FFmpegProgress: Hashable, Sendable {
    /// 已编码到源视频的第几秒。
    public var outTimeSeconds: Double?
    /// 相对播放速度，`2.5` 表示 2.5 倍实时。
    public var speed: Double?
    /// 目前写出的字节数。
    public var totalSize: Int64?
    public var frame: Int?
    public var finished = false

    public init() {}

    /// 用总时长换算完成比例。
    public func fraction(duration: Double) -> Double? {
        guard duration > 0, let outTimeSeconds else { return nil }
        return min(1, max(0, outTimeSeconds / duration))
    }

    /// 按当前速度估算剩余秒数。
    public func remainingSeconds(duration: Double) -> Double? {
        guard duration > 0, let outTimeSeconds, let speed, speed > 0.01 else { return nil }
        let remaining = duration - outTimeSeconds
        guard remaining > 0 else { return 0 }
        return remaining / speed
    }
}

public struct FFmpegProgressParser: Sendable {
    public private(set) var progress = FFmpegProgress()
    private var buffer = ""

    public init() {}

    /// 喂进一段 stdout（不保证按行对齐），返回本次是否凑齐了一批新进度。
    public mutating func consume(_ chunk: String) -> Bool {
        buffer += chunk
        var updated = false

        // 最后一段可能是不完整的行，留在缓冲里等下次。
        while let newlineIndex = buffer.firstIndex(of: "\n") {
            let line = String(buffer[buffer.startIndex..<newlineIndex])
            buffer = String(buffer[buffer.index(after: newlineIndex)...])
            if apply(line: line) { updated = true }
        }
        return updated
    }

    /// 返回 true 表示这一行是一批进度的结束标记。
    private mutating func apply(line: String) -> Bool {
        guard let equals = line.firstIndex(of: "=") else { return false }
        let key = line[line.startIndex..<equals].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        guard value != "N/A" else { return false }

        switch key {
        case "out_time_us", "out_time_ms":
            // 名字骗人：ffmpeg 这两个键给的都是微秒。
            if let micro = Double(value) { progress.outTimeSeconds = micro / 1_000_000 }
        case "out_time":
            // ffmpeg 给的是 `00:00:03.000000`（6 位小数），Timecode 只认到毫秒。
            if progress.outTimeSeconds == nil,
               let seconds = Timecode.parse(Self.trimFraction(value, digits: 3)) {
                progress.outTimeSeconds = seconds
            }
        case "total_size":
            if let bytes = Int64(value) { progress.totalSize = bytes }
        case "frame":
            if let frame = Int(value) { progress.frame = frame }
        case "speed":
            // "9.25x" → 9.25
            let trimmed = value.hasSuffix("x") ? String(value.dropLast()) : value
            if let speed = Double(trimmed) { progress.speed = speed }
        case "progress":
            if value == "end" { progress.finished = true }
            return true
        default:
            break
        }
        return false
    }

    /// `00:00:03.000000` → `00:00:03.000`
    static func trimFraction(_ value: String, digits: Int) -> String {
        guard let dot = value.lastIndex(of: ".") else { return value }
        let fraction = value[value.index(after: dot)...]
        guard fraction.count > digits else { return value }
        return String(value[..<dot]) + "." + fraction.prefix(digits)
    }
}
