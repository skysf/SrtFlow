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

// MARK: - Subtitle colour ↔ ASS

do {
    // ASS 的 alpha 是反的：00 不透明、FF 全透明；字节序也和 RGB 相反。
    checkEqual(SubtitleColor.white.assValue, "&H00FFFFFF", "white → ASS")
    checkEqual(SubtitleColor.black.assValue, "&H00000000", "black → ASS")
    checkEqual(SubtitleColor(red: 1, green: 0, blue: 0).assValue, "&H000000FF", "red → ASS is BGR order")
    checkEqual(SubtitleColor(red: 0, green: 0, blue: 1).assValue, "&H00FF0000", "blue → ASS is BGR order")
    checkEqual(SubtitleColor(red: 0, green: 0, blue: 0, opacity: 0).assValue, "&HFF000000", "transparent → ASS alpha FF")
    checkEqual(SubtitleColor(red: 0, green: 0, blue: 0, opacity: 0.5).assValue, "&H80000000", "half → ASS alpha 80")

    guard let parsed = SubtitleColor.fromASS("&H000000FF") else {
        check(false, "fromASS red parses"); exit(1)
    }
    checkEqual(parsed.red, 1, "fromASS red channel")
    checkEqual(parsed.green, 0, "fromASS green channel")
    checkEqual(parsed.blue, 0, "fromASS blue channel")
    checkEqual(parsed.opacity, 1, "fromASS opaque")
    checkEqual(SubtitleColor.fromASS("&HFF000000")?.opacity, 0, "fromASS transparent")
    // 六位写法没有 alpha 段，按不透明处理。
    checkEqual(SubtitleColor.fromASS("&HFFFFFF")?.opacity, 1, "fromASS 6-digit is opaque")
    check(SubtitleColor.fromASS("")  == nil, "fromASS rejects empty")

    // 往返一圈不掉精度。
    for value in ["&H00FFFFFF", "&H80112233", "&H00ABCDEF"] {
        checkEqual(SubtitleColor.fromASS(value)?.assValue, value, "ASS colour round trip \(value)")
    }
}

// MARK: - Burn-in style → ASS

do {
    var style = BurnInStyle.default
    style.fontName = "Hiragino Sans GB"
    style.fontSize = 56
    style.position = .bottomCenter
    style.marginVertical = 60

    let cues = [
        SubtitleCue(index: 1, start: 1, end: 3, text: "第一行\n第二行", styleName: "SomeOtherStyle"),
        // 源文件自带的覆盖标签必须被清掉，否则会盖过界面上调的样式。
        SubtitleCue(index: 2, start: 4, end: 6, text: "{\\pos(100,200)\\c&H00FF00&}带标签的文本")
    ]
    let ass = style.assDocument(cues: cues, aspectRatio: 16.0 / 9.0, title: "Demo")

    check(ass.contains("PlayResY: 1080"), "burn-in ASS uses 1080p reference canvas")
    check(ass.contains("PlayResX: 1920"), "burn-in ASS canvas width from aspect ratio")
    check(ass.contains("ScaledBorderAndShadow: yes"), "burn-in ASS scales border and shadow")
    check(ass.contains("Style: SrtFlow,Hiragino Sans GB,56,"), "burn-in ASS style line")
    check(ass.contains(",Default,") == false, "burn-in ASS has no leftover Default style reference")
    check(ass.contains("第一行\\N第二行"), "burn-in ASS keeps line breaks as \\N")
    check(!ass.contains("\\pos(100,200)"), "burn-in ASS strips source override tags")
    check(ass.contains("带标签的文本"), "burn-in ASS keeps text after stripping tags")
    // 所有条目都指到我们的样式，源里的 styleName 一律忽略。
    checkEqual(ass.components(separatedBy: "Dialogue: ").count - 1, 2, "burn-in ASS dialogue count")
    check(!ass.contains("SomeOtherStyle"), "burn-in ASS overrides per-cue style name")

    // 竖屏：画布宽度跟着宽高比变。
    let vertical = style.assDocument(cues: cues, aspectRatio: 1080.0 / 1920.0)
    check(vertical.contains("PlayResX: 608"), "burn-in ASS vertical canvas width")
    // 宽高比非法时回退到 16:9，而不是算出 0 或 NaN。
    check(style.assDocument(cues: [], aspectRatio: 0).contains("PlayResX: 1920"), "burn-in ASS falls back to 16:9")

    checkEqual(BurnInStyle.builtInPresets.count, 5, "built-in preset count")
    check(BurnInStyle.builtInPresets.allSatisfy(\.isBuiltIn), "presets marked built-in")
    checkEqual(Set(BurnInStyle.builtInPresets.map(\.id)).count, 5, "preset ids are unique")

    // 半透明底框那一档应该走 BorderStyle 3。
    guard let box = BurnInStyle.builtInPresets.first(where: { $0.borderStyle == .box }) else {
        check(false, "a box-style preset exists"); exit(1)
    }
    checkEqual(box.assStyle.borderStyle, 3, "box preset maps to ASS BorderStyle 3")
    // libass 在 BorderStyle 3 下是用 OutlineColour 画底框的，BackColour 只管投影。
    // 底框颜色若是透明、内边距若是 0，底框就整个不见了 —— 这里钉住这个语义。
    check(box.outlineColor.opacity > 0, "box preset's box colour is actually visible")
    check(box.outlineWidth > 0, "box preset has non-zero box padding")
    check(box.borderStyle.usesOutlineColorAsBox, "box mode repurposes the outline colour")
    check(!SubtitleBorderStyle.outline.usesOutlineColorAsBox, "outline mode keeps the outline colour")

    checkEqual(SubtitlePosition.bottomCenter.assAlignment, 2, "bottom-center alignment")
    checkEqual(SubtitlePosition.topRight.assAlignment, 9, "top-right alignment")
    checkEqual(SubtitlePosition.middleCenter.row, 1, "middle row index")
    checkEqual(SubtitlePosition.bottomRight.column, 2, "right column index")
}

