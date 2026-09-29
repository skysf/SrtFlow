import Foundation
import SrtFlowCore

// 用户文本文件的编码识别（SrtFlowCore 的 TextDecoding：剪辑页挂字幕、字幕编辑、烧录、批量转换、AI 读文稿共用一处）。
// GBK 字幕被当成 UTF-16 读成乱码的回归（docs/bugfixes/2026-09-27-gbk-subtitles-read-as-utf16.md）：换回老顺序
//（UTF-8 → UTF-16 → GBK）这里的 GBK 两条、不带 BOM 的 UTF-16 一条当场红。
// 放在 MCP 自检里是因为它链接了整份 SrtFlowCore，又不用往只许降的 SrtFlowCoreChecks/main.swift 里加行。
// 编法见 scripts/check-mcp.sh；约束见 docs/architecture/text-file-encoding.md。

func runTextDecodingChecks() {
    checkTextDecoding()
}

/// 编码识别：GBK 字幕不管字节数单双都要读对（以前双数的一律被当成 UTF-16 读成乱码），UTF-16 带不带 BOM、
/// 大端小端都认，UTF-8 的 BOM 不留在正文里。
private func checkTextDecoding() {
    let gbk = String.Encoding(rawValue: 0x8000_0421)
    let srt = "1\n00:00:01,000 --> 00:00:02,500\n欢迎来到南极\n"
    let pair = [srt, srt + "x"]
    for text in pair {
        let data = text.data(using: gbk)!
        checkEqual(TextDecoding.decode(data), text, "a GBK subtitle file with \(data.count) bytes reads as Chinese")
    }
    checkEqual(Set(pair.map { $0.data(using: gbk)!.count % 2 }), [0, 1], "one GBK sample has an even byte count, one odd")
    var littleWithMark = Data([0xFF, 0xFE])
    littleWithMark.append(srt.data(using: .utf16LittleEndian)!)
    checkEqual(TextDecoding.decode(littleWithMark), srt, "UTF-16 little-endian with a byte-order mark")
    checkEqual(TextDecoding.decode(srt.data(using: .utf16LittleEndian)!), srt, "UTF-16 little-endian without a mark")
    checkEqual(TextDecoding.decode(srt.data(using: .utf16BigEndian)!), srt, "UTF-16 big-endian without a mark")
    var utf8WithMark = Data([0xEF, 0xBB, 0xBF])
    utf8WithMark.append(Data(srt.utf8))
    checkEqual(TextDecoding.decode(utf8WithMark), srt, "a UTF-8 byte-order mark is not left in the text")
    checkEqual(TextDecoding.decode(Data(srt.utf8)), srt, "plain UTF-8")
}

