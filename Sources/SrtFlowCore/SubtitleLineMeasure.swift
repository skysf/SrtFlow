import Foundation

// 一行字幕有多宽：两把尺子（2026-09-26，docs/architecture/subtitle-generation-style.md）。
//
// 管什么：
// - `units`：按主流规范数字数 —— 中日韩的字（全角）算 1，拉丁字母、数字、空格、半角标点算 0.5
//   （Netflix：半角字符按半个算；英文每行 42 个字符 = 21）。每行封顶、阅读速度都用它。
// - `ems`：估这行在画面上占几个字号宽 —— 全角 1、半角约 0.6（粗体英文平均略宽于半个字号）、空格约 0.3。
//   「一行放得下多少」（竖屏更短）用它，跟 App 按字幕样式和画面宽度算出来的可用宽度比。
// 不管什么：断在哪（`SubtitleBreaks`）、上限是多少（`SubtitleSegmentationConfig`）。

public enum SubtitleLineMeasure {

    /// 全角：中日韩统一表意文字、假名、谚文、中日韩符号与标点、全角字母数字。
    public static func isFullWidth(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F,       // 谚文字母
             0x2E80...0x303F,       // 部首、中日韩符号和标点（含全角空格）
             0x3040...0x33FF,       // 假名、注音、中日韩兼容
             0x3400...0x4DBF,       // 表意文字扩展 A
             0x4E00...0x9FFF,       // 表意文字
             0xAC00...0xD7A3,       // 谚文音节
             0xF900...0xFAFF,       // 兼容表意文字
             0xFE30...0xFE4F,       // 竖排兼容形式
             0xFF01...0xFF60,       // 全角字母、数字、标点
             0xFFE0...0xFFE6,
             0x20000...0x3FFFD:     // 表意文字扩展 B 以后
            return true
        default:
            return false
        }
    }

    /// 按规范数的字数（换行不算）。
    public static func units(_ text: String) -> Double {
        text.unicodeScalars.reduce(0) { sum, scalar in
            if scalar == "\n" { return sum }
            return sum + (isFullWidth(scalar) ? 1 : 0.5)
        }
    }

    /// 估的显示宽度，按字号的倍数（换行不算）。
    public static func ems(_ text: String) -> Double {
        text.unicodeScalars.reduce(0) { sum, scalar in
            if scalar == "\n" { return sum }
            if isFullWidth(scalar) { return sum + 1 }
            return sum + (scalar == " " ? 0.3 : 0.6)
        }
    }

    /// 这段字是不是以全角字为主（中文、日文、韩文）：看得见的字里全角的过半。
    public static func isMostlyFullWidth(_ text: String) -> Bool {
        var full = 0
        var visible = 0
        for scalar in text.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            visible += 1
            if isFullWidth(scalar) { full += 1 }
        }
        return visible > 0 && full * 2 > visible
    }
}
