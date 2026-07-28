import Foundation
import SrtFlowCore

// CLT 不包含 XCTest，这里用极简断言跑核心库自检：
//   swift run SrtFlowCoreChecks
// 全部通过时退出码为 0，输出 "All checks passed"。

private var failures = 0
private var checks = 0

func check(_ condition: Bool, _ message: String, file: String = #fileID, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL [\(file):\(line)] \(message)")
    }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String, file: String = #fileID, line: Int = #line) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL [\(file):\(line)] \(message): got \(actual), expected \(expected)")
    }
}

// MARK: - Timecode

checkEqual(Timecode.parse("00:00:01,000"), 1.0, "srt comma")
checkEqual(Timecode.parse("00:00:01.500"), 1.5, "srt dot")
checkEqual(Timecode.parse("01:02:03,250"), 3723.25, "hours")
checkEqual(Timecode.parse("02:03.400"), 123.4, "vtt short form")
checkEqual(Timecode.parse("0:00:01.50"), 1.5, "ass centiseconds")
checkEqual(Timecode.parse("0:01:00.5"), 60.5, "single fraction digit")
check(Timecode.parse("not a time") == nil, "garbage rejected")
check(Timecode.parse("00:00") == nil, "missing fraction rejected")

checkEqual(Timecode.formatMillis(3723.25, separator: ","), "01:02:03,250", "format srt")
checkEqual(Timecode.formatMillis(3723.25, separator: "."), "01:02:03.250", "format vtt")
checkEqual(Timecode.formatASS(3723.25), "1:02:03.25", "format ass")
checkEqual(Timecode.formatASS(0.5), "0:00:00.50", "format ass half second")
checkEqual(Timecode.formatMillis(-5, separator: ","), "00:00:00,000", "negative clamped")

// MARK: - SRT

let srtSample = """
1
00:00:01,000 --> 00:00:03,500
你好，世界

2
00:00:04,000 --> 00:00:06,000
Second line
continues here

"""

do {
    let doc = SubtitleParser.parse(srtSample, format: .srt, filename: "a.srt")
    checkEqual(doc.cues.count, 2, "srt cue count")
    checkEqual(doc.cues[0].start, 1.0, "srt start")
    checkEqual(doc.cues[0].end, 3.5, "srt end")
    checkEqual(doc.cues[0].text, "你好，世界", "srt text")
    checkEqual(doc.cues[1].text, "Second line\ncontinues here", "srt multiline")
    checkEqual(doc.title, "a", "srt title from filename")
    checkEqual(doc.cues[1].index, 2, "reindex")

    let out = SubtitleSerializer.serialize(doc, format: .srt)
    let reparsed = SubtitleParser.parse(out, format: .srt)
    checkEqual(reparsed.cues.count, 2, "srt round trip count")
    checkEqual(reparsed.cues[0].start, 1.0, "srt round trip start")
    checkEqual(reparsed.cues[0].text, "你好，世界", "srt round trip text")

    let crlf = SubtitleParser.parse(srtSample.replacingOccurrences(of: "\n", with: "\r\n"), format: .srt)
    checkEqual(crlf.cues.count, 2, "srt crlf")
}

// MARK: - VTT

let vttSample = """
WEBVTT

NOTE this is a comment

cue-1
00:01.000 --> 00:03.000 align:start position:0%
Hello

00:00:04.000 --> 00:00:06.000
World

"""

do {
    let doc = SubtitleParser.parse(vttSample, format: .vtt)
    checkEqual(doc.cues.count, 2, "vtt cue count")
    checkEqual(doc.cues[0].start, 1.0, "vtt short timecode")
    checkEqual(doc.cues[0].end, 3.0, "vtt end")
    checkEqual(doc.cues[0].text, "Hello", "vtt identifier skipped")
    checkEqual(doc.cues[1].text, "World", "vtt text")

    let out = SubtitleSerializer.serialize(doc, format: .vtt)
    check(out.hasPrefix("WEBVTT"), "vtt header")
    let reparsed = SubtitleParser.parse(out, format: .vtt)
    checkEqual(reparsed.cues.count, 2, "vtt round trip")
    checkEqual(reparsed.cues[1].end, 6.0, "vtt round trip end")
}

// MARK: - ASS

let assSample = """
[Script Info]
Title: Demo
ScriptType: v4.00+
PlayResX: 1920

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,PingFang SC,48,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,-1,0,0,0,100,100,0,0,1,2,0,2,0010,0010,0010,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:03.50,Default,Actor,0010,0010,0010,,Hello, with comma
Dialogue: 1,0:00:04.00,0:00:06.00,Default,,0000,0000,0000,Scroll up,{\\an8\\pos(100,200)}Styled\\NSecond

"""