// MARK: - ffmpeg 参数构建

do {
    // 用户手打的那条命令：-c:v libx264 -crf 23 -preset slow -c:a copy
    let base = FFmpegCommand(inputPath: "in.mp4", outputPath: "out.mp4", sourceHeight: 1080)
    let args = FFmpegArgumentBuilder.arguments(for: base)
    func indexOf(_ flag: String, in list: [String]) -> Int? { list.firstIndex(of: flag) }

    check(args.contains("-nostdin"), "always -nostdin so ffmpeg never blocks on our stdin")
    check(args.contains("-progress"), "encode reports progress")
    checkEqual(args[(indexOf("-c:v", in: args) ?? 0) + 1], "libx264", "default encoder is libx264")
    checkEqual(args[(indexOf("-crf", in: args) ?? 0) + 1], "23", "default crf 23")
    checkEqual(args[(indexOf("-preset", in: args) ?? 0) + 1], "slow", "default preset slow")
    checkEqual(args[(indexOf("-c:a", in: args) ?? 0) + 1], "copy", "audio copied by default")
    checkEqual(args[(indexOf("-pix_fmt", in: args) ?? 0) + 1], "yuv420p", "forces 8-bit 4:2:0 for compatibility")
    check(args.contains("+faststart"), "faststart on by default")
    checkEqual(args.last, "out.mp4", "output path goes last")
    // 输入必须排在所有 -map 前面。
    check((indexOf("-i", in: args) ?? 99) < (indexOf("-map", in: args) ?? 0), "inputs precede maps")
    check(args.contains("0:a:0?"), "optional audio map tolerates videos with no sound track")
    check(FFmpegArgumentBuilder.filterChain(for: base) == nil, "no filters when nothing to do")

    // 硬件档
    var hardware = base
    hardware.settings.encoder = .hardware
    hardware.settings.hardwareQuality = 60
    let hardwareArgs = FFmpegArgumentBuilder.arguments(for: hardware)
    checkEqual(hardwareArgs[(indexOf("-c:v", in: hardwareArgs) ?? 0) + 1], "h264_videotoolbox", "hardware encoder")
    checkEqual(hardwareArgs[(indexOf("-q:v", in: hardwareArgs) ?? 0) + 1], "60", "hardware quality")
    check(!hardwareArgs.contains("-crf"), "hardware path has no crf")
    check(!hardwareArgs.contains("-preset"), "hardware path has no x264 preset")
    check(hardwareArgs.contains("-spatial_aq"), "hardware path enables spatial AQ")

    // 音频不能 copy 时自动转 AAC
    var pcm = base
    pcm.audioCanCopy = false
    let pcmArgs = FFmpegArgumentBuilder.arguments(for: pcm)
    checkEqual(pcmArgs[(indexOf("-c:a", in: pcmArgs) ?? 0) + 1], "aac", "falls back to AAC when copy impossible")
    checkEqual(pcmArgs[(indexOf("-b:a", in: pcmArgs) ?? 0) + 1], "192k", "default AAC bitrate")

    // 没有音轨时完全不写音频参数
    var silent = base
    silent.hasAudio = false
    let silentArgs = FFmpegArgumentBuilder.arguments(for: silent)
    check(!silentArgs.contains("-c:a"), "no audio flags for a silent source")
    check(!silentArgs.contains("0:a:0?"), "no audio map for a silent source")

    // 缩放只降不升
    var downscale = base
    downscale.settings.resolution = .hd720
    checkEqual(FFmpegArgumentBuilder.filterChain(for: downscale), "scale=-2:720", "downscale 1080p→720p")
    var upscale = base
    upscale.sourceHeight = 480
    upscale.settings.resolution = .fhd1080
    check(FFmpegArgumentBuilder.filterChain(for: upscale) == nil, "never upscales a smaller source")
    var unknownHeight = base
    unknownHeight.sourceHeight = nil
    unknownHeight.settings.resolution = .hd720
    check(FFmpegArgumentBuilder.filterChain(for: unknownHeight) == nil, "skips scaling when source height unknown")

    // 帧率同样只降不升
    var dropFps = base
    dropFps.sourceFrameRate = 60
    dropFps.settings.frameRate = .fps30
    checkEqual(FFmpegArgumentBuilder.filterChain(for: dropFps), "fps=30", "60fps→30fps")
    var keepFps = base
    keepFps.sourceFrameRate = 24
    keepFps.settings.frameRate = .fps30
    check(FFmpegArgumentBuilder.filterChain(for: keepFps) == nil, "never interpolates up to a higher fps")

    // 滤镜顺序：降帧 → 缩放 → 叠字幕（字幕最后画，按输出分辨率渲染最清晰）
    var full = base
    full.sourceFrameRate = 60
    full.settings.frameRate = .fps30
    full.settings.resolution = .hd720
    full.burnIn = FFmpegCommand.BurnIn()
    checkEqual(
        FFmpegArgumentBuilder.filterChain(for: full),
        "fps=30,scale=-2:720,subtitles=filename=subtitle.ass:fontsdir=fonts",
        "filter order is fps → scale → subtitles"
    )

    // 软字幕轨要额外接一路输入，并且 map 得对上
    var soft = base
    soft.softSubtitlePath = "/tmp/x/track.srt"
    let softArgs = FFmpegArgumentBuilder.arguments(for: soft)
    checkEqual(softArgs.filter { $0 == "-i" }.count, 2, "soft subtitle track adds a second input")
    check(softArgs.contains("1:s:0?"), "soft subtitle track is mapped from input 1")
    checkEqual(softArgs[(indexOf("-c:s", in: softArgs) ?? 0) + 1], "mov_text", "mp4 subtitle codec")

    // 单帧预览：不能带编码参数，而且必须有 -copyts，否则字幕不会出现
    var still = base
    still.mode = .stillFrame(atSeconds: 12.5)
    still.outputPath = "preview.png"
    still.burnIn = FFmpegCommand.BurnIn()
    let stillArgs = FFmpegArgumentBuilder.arguments(for: still)
    check(stillArgs.contains("-copyts"), "still frame keeps source timestamps so subtitles render")
    checkEqual(stillArgs[(indexOf("-ss", in: stillArgs) ?? 0) + 1], "12.5", "still frame seek position")
    check((indexOf("-ss", in: stillArgs) ?? 99) < (indexOf("-i", in: stillArgs) ?? 0), "seek before input for speed")
    check(stillArgs.contains("-frames:v"), "still frame limits output to one frame")
    check(!stillArgs.contains("-c:v"), "still frame has no video encoder flags")
    check(!stillArgs.contains("-progress"), "still frame needs no progress stream")
    check(!stillArgs.contains("+faststart"), "still frame has no mp4 flags")
    check(stillArgs.contains("-an"), "still frame drops audio")

    // 硬件解码可以关掉（失败重试时用）
    var noHardware = base
    noHardware.useHardwareDecode = false
    check(!FFmpegArgumentBuilder.arguments(for: noHardware).contains("-hwaccel"), "hardware decode can be disabled")
    check(FFmpegArgumentBuilder.arguments(for: base).contains("videotoolbox"), "hardware decode on by default")

    // 元数据
    var metadata = base
    metadata.settings.stripMetadata = true
    metadata.settings.fastStart = false
    metadata.metadataTitle = "My Video"
    let metadataArgs = FFmpegArgumentBuilder.arguments(for: metadata)
    check(metadataArgs.contains("-map_metadata"), "strips metadata when asked")
    check(metadataArgs.contains("title=My Video"), "writes title metadata")
    check(!metadataArgs.contains("+faststart"), "faststart can be turned off")
}

