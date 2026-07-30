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

// MARK: - Result

if failures == 0 {
    print("All \(checks) checks passed.")
} else {
    print("\(failures) of \(checks) checks FAILED.")
    exit(1)
}