do {
    let doc = SubtitleParser.parse(assSample, format: .ass, filename: "d.ass")
    checkEqual(doc.title, "d", "ass title from filename")
    checkEqual(doc.scriptInfo["Title"], "Demo", "ass script info title kept")
    checkEqual(doc.scriptInfo["PlayResX"], "1920", "ass script info kept")
    checkEqual(doc.styles.count, 1, "ass style count")
    checkEqual(doc.styles[0].fontName, "PingFang SC", "ass style font")
    check(doc.styles[0].bold, "ass style bold")
    checkEqual(doc.styles[0].marginL, 10, "ass style margin")

    checkEqual(doc.cues.count, 2, "ass cue count")
    checkEqual(doc.cues[0].start, 1.0, "ass start")
    checkEqual(doc.cues[0].end, 3.5, "ass end")
    checkEqual(doc.cues[0].text, "Hello, with comma", "ass comma in text survives")
    checkEqual(doc.cues[0].name, "Actor", "ass actor")
    checkEqual(doc.cues[0].marginL, 10, "ass event margin")
    checkEqual(doc.cues[1].layer, 1, "ass layer")
    checkEqual(doc.cues[1].effect, "Scroll up", "ass effect")
    checkEqual(doc.cues[1].text, "{\\an8\\pos(100,200)}Styled\\NSecond", "ass override tags kept")

    let out = SubtitleSerializer.serialize(doc, format: .ass)
    let reparsed = SubtitleParser.parse(out, format: .ass)
    checkEqual(reparsed.styles.first?.fontName, "PingFang SC", "ass round trip style")
    checkEqual(reparsed.cues.count, 2, "ass round trip cues")
    checkEqual(reparsed.cues[1].text, doc.cues[1].text, "ass round trip tags")
    checkEqual(reparsed.cues[0].name, "Actor", "ass round trip actor")
    checkEqual(reparsed.cues[1].effect, "Scroll up", "ass round trip effect")

    let srt = SubtitleSerializer.serialize(doc, format: .srt)
    check(!srt.contains("{\\"), "ass→srt strips override tags")
    check(srt.contains("Styled\nSecond"), "ass→srt converts \\N to newline")
    check(srt.contains("00:00:01,000 --> 00:00:03,500"), "ass→srt timecodes")
}

// MARK: - SSA

let ssaSample = """
[Script Info]
Title: Old
ScriptType: v4.00

[V4 Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, TertiaryColour, BackColour, Bold, Italic, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, AlphaLevel, Encoding
Style: Default,Arial,30,16777215,255,0,0,-1,0,1,3,2,5,0015,0015,0015,0,1

[Events]
Format: Marked, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: Marked=0,0:00:01.00,0:00:02.00,Default,,0000,0000,0000,,Hi there

"""

do {
    let doc = SubtitleParser.parse(ssaSample, format: .ssa)
    checkEqual(doc.cues.count, 1, "ssa cue count")
    checkEqual(doc.cues[0].text, "Hi there", "ssa text")
    checkEqual(doc.styles[0].fontName, "Arial", "ssa style font")
    check(doc.styles[0].bold, "ssa style bold")

    let out = SubtitleSerializer.serialize(doc, format: .ssa)
    check(out.contains("[V4 Styles]"), "ssa keeps v4 section")
    check(out.contains("v4.00"), "ssa keeps script type")
    let reparsed = SubtitleParser.parse(out, format: .ssa)
    checkEqual(reparsed.cues.count, 1, "ssa round trip")
    checkEqual(reparsed.cues[0].text, "Hi there", "ssa round trip text")
}

// MARK: - Plain text

do {
    let styleA = SubtitleParser.parse("00:00:01,000 --> 00:00:03,500\n你好，世界\n", format: .text)
    checkEqual(styleA.cues.count, 1, "txt style A count")
    checkEqual(styleA.cues[0].start, 1.0, "txt style A start")
    checkEqual(styleA.cues[0].text, "你好，世界", "txt style A text")

    let styleB = SubtitleParser.parse("[00:00:01.000] 你好，世界\n[00:00:02.500] 第二行\n", format: .text)
    checkEqual(styleB.cues.count, 2, "txt style B count")
    checkEqual(styleB.cues[0].start, 1.0, "txt style B start")
    checkEqual(styleB.cues[1].start, 2.5, "txt style B second")
    checkEqual(styleB.cues[1].text, "第二行", "txt style B text")

    let noTime = SubtitleParser.parse("第一行\n第二行\n", format: .text)
    checkEqual(noTime.cues.count, 2, "txt no-time count")
    checkEqual(noTime.cues[0].start, 0, "txt no-time zero start")
    checkEqual(noTime.cues[0].end, 0, "txt no-time zero end")
    checkEqual(SubtitleSerializer.serialize(noTime, format: .text), "第一行\n第二行\n", "txt no-time round trip")
}

// MARK: - Conversion

do {
    let vtt = SubtitleConverter.convert("1\n00:00:01,000 --> 00:00:03,500\nHello\n\n", from: .srt, to: .vtt)
    check(vtt.hasPrefix("WEBVTT"), "srt→vtt header")
    check(vtt.contains("00:00:01.000 --> 00:00:03.500"), "srt→vtt timecodes")

    let srt = SubtitleConverter.convert("[00:00:01.000] Hello\n", from: .text, to: .srt)
    check(srt.contains("00:00:01,000 --> 00:00:01,000"), "txt→srt timecodes")
    check(srt.contains("Hello"), "txt→srt text")

    let ass = SubtitleConverter.convert("1\n00:00:01,000 --> 00:00:03,500\nHello\nWorld\n\n", from: .srt, to: .ass)
    let reparsed = SubtitleParser.parse(ass, format: .ass)
    checkEqual(reparsed.cues.count, 1, "srt→ass cues")
    checkEqual(reparsed.cues[0].text, "Hello\\NWorld", "srt→ass newline to \\N")
    check(!reparsed.styles.isEmpty, "srt→ass has styles")

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let src = dir.appendingPathComponent("movie.srt")
    try "1\n00:00:01,000 --> 00:00:02,000\nHi\n\n".write(to: src, atomically: true, encoding: .utf8)
    let out = try SubtitleConverter.convertFile(at: src, to: .vtt)
    checkEqual(out.pathExtension, "vtt", "convertFile extension")
    check((try String(contentsOf: out, encoding: .utf8)).hasPrefix("WEBVTT"), "convertFile content")
} catch {
    check(false, "conversion threw: \(error)")
}

// MARK: - Result

if failures == 0 {
    print("All \(checks) checks passed.")
} else {
    print("\(failures) of \(checks) checks FAILED.")
    exit(1)
}