// MARK: - 进度解析

do {
    var parser = FFmpegProgressParser()
    // 分块喂进来，模拟管道读到一半的情况。
    check(!parser.consume("frame=90\nfps=0.00\nout_time_us=30000"), "partial line yields no update")
    check(parser.consume("00\ntotal_size=3900841\nspeed=9.25x\nprogress=continue\n"), "batch boundary reported")
    checkEqual(parser.progress.frame, 90, "parsed frame")
    checkEqual(parser.progress.outTimeSeconds, 3, "parsed out_time_us as microseconds")
    checkEqual(parser.progress.totalSize, 3_900_841, "parsed total_size")
    checkEqual(parser.progress.speed, 9.25, "parsed speed with trailing x")
    check(!parser.progress.finished, "not finished at progress=continue")

    checkEqual(parser.progress.fraction(duration: 30), 0.1, "fraction of duration")
    checkEqual(parser.progress.remainingSeconds(duration: 30), 27 / 9.25, "eta from speed")
    check(parser.progress.fraction(duration: 0) == nil, "no fraction without duration")

    _ = parser.consume("progress=end\n")
    check(parser.progress.finished, "finished at progress=end")

    // N/A 要忽略，不能把 speed 写成 0
    var fresh = FFmpegProgressParser()
    _ = fresh.consume("speed=N/A\nout_time_us=N/A\nprogress=continue\n")
    check(fresh.progress.speed == nil, "ignores N/A speed")
    check(fresh.progress.outTimeSeconds == nil, "ignores N/A out_time")

    // 只有 out_time 没有 out_time_us 时的回退路径（6 位小数）
    var fallback = FFmpegProgressParser()
    _ = fallback.consume("out_time=00:00:03.500000\nprogress=continue\n")
    checkEqual(fallback.progress.outTimeSeconds, 3.5, "parses out_time with 6 fractional digits")

    // 进度比例不会越界
    var over = FFmpegProgressParser()
    _ = over.consume("out_time_us=99000000\nspeed=2.0x\nprogress=continue\n")
    checkEqual(over.progress.fraction(duration: 10), 1, "fraction clamped to 1")
    checkEqual(over.progress.remainingSeconds(duration: 10), 0, "eta clamped to 0")
    // 没有 speed 就没法估时间，这时候返回 nil 而不是瞎猜一个数。
    var noSpeed = FFmpegProgressParser()
    _ = noSpeed.consume("out_time_us=1000000\nprogress=continue\n")
    check(noSpeed.progress.remainingSeconds(duration: 10) == nil, "no eta without a speed reading")
}

