import Foundation

/// Timecode parsing and formatting for SRT / VTT / ASS / TXT subtitle files.
public enum Timecode {

    /// Parses `hh:mm:ss,mmm`, `hh:mm:ss.mmm`, `mm:ss.mmm` or `h:mm:ss.cc`.
    /// Fraction of 1-2 digits is treated as deci/centiseconds, 3 digits as milliseconds.
    public static func parse(_ string: String) -> TimeInterval? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }

        let secParts = parts[parts.count - 1].split(whereSeparator: { $0 == "," || $0 == "." })
        guard secParts.count == 2,
              let seconds = Int(secParts[0]), seconds >= 0 else { return nil }

        let frac = secParts[1]
        guard !frac.isEmpty, frac.count <= 3, frac.allSatisfy(\.isNumber),
              let fracValue = Int(frac) else { return nil }
        let millis: Int
        switch frac.count {
        case 1: millis = fracValue * 100
        case 2: millis = fracValue * 10
        default: millis = fracValue
        }

        guard let minutes = Int(parts[parts.count - 2]), minutes >= 0 else { return nil }
        var total = TimeInterval(seconds) + TimeInterval(millis) / 1000 + TimeInterval(minutes) * 60
        if parts.count == 3 {
            guard let hours = Int(parts[0]), hours >= 0 else { return nil }
            total += TimeInterval(hours) * 3600
        }
        return total
    }

    /// `00:00:01,000` (SRT) or `00:00:01.000` (VTT).
    public static func formatMillis(_ time: TimeInterval, separator: Character) -> String {
        let totalMs = max(0, Int((time * 1000).rounded()))
        let ms = totalMs % 1000
        let totalSec = totalMs / 1000
        let sec = totalSec % 60
        let min = (totalSec / 60) % 60
        let hour = totalSec / 3600
        return String(format: "%02d:%02d:%02d%@%03d", hour, min, sec, String(separator), ms)
    }

    /// `0:00:01.00` (ASS/SSA, centiseconds).
    public static func formatASS(_ time: TimeInterval) -> String {
        let totalCs = max(0, Int((time * 100).rounded()))
        let cs = totalCs % 100
        let totalSec = totalCs / 100
        let sec = totalSec % 60
        let min = (totalSec / 60) % 60
        let hour = totalSec / 3600
        return String(format: "%d:%02d:%02d.%02d", hour, min, sec, cs)
    }
}