// MARK: - 关联字幕：编辑合同（LinkedSubtitleEditing，计划第 8 节全部规则）

do {
    let a = SubtitleCue(index: 1, start: 0, end: 2, text: "hello there")
    let b = SubtitleCue(index: 2, start: 2, end: 4, text: "world")
    let c = SubtitleCue(index: 3, start: 4, end: 6, text: "again")

    func makePair() -> (SubtitleDocumentModel, SubtitleCompanion) {
        var translation = SubtitleDocumentModel(cues: [a, b, c])
        translation.cues[0].text = "你好"
        translation.cues[1].text = "世界"
        translation.cues[2].text = "再见"
        let companion = SubtitleCompanion(
            translation: translation,
            targetLanguage: "zh-Hans",
            cueMeta: [
                a.id: CueMeta(recognitionConfidence: 0.8),
                b.id: CueMeta(recognitionConfidence: 0.9),
                c.id: CueMeta(recognitionConfidence: 0.7)
            ]
        )
        return (SubtitleDocumentModel(cues: [a, b, c]), companion)
    }

    // 规则 1：改时间两轨同步。
    do {
        var (original, companion) = makePair()
        LinkedSubtitleEditing.setTime(id: a.id, start: 0.5, end: 1.5, original: &original, companion: &companion)
        checkEqual(original.cues[0].start, 0.5, "改时间：原文 start")
        checkEqual(companion.translation?.cues[0].start, 0.5, "改时间：译文同步 start")
        checkEqual(companion.translation?.cues[0].end, 1.5, "改时间：译文同步 end")
    }

    // 规则 2：改原文 → 译文 stale、置信度作废、origin 转人工。
    do {
        var (original, companion) = makePair()
        LinkedSubtitleEditing.setOriginalText(id: a.id, text: "hi", original: &original, companion: &companion)
        checkEqual(original.cues[0].text, "hi", "改原文：文本落盘")
        checkEqual(companion.cueMeta[a.id]?.translationStale, true, "改原文：译文标过期")
        checkEqual(companion.cueMeta[a.id]?.recognitionConfidence, nil, "改原文：置信度作废")
        checkEqual(companion.cueMeta[a.id]?.origin, .editedManually, "改原文：origin 转人工")
        // 相同文本 = 无操作。
        var before = companion
        LinkedSubtitleEditing.setOriginalText(id: b.id, text: "world", original: &original, companion: &before)
        checkEqual(before.cueMeta[b.id]?.recognitionConfidence, 0.9, "改原文：同文本不该动 meta")
    }

    // 规则 3：改译文 → 清 stale；译文轨缺该 cue 时按原文时间补一条。
    do {
        var (original, companion) = makePair()
        companion.cueMeta[a.id]?.translationStale = true
        LinkedSubtitleEditing.setTranslationText(id: a.id, text: "您好", original: &original, companion: &companion)
        checkEqual(companion.translation?.cues[0].text, "您好", "改译文：文本落盘")
        checkEqual(companion.cueMeta[a.id]?.translationStale, false, "改译文：清 stale")

        companion.translation?.removeCues(ids: [b.id])
        LinkedSubtitleEditing.setTranslationText(id: b.id, text: "补译", original: &original, companion: &companion)
        let refilled = companion.translation?.cues.first { $0.id == b.id }
        checkEqual(refilled?.text, "补译", "改译文：缺条时补一条")
        checkEqual(refilled?.start, 2, "改译文：补条沿用原文时间")
    }

    // 规则 4：删除三方同删。
    do {
        var (original, companion) = makePair()
        LinkedSubtitleEditing.removeCues(ids: [b.id], original: &original, companion: &companion)
        checkEqual(original.cues.map(\.id), [a.id, c.id], "删除：原文轨删掉")
        checkEqual(companion.translation?.cues.map(\.id), [a.id, c.id], "删除：译文轨同删")
        checkEqual(companion.cueMeta[b.id], nil, "删除：meta 同删")
        checkEqual(original.cues.map(\.index), [1, 2], "删除：原文要重排 index")
    }

    // 规则 5：拆分 —— 首条留 ID、次条新 UUID、译文后半置空、双双标 stale。
    do {
        var (original, companion) = makePair()
        let newID = UUID()
        let ok = LinkedSubtitleEditing.splitCue(id: a.id, at: 1, newID: newID, original: &original, companion: &companion)
        check(ok, "拆分：合法拆分点要成功")
        checkEqual(original.cues.map(\.id), [a.id, newID, b.id, c.id], "拆分：首条留原 ID、次条新 UUID")
        checkEqual(original.cues[0].end, 1, "拆分：前半 end = 拆分点")
        checkEqual(original.cues[1].start, 1, "拆分：后半 start = 拆分点")
        checkEqual(original.cues[1].end, 2, "拆分：后半沿用原 end")
        checkEqual(companion.translation?.cues.map(\.id), [a.id, newID, b.id, c.id], "拆分：译文轨同拆")
        checkEqual(companion.translation?.cues[0].text, "你好", "拆分：译文整体留前半")
        checkEqual(companion.translation?.cues[1].text, "", "拆分：译文后半置空")
        checkEqual(companion.cueMeta[a.id]?.translationStale, true, "拆分：前半标 stale")
        checkEqual(companion.cueMeta[newID]?.translationStale, true, "拆分：后半标 stale")
        checkEqual(companion.cueMeta[a.id]?.recognitionConfidence, nil, "拆分：置信度作废")
        checkEqual(original.cues.map(\.index), [1, 2, 3, 4], "拆分：index 重排")

        check(
            !LinkedSubtitleEditing.splitCue(id: b.id, at: 2, original: &original, companion: &companion),
            "拆分：落在边界上要拒绝"
        )
    }

    // 规则 6：合并 —— 沿用文档序首条 ID、文本拼接、时间取并、删其余 meta。
    do {
        var (original, companion) = makePair()
        let ok = LinkedSubtitleEditing.mergeCues(ids: [b.id, a.id], original: &original, companion: &companion)
        check(ok, "合并：两条要能合")
        checkEqual(original.cues.map(\.id), [a.id, c.id], "合并：沿用文档序首条 ID")
        checkEqual(original.cues[0].text, "hello there world", "合并：原文拼接")
        checkEqual(original.cues[0].start, 0, "合并：时间取并集起点")
        checkEqual(original.cues[0].end, 4, "合并：时间取并集终点")
        checkEqual(companion.translation?.cues[0].text, "你好 世界", "合并：译文拼接")
        checkEqual(companion.cueMeta[b.id], nil, "合并：被并条目的 meta 删掉")
        checkEqual(companion.cueMeta[a.id]?.translationStale, true, "合并：结果标 stale")
        check(
            !LinkedSubtitleEditing.mergeCues(ids: [c.id], original: &original, companion: &companion),
            "合并：单条不该动"
        )
    }

    // normalize：失锚译文与孤儿 meta 清干净，空 companion 判定正确。
    do {
        var (original, companion) = makePair()
        let ghost = UUID()
        companion.cueMeta[ghost] = CueMeta()
        companion.translation?.cues[0].id = ghost
        companion.normalize(originalCueIDs: Set(original.cues.map(\.id)))
        checkEqual(companion.translation?.cues.count, 2, "normalize：失锚译文 cue 清掉")
        checkEqual(companion.cueMeta[ghost], nil, "normalize：孤儿 meta 清掉")

        var empty = SubtitleCompanion()
        check(!empty.hasPersistentData, "空 companion 不算持久数据")
        empty.sourceLanguage = "en"
        check(empty.hasPersistentData, "只有语言字段也算持久数据（旧版会静默丢）")
    }
}

// MARK: - 关联字幕：宽容 Codable

do {
    // 缺键 / 坏枚举 / 坏 UUID 键都不许崩，各自退回默认或丢弃。
    let json = """
    {
      "origin": "fromMars",
      "cueMeta": {
        "not-a-uuid": { "translationStale": true },
        "6BA7B810-9DAD-11D1-80B4-00C04FD430C8": { "origin": "alien", "translationStale": true }
      }
    }
    """
    let decoded = try JSONDecoder().decode(SubtitleCompanion.self, from: Data(json.utf8))
    checkEqual(decoded.origin, .generated, "坏 companion origin 退回兜底")
    checkEqual(decoded.cueMeta.count, 1, "坏 UUID 键要丢弃")
    let meta = decoded.cueMeta[UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!]
    checkEqual(meta?.origin, .generated, "坏 cue origin 退回兜底")
    checkEqual(meta?.translationStale, true, "认识的字段照常解")
    checkEqual(meta?.readingSpeedWarning, false, "缺的字段取默认值")

    // 空对象也能解（全默认）。
    let bare = try JSONDecoder().decode(SubtitleCompanion.self, from: Data("{}".utf8))
    check(!bare.hasPersistentData, "空对象解出来是无数据 companion")

    // 往返：uuidString 作键的 cueMeta 对象编码。
    let cue = SubtitleCue(index: 1, start: 0, end: 1, text: "x")
    let full = SubtitleCompanion(
        translation: SubtitleDocumentModel(cues: [cue]),
        targetLanguage: "ja",
        sourceLanguage: "en",
        origin: .imported,
        generation: GenerationSnapshot(module: "SpeechTranscriber", segmentationConfigVersion: 1),
        cueMeta: [cue.id: CueMeta(recognitionConfidence: 0.5, provenance: CueProvenance(clipID: UUID(), sourceStart: 3, sourceEnd: 4))]
    )
    let data = try JSONEncoder().encode(full)
    let back = try JSONDecoder().decode(SubtitleCompanion.self, from: data)
    checkEqual(back, full, "companion 编解码往返无损")
    let rawObject = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let rawMeta = rawObject?["cueMeta"] as? [String: Any]
    check(rawMeta?[cue.id.uuidString] != nil, "cueMeta 要以 uuidString 为键编码成 JSON 对象")
}

// MARK: - 字幕分段：成句、约束、变速、边界合同

do {
    func window(
        src: ClosedRange<Double>, tlStart: Double = 0, speed: Double = 1, lane: Int = 0,
        clip: UUID = UUID()
    ) -> SubtitleClipWindow {
        SubtitleClipWindow(
            clipID: clip, assetFingerprint: "asset-a",
            sourceStart: src.lowerBound, sourceEnd: src.upperBound,
            timelineStart: tlStart, speed: speed, laneRank: lane
        )
    }
    // 识别器风格的词流：英文词自带前导空格、标点附着词尾。
    let speech: [TimedWord] = [
        TimedWord(text: "Hello,", start: 0.0, end: 0.4, confidence: 0.9),
        TimedWord(text: " world.", start: 0.5, end: 0.9, confidence: 0.7),
        TimedWord(text: " This", start: 2.0, end: 2.3, confidence: 0.95),
        TimedWord(text: " is", start: 2.3, end: 2.5, confidence: 1.0),
        TimedWord(text: " a", start: 2.5, end: 2.6, confidence: 1.0),
        TimedWord(text: " test.", start: 2.6, end: 3.0, confidence: 0.9)
    ]

    // 1×：两句 → 两条 cue，标点断句，置信度取均值。
    do {
        let out = SubtitleSegmenter.segment(words: speech, window: window(src: 0...10))
        checkEqual(out.cues.count, 2, "1×：两句两条 cue")
        checkEqual(out.cues.first?.text, "Hello, world.", "1×：句一文本")
        checkEqual(out.cues.last?.text, "This is a test.", "1×：句二文本")
        checkEqual(out.cues.first?.start, 0, "1×：句一起点")
        checkEqual(out.cues.last?.start, 2.0, "1×：句二起点")
        if let id = out.cues.first?.id, let meta = out.meta[id] {
            check(abs((meta.recognitionConfidence ?? 0) - 0.8) < 0.0001, "1×：置信度均值")
            checkEqual(meta.readingSpeedWarning, false, "1×：正常语速无告警")
            checkEqual(meta.provenance?.sourceAssetFingerprint, "asset-a", "1×：provenance 带素材指纹")
            checkEqual(meta.provenance?.sourceStart, 0, "1×：provenance 源起点")
        }
    }

    // 2×：映射到时间线（timelineStart 5），时长减半后向后借位补最短时长。
    do {
        let out = SubtitleSegmenter.segment(words: speech, window: window(src: 0...10, tlStart: 5, speed: 2))
        checkEqual(out.cues.count, 2, "2×：仍是两条")
        checkEqual(out.cues.first?.start, 5, "2×：起点映射")
        checkEqual(out.cues.last?.start, 6.0, "2×：句二 2.0s→6.0s")
        check(abs((out.cues.first?.duration ?? 0) - 0.7) < 0.0001, "2×：短 cue 借位到最短时长")
    }

    // 0.1×：一句在时间线上被拉到 10s，超 maxCueDuration → 拆成多条 ——
    // 同一素材不同 speed 分段不同是合同行为。
    do {
        let out = SubtitleSegmenter.segment(
            words: Array(speech[2...]), window: window(src: 0...10, speed: 0.1)
        )
        check(out.cues.count > 1, "0.1×：超长句要按词边界拆条")
        for cue in out.cues {
            check(cue.duration <= 7.0 + 0.0001, "0.1×：每条不超 maxCueDuration")
        }
    }

    // 8×：两句背靠背，前句借不到空档 → CPS 无解，如实告警。
    do {
        let fast: [TimedWord] = [
            TimedWord(text: "Fast one.", start: 0.0, end: 1.0),
            TimedWord(text: " Two.", start: 1.0, end: 1.5)
        ]
        let out = SubtitleSegmenter.segment(words: fast, window: window(src: 0...10, speed: 8))
        checkEqual(out.cues.count, 2, "8×：两句两条")
        if let first = out.cues.first {
            check(first.duration < 0.2, "8×：前句被后句顶住借不到位")
            checkEqual(out.meta[first.id]?.readingSpeedWarning, true, "8×：无解要告警")
        }
        if let second = out.cues.last {
            checkEqual(out.meta[second.id]?.readingSpeedWarning, false, "8×：后句借到位就不告警")
        }
    }

    // 边界合同：半开区间中点归属，相邻分片不重复不遗漏；clamp 零时长丢弃。
    do {
        let a = window(src: 0...2.45)
        let b = window(src: 2.45...10, tlStart: 2.45)
        let outA = SubtitleSegmenter.segment(words: speech, window: a)
        let outB = SubtitleSegmenter.segment(words: speech, window: b)
        let textA = outA.cues.map(\.text).joined(separator: "|")
        let textB = outB.cues.map(\.text).joined(separator: "|")
        check(textA.contains("This is"), "边界：中点 2.4 的词归前片")
        check(!textA.contains("a test"), "边界：中点 2.55 的词不归前片")
        check(textB.contains("a test."), "边界：后片接住剩余词")
        check(!textB.contains("This"), "边界：前片的词不重复出现在后片")
        let wordsA = SubtitleSegmenter.attributeWords(speech, to: a).count
        let wordsB = SubtitleSegmenter.attributeWords(speech, to: b).count
        checkEqual(wordsA + wordsB, speech.count, "边界：两片词数合计 = 全量，无重复无遗漏")

        let degenerate = [TimedWord(text: "x", start: 2.45, end: 2.45)]
        check(
            SubtitleSegmenter.attributeWords(degenerate, to: b).isEmpty,
            "边界：clamp 后零时长要丢弃"
        )
    }

    // 折行：词边界贪心折行，不切词。
    do {
        let cfg = SubtitleSegmentationConfig(maxLineCount: 2, maxLineLength: 10)
        let words: [TimedWord] = [
            TimedWord(text: "aaaa", start: 0, end: 1),
            TimedWord(text: " bbbb", start: 1, end: 2),
            TimedWord(text: " cccc", start: 2, end: 3)
        ]
        let out = SubtitleSegmenter.segment(words: words, window: window(src: 0...10), config: cfg)
        checkEqual(out.cues.first?.text, "aaaa bbbb\ncccc", "折行：贪心塞行、词边界换行")
    }

    // 停顿断句：无标点也按停顿切。
    do {
        let words: [TimedWord] = [
            TimedWord(text: "无标点", start: 0, end: 0.5),
            TimedWord(text: "的话", start: 0.5, end: 1.0),
            TimedWord(text: "靠停顿", start: 2.5, end: 3.0)
        ]
        let out = SubtitleSegmenter.segment(words: words, window: window(src: 0...10))
        checkEqual(out.cues.count, 2, "停顿：超阈值断句")
        checkEqual(out.cues.first?.text, "无标点的话", "停顿：中文词直接相连")
    }
}

// MARK: - 重叠 cue 排序合同（预览与烧录共用的唯一实现）

do {
    let clipMain = UUID()
    let clipAudio = UUID()
    var meta: [UUID: CueMeta] = [:]
    var manual = SubtitleCue(start: 1, end: 3, text: "manual")
    var fromAudio = SubtitleCue(start: 1, end: 3, text: "audio-lane")
    var fromMain = SubtitleCue(start: 1, end: 3, text: "main-lane")
    let later = SubtitleCue(start: 2, end: 4, text: "later")
    meta[fromAudio.id] = CueMeta(provenance: CueProvenance(clipID: clipAudio))
    meta[fromMain.id] = CueMeta(provenance: CueProvenance(clipID: clipMain))
    let rank: (UUID?) -> Int = { id in
        switch id {
        case clipMain: return 0
        case clipAudio: return 1
        default: return -1
        }
    }

    let active = SubtitleOverlap.active(at: 2, in: [manual, fromAudio, fromMain, later])
    checkEqual(active.count, 4, "active：半开区间 start<=t<end")
    checkEqual(SubtitleOverlap.active(at: 4, in: [later]).count, 0, "active：end 时刻不算活动")

    let ordered = SubtitleOverlap.ordered(active, meta: meta, laneRank: rank)
    checkEqual(
        ordered.map(\.text), ["manual", "main-lane", "audio-lane", "later"],
        "排序：start 优先，再按轨道秩（无 provenance 最前）"
    )
    // 稳定性：重复排序结果一致。
    checkEqual(
        SubtitleOverlap.ordered(ordered.shuffled(), meta: meta, laneRank: rank).map(\.id),
        ordered.map(\.id),
        "排序：全序稳定，与输入顺序无关"
    )
    _ = manual; _ = fromAudio; _ = fromMain
}

// MARK: - 转写缓存区间账本

do {
    typealias R = SourceRange
    checkEqual(
        TranscriptLedger.normalize([R(start: 3, end: 4), R(start: 0, end: 1), R(start: 0.9995, end: 2)]),
        [R(start: 0, end: 2), R(start: 3, end: 4)],
        "账本：排序合并、epsilon 吸毛刺"
    )
    checkEqual(
        TranscriptLedger.gaps(
            desired: [R(start: 0, end: 10)],
            covered: [R(start: 2, end: 3), R(start: 5, end: 7)]
        ),
        [R(start: 0, end: 2), R(start: 3, end: 5), R(start: 7, end: 10)],
        "账本：缺口 = desired − covered"
    )
    checkEqual(
        TranscriptLedger.gaps(desired: [R(start: 2.5, end: 2.9)], covered: [R(start: 2, end: 3)]),
        [],
        "账本：全覆盖无缺口"
    )
    checkEqual(
        TranscriptLedger.padded(
            [R(start: 2, end: 3), R(start: 3.5, end: 4)], padding: 0.5,
            within: R(start: 0, end: 4.2)
        ),
        [R(start: 1.5, end: 4.2)],
        "账本：padding 后夹回素材范围并合并"
    )

    // 固定窗口切分：长素材断点续跑的粒度（每窗转写完立即落盘）。
    checkEqual(
        TranscriptLedger.windows([R(start: 0, end: 300)], maxDuration: 120),
        [R(start: 0, end: 120), R(start: 120, end: 240), R(start: 240, end: 300)],
        "账本：大缺口切成固定窗口"
    )
    checkEqual(
        TranscriptLedger.windows([R(start: 5, end: 20), R(start: 100, end: 130)], maxDuration: 120),
        [R(start: 5, end: 20), R(start: 100, end: 130)],
        "账本：小缺口不切"
    )
    check(
        TranscriptLedger.windows([R(start: 0, end: 250)], maxDuration: 120)
            .reduce(0) { $0 + $1.duration } == 250,
        "账本：切窗后总时长不变"
    )

    var entry = TranscriptCacheEntry(
        fingerprint: "f1", localeIdentifier: "en_US",
        transcriber: "SpeechTranscriber", configVersion: 1
    )
    entry.merge(
        words: [TimedWord(text: "old", start: 1, end: 2)],
        analyzed: R(start: 0, end: 3)
    )
    // 无语音的区间也要记 covered。
    entry.merge(words: [], analyzed: R(start: 3, end: 5))
    checkEqual(entry.covered, [R(start: 0, end: 5)], "账本：无语音区间也记 covered")
    // 重转区间内旧词被新结果覆盖。
    entry.merge(
        words: [TimedWord(text: "new", start: 1.2, end: 1.8)],
        analyzed: R(start: 1, end: 2)
    )
    checkEqual(entry.words.map(\.text), ["new"], "账本：重转区间旧词被替换")
    check(
        entry.matches(fingerprint: "f1", localeIdentifier: "en_US", transcriber: "SpeechTranscriber", configVersion: 1),
        "账本：指纹配置齐同才命中"
    )
    check(
        !entry.matches(fingerprint: "f1", localeIdentifier: "en_US", transcriber: "SpeechTranscriber", configVersion: 2),
        "账本：配置变了要失效"
    )
}

// MARK: - 字幕导出规划器

do {
    let a = SubtitleCue(index: 1, start: 0, end: 2, text: "hello")
    let b = SubtitleCue(index: 2, start: 2, end: 4, text: "world")
    let original = SubtitleDocumentModel(cues: [a, b])
    var translation = SubtitleDocumentModel(cues: [a])
    translation.cues[0].text = "你好"

    let bilingual = SubtitleExportPlanner.bilingualDocument(original: original, translation: translation)
    checkEqual(bilingual.cues[0].text, "hello\n你好", "双语：原文上译文下")
    checkEqual(bilingual.cues[1].text, "world", "双语：缺译文的行只有原文，不编造")

    checkEqual(
        SubtitleExportPlanner.fileName(
            base: "movie", choice: .translation, sourceLanguage: "en",
            targetLanguage: "zh-Hans", format: .srt
        ),
        "movie.zh-Hans.srt", "命名：译文带目标语言标签"
    )
    checkEqual(
        SubtitleExportPlanner.fileName(
            base: "movie", choice: .bilingual, sourceLanguage: "en",
            targetLanguage: "zh-Hans", format: .vtt
        ),
        "movie.en-zh-Hans.vtt", "命名：双语 <src>-<dst>"
    )
    checkEqual(
        SubtitleExportPlanner.fileName(
            base: "movie", choice: .original, sourceLanguage: nil,
            targetLanguage: nil, format: .srt
        ),
        "movie.srt", "命名：没有语言标签就省略"
    )

    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("srtflow-planner-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // 冲突追加 -2/-3。
    try Data("x".utf8).write(to: dir.appendingPathComponent("movie.srt"))
    let next = SubtitleExportPlanner.availableURL(directory: dir, fileName: "movie.srt")
    checkEqual(next.lastPathComponent, "movie-2.srt", "冲突：追加 -2")

    // 写盘 → 回读校验 → 能再解析。
    let written = try SubtitleExportPlanner.writeValidated(original, format: .srt, to: next)
    let parsed = SubtitleParser.parse(
        try String(contentsOf: written, encoding: .utf8), format: .srt, filename: "movie-2.srt"
    )
    checkEqual(parsed.cues.count, 2, "写盘：SRT 回读 cue 数一致")
    checkEqual(parsed.cues.first?.text, "hello", "写盘：内容无损")

    let vtt = try SubtitleExportPlanner.writeValidated(
        translation, format: .vtt, to: dir.appendingPathComponent("movie.zh-Hans.vtt")
    )
    check(
        try String(contentsOf: vtt, encoding: .utf8).hasPrefix("WEBVTT"),
        "写盘：VTT 头正确"
    )

    // 失败路径：目标目录不存在 → 抛错，且不产生半截文件。
    let bogus = dir.appendingPathComponent("no-such-dir/out.srt")
    check(
        (try? SubtitleExportPlanner.writeValidated(original, format: .srt, to: bogus)) == nil,
        "写盘：坏目录要抛错"
    )
    check(
        !FileManager.default.fileExists(atPath: bogus.path),
        "写盘：失败不留半截文件"
    )
    // 既有文件在失败场景下原样保留。
    let precious = dir.appendingPathComponent("movie.srt")
    checkEqual(
        try String(contentsOf: precious, encoding: .utf8), "x",
        "写盘：规划器永不碰用户已有文件"
    )
}

// MARK: - Result

// 录屏与工程帧率的检查放在 ScreenRecordingChecks.swift 里（顶层脚本作用域
// 塞太多断言会把 Swift 类型检查拖垮，实测卡 20 分钟没编完）。
runScreenRecordingChecks()
runLanguageDetectionChecks()

if failures == 0 {
    print("All \(checks) checks passed.")
} else {
    print("\(failures) of \(checks) checks FAILED.")
    exit(1)
}
