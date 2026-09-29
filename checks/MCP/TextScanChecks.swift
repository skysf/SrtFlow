import CoreGraphics
import Foundation
import SrtFlowMCPKit

// 扫画面里的字（look text_scan，方案第 55 条）：烧进去的字幕带（下方居中、字一直在变）、固定的字（水印、固定的标题）、
// 满屏的字（幻灯片）各认得出来、互不混；铺满时没有人、字多就对准字，focus=text 只看字，字比窗宽时说宽出去多少。
// 编法见 scripts/check-mcp.sh。

func runTextScanChecks() {
    textRegionChecks()
    textFocusChecks()
}

private func text(_ string: String, _ x: Double, _ y: Double, _ width: Double, _ height: Double) -> AIVision.Text {
    AIVision.Text(string: string, box: CGRect(x: x, y: y, width: width, height: height))
}

private func textRegionChecks() {
    // 十帧：八帧底部有在变的字幕，每帧右上角有水印，底部正中一直是同一行标题（不变 → 不算字幕），前六帧是满屏的幻灯片。
    let frames = (0..<10).map { index -> AITextRegions.Frame in
        var texts = [text("SKYLU", 0.86, 0.04, 0.1, 0.03), text("Lesson 1", 0.42, 0.95, 0.16, 0.03)]
        if index < 8 { texts.append(text("line number \(index)", 0.3, 0.84, 0.4, 0.06)) }
        if index < 6 {
            texts += [text("Title \(index)", 0.1, 0.15, 0.8, 0.08), text("point a \(index)", 0.12, 0.3, 0.6, 0.05),
                      text("point b \(index)", 0.12, 0.4, 0.6, 0.05), text("point c \(index)", 0.12, 0.5, 0.6, 0.05)]
        }
        return AITextRegions.Frame(time: Double(index) * 2, texts: texts)
    }
    let report = AITextRegions.report(frames)
    checkEqual(report.band?.coverage, 0.8, "text scan: burned-in subtitles along the bottom, in 8 of 10 frames")
    check(abs((report.band?.box.minY ?? 0) - 0.84) < 0.01 && abs((report.band?.box.maxY ?? 0) - 0.9) < 0.01,
          "text scan: the band's top and bottom are where the subtitle lines are (the fixed title below does not widen it)")
    checkEqual(report.band?.from, 0, "text scan: first seen")
    checkEqual(report.band?.to, 14, "text scan: last seen")
    checkEqual(Set(report.fixed.map(\.text)), ["SKYLU", "Lesson 1"], "text scan: the watermark and the fixed title stay in place")
    checkEqual(report.fixed.first { $0.text == "SKYLU" }?.coverage, 1, "text scan: the watermark is in every frame")
    checkEqual(report.heavy?.coverage, 0.6, "text scan: slides in 6 of 10 frames")
    check(abs((report.heavy?.box.minX ?? 0) - 0.1) < 0.01 && abs((report.heavy?.box.maxX ?? 0) - 0.9) < 0.01,
          "text scan: the slides' text spans 0.1–0.9 across (subtitles and watermark left out)")
    let json = AITextRegions.json(report, timeline: { $0 + 100 })
    checkEqual(json["subtitle_band"]?["from"]?.doubleValue, 100, "text scan: times on the timeline for a clip")
    check(json["subtitle_band"]?["hint"]?.stringValue?.contains("crop bottom 0.17") == true, "text scan: how much to crop off")
    checkEqual(AITextRegions.json(AITextRegions.report([.init(time: 0, texts: [])]))["found"]?.stringValue,
               "No text stays on screen.", "text scan: says so when there is nothing")

    // 跳角的水印：左下、右上来回出现 → 会动，报两处；同一处挨着的两个词并成一块。
    let jumping = (0..<8).map { index -> AITextRegions.Frame in
        let corner = index % 2 == 0 ? (x: 0.02, y: 0.93) : (x: 0.85, y: 0.03)
        return AITextRegions.Frame(time: Double(index), texts: [text("Studio", corner.x, corner.y, 0.05, 0.02)])
    }
    let moves = AITextRegions.report(jumping).fixed.first
    check(moves?.text == "Studio" && moves?.places.count == 2, "text scan: a watermark that jumps between corners is reported with its places")
    let twoWords = (0..<5).map { AITextRegions.Frame(time: Double($0), texts: [
        text("Sky", 0.01, 0.93, 0.03, 0.02), text("Studio", 0.045, 0.93, 0.05, 0.02)
    ]) }
    checkEqual(AITextRegions.report(twoWords).fixed.map(\.text), ["Sky Studio"], "text scan: neighbouring words in one place become one mark")
    let stacked = (0..<5).map { AITextRegions.Frame(time: Double($0), texts: [
        text("Studio", 0.01, 0.95, 0.05, 0.02), text("Sky", 0.012, 0.925, 0.03, 0.02)
    ]) }
    checkEqual(AITextRegions.report(stacked).fixed.map(\.text), ["Sky Studio"], "text scan: a logo stacked in two lines reads top line first")
    // 居中的幻灯片标题在顶上一直在变：不是字幕（只认下面）。
    let titles = (0..<6).map { AITextRegions.Frame(time: Double($0), texts: [text("SLIDE TITLE \($0)", 0.1, 0.08, 0.8, 0.08)]) }
    checkEqual(AITextRegions.report(titles).band, nil, "text scan: centred slide titles at the top are not a subtitle band")

    // 课程录屏（2026-09-29 验收实剪，L28 的样子）：字幕在 0.90–0.965、一半的帧有、每句都不同；幻灯片居中的标签在 0.77，
    // 一页停三帧、每帧都有。框只量字幕那一行 —— 以前按所有居中的字取，框从 0.77 起，叫人裁 0.24，会切掉幻灯片自己的标签。
    let course = (0..<12).map { index -> AITextRegions.Frame in
        var texts = [text("LABEL \(index / 3)", 0.4, 0.77, 0.2, 0.04)]
        if index % 2 == 0 { texts.append(text("字幕第\(index)句", 0.35, 0.9, 0.3, 0.065)) }
        return AITextRegions.Frame(time: Double(index) * 2, texts: texts)
    }
    let courseBand = AITextRegions.report(course).band
    check(abs((courseBand?.box.minY ?? 0) - 0.9) < 0.005, "text scan: slide labels that change page by page do not stretch the subtitle band (top \(courseBand?.box.minY ?? -1))")
    check(AITextRegions.json(AITextRegions.report(course))["subtitle_band"]?["hint"]?.stringValue?.contains("crop bottom 0.11") == true,
          "text scan: the crop only takes the subtitles off")
    // 两行的字幕：紧贴着的上一行一样大，也算进框里。
    let twoLines = (0..<6).map { index in AITextRegions.Frame(time: Double(index), texts: [
        text("upper \(index)", 0.3, 0.84, 0.4, 0.05), text("lower \(index)", 0.3, 0.895, 0.4, 0.05)
    ]) }
    check(abs((AITextRegions.report(twoLines).band?.box.minY ?? 0) - 0.84) < 0.005, "text scan: a two-line subtitle's upper line is in the band")

    // 幻灯片自己的字恰好贴在字幕上面（2026-09-29 复查，L27 的样子）：字幕在 0.886，只有一帧里幻灯片的标题在 0.768–0.874、
    // 贴着字幕。以前把它当「两行字幕的上一行」算进框里，框从 0.768 起，10% 分位被拉到 0.86，叫人裁 0.15，裁线切进了 PDF 页里的
    // 一行字。上一行要像字幕一样每句都换：至少两帧、两句不同的话才认。框只认字幕那一行：从 0.886 起，裁 0.12。
    let lone = (0..<8).map { index -> AITextRegions.Frame in
        var texts = [text("字幕第\(index)句", 0.3, 0.886, 0.4, 0.092)]
        if index == 3 { texts.append(text("Gemini - The 3 Models", 0.46, 0.768, 0.14, 0.106)) }
        return AITextRegions.Frame(time: Double(index) * 2, texts: texts)
    }
    let loneBand = AITextRegions.report(lone).band
    check(abs((loneBand?.box.minY ?? 0) - 0.886) < 0.005, "text scan: a slide's text right above the subtitle in one frame is not a second line (top \(loneBand?.box.minY ?? -1))")
    check(AITextRegions.json(AITextRegions.report(lone))["subtitle_band"]?["hint"]?.stringValue?.contains("crop bottom 0.12") == true,
          "text scan: so the crop is the subtitle's, not stretched by it")
    // 同一句幻灯片的字停了两帧（不到三成的帧，还不算固定的字）、都贴在字幕上面：还是同一句，不是每句都换的第二行。
    let repeated = (0..<8).map { index -> AITextRegions.Frame in
        var texts = [text("字幕第\(index)句", 0.3, 0.886, 0.4, 0.092)]
        if index == 2 || index == 3 { texts.append(text("Gemini - The 3 Models", 0.46, 0.768, 0.14, 0.106)) }
        return AITextRegions.Frame(time: Double(index) * 2, texts: texts)
    }
    check(abs((AITextRegions.report(repeated).band?.box.minY ?? 0) - 0.886) < 0.005, "text scan: the same slide text above the subtitle in two frames is not a second line either")
    // 真的会折行的字幕：上一行每句不同，隔几句折一次也认。
    let wrapping = (0..<10).map { index -> AITextRegions.Frame in
        var texts = [text("lower \(index)", 0.3, 0.895, 0.4, 0.05)]
        if index % 3 == 0 { texts.append(text("upper \(index)", 0.3, 0.84, 0.4, 0.05)) }
        return AITextRegions.Frame(time: Double(index) * 2, texts: texts)
    }
    check(abs((AITextRegions.report(wrapping).band?.box.minY ?? 0) - 0.84) < 0.02, "text scan: a subtitle that wraps now and then still has its upper line in the band")

    // 幻灯片 / PDF 往下滚出画面（2026-09-29，L27 的 PDF 页）：最底下那一行只露出上面一道，贴着画面底边（底边 0.997、高 0.011–0.028），
    // 每帧滚到不同的一行、字一直在变。它不是字幕；混进字幕那一堆，「不同的字最多」会偏袒它。字幕离得远（底边 0.95）时它一个人赢：
    // 框成了 0.983–0.997、叫人裁 0.03，真的字幕（0.87 起）一个字没裁。
    let scrolledFar = (0..<10).map { index -> AITextRegions.Frame in
        var texts = [text("cut off line \(index)", 0.25, 0.983, 0.5, 0.014)]
        if index % 3 == 0 { texts.append(text("字幕第\(index)句", 0.3, 0.87, 0.4, 0.08)) }
        return AITextRegions.Frame(time: Double(index) * 2, texts: texts)
    }
    let farBand = AITextRegions.report(scrolledFar).band
    check(abs((farBand?.box.minY ?? 0) - 0.87) < 0.005 && abs((farBand?.box.maxY ?? 0) - 0.95) < 0.005,
          "text scan: a line cut off by the bottom edge is not the subtitle band (band \(farBand?.box.minY ?? -1)–\(farBand?.box.maxY ?? -1))")
    check(AITextRegions.json(AITextRegions.report(scrolledFar))["subtitle_band"]?["hint"]?.stringValue?.contains("crop bottom 0.14") == true,
          "text scan: so the crop is for the real subtitles, not 0.03 off the edge")
    // 字幕离得近（底边 0.978，和它们差不到 0.02）：分到同一堆，框的底边被抬到 0.997。
    let scrolledNear = (0..<10).map { index -> AITextRegions.Frame in
        var texts = [text("cut off line \(index)", 0.25, 0.983, 0.5, 0.014)]
        if index % 3 == 0 { texts.append(text("字幕第\(index)句", 0.3, 0.886, 0.4, 0.092)) }
        return AITextRegions.Frame(time: Double(index) * 2, texts: texts)
    }
    let nearBand = AITextRegions.report(scrolledNear).band
    check(abs((nearBand?.box.maxY ?? 0) - 0.978) < 0.005, "text scan: the band's bottom is the subtitle's, not the cut-off line's 0.997 (bottom \(nearBand?.box.maxY ?? -1))")
    // 字幕真的贴着底边（底边 0.995、有一整行高）不是被切掉的：照样是字幕。
    let lowSubtitle = (0..<6).map { AITextRegions.Frame(time: Double($0), texts: [text("字幕第\($0)句", 0.3, 0.935, 0.4, 0.06)]) }
    check(abs((AITextRegions.report(lowSubtitle).band?.box.minY ?? 0) - 0.935) < 0.005, "text scan: a full-height subtitle line near the bottom edge is still a subtitle")
    // 太高的框（一行字幕的框被背景量大，L27 的 0.860–1.001）不算字幕行：算进去会多裁 0.04（那一帧字幕只有一行，字形在 0.90–0.965）。
    let oversized = (0..<8).map { index -> AITextRegions.Frame in
        var texts = [text("字幕第\(index)句", 0.3, 0.886, 0.4, 0.092)]
        if index == 4 { texts = [text("个视频中，我们将讨论钱的问题。", 0.27, 0.860, 0.57, 0.141)] }
        return AITextRegions.Frame(time: Double(index) * 2, texts: texts)
    }
    check(abs((AITextRegions.report(oversized).band?.box.minY ?? 0) - 0.886) < 0.005, "text scan: a box measured too tall for one line does not stretch the band")

    // 字幕稀疏、幻灯片的字多（2026-09-29，L27 的生产抽样：24 帧里只有 4 帧有字幕，幻灯片 0.81–0.84 一段里有 9 句不同的字，每页停两帧）：
    // 以前「不同的字最多」选了幻灯片，框从 0.78 起、叫人裁 0.23；字幕是够多的几堆里最下面的一堆。
    let sparse = (0..<24).map { index -> AITextRegions.Frame in
        var lines = index < 18 ? [text("slide line \(index / 2)", 0.15, 0.78 + Double(index / 2 % 4) * 0.008, 0.6, 0.03)] : []
        if index % 6 == 1 { lines.append(text("字幕第\(index)句", 0.3, 0.886, 0.4, 0.092)) }
        return AITextRegions.Frame(time: Double(index) * 6.7, texts: lines)
    }
    let sparseBand = AITextRegions.report(sparse).band
    check(abs((sparseBand?.box.minY ?? 0) - 0.886) < 0.005 && abs((sparseBand?.box.maxY ?? 0) - 0.978) < 0.005,
          "text scan: a sparse subtitle track below a slide's many text rows is still the band (band \(sparseBand?.box.minY ?? -1)–\(sparseBand?.box.maxY ?? -1))")
    // 下面再有一行、只有三句不同的话（页脚、台标的几种写法）撑不起字幕：最下面的一堆也得至少是最多那堆的三分之一。
    let footer = (0..<12).map { index -> AITextRegions.Frame in
        var lines = [text("字幕第\(index)句", 0.3, 0.85, 0.4, 0.05)]
        if index < 9 { lines.append(text("Ad number \(index / 3)", 0.4, 0.95, 0.2, 0.03)) }
        return AITextRegions.Frame(time: Double(index) * 2, texts: lines)
    }
    check(abs((AITextRegions.report(footer).band?.box.minY ?? 0) - 0.85) < 0.005, "text scan: a low footer with three different texts does not take the band from a full subtitle track")
    // 只有两句轮着出现：字没怎么变，不是字幕。
    let alternating = (0..<6).map { AITextRegions.Frame(time: Double($0), texts: [text($0 % 2 == 0 ? "Buy now" : "Sale today", 0.3, 0.85, 0.4, 0.06)]) }
    checkEqual(AITextRegions.report(alternating).band, nil, "text scan: two texts taking turns are not a subtitle band")

    // 提示要说清楚：裁的是一整条，条里别的字（幻灯片自己贴底边的小字）也一起没了。
    check(AITextRegions.json(AITextRegions.report(course))["subtitle_band"]?["hint"]?.stringValue?.contains("everything in that strip") == true,
          "text scan: the hint says the crop takes off whatever else is in the strip")

    // 同一行字一直不变：不是字幕（是固定的标题）。
    let fixedTitle = (0..<6).map { AITextRegions.Frame(time: Double($0), texts: [text("Chapter One", 0.3, 0.85, 0.4, 0.06)]) }
    checkEqual(AITextRegions.report(fixedTitle).band, nil, "text scan: a line that never changes is not a subtitle band")
    checkEqual(AITextRegions.report(fixedTitle).fixed.first?.text, "Chapter One", "text scan: it is fixed text instead")
}

private func textFocusChecks() {
    let window = CGSize(width: 0.316, height: 1)   // 16:9 素材转 9:16 时那扇窗
    let slide = AISubjectFocus.FrameFindings(texts: [
        CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.08), CGRect(x: 0.1, y: 0.35, width: 0.5, height: 0.05),
        CGRect(x: 0.1, y: 0.45, width: 0.5, height: 0.05)
    ], salient: [CGRect(x: 0.7, y: 0.7, width: 0.1, height: 0.1)])
    let aim = AISubjectFocus.focus(in: slide, window: window)
    checkEqual(aim?.kind, .text, "focus: no people but lots of text → aim at the text (before whatever stands out)")
    check(abs((aim?.point.x ?? 0) - 0.5) < 0.001, "focus: at the middle of the text")
    var withFace = slide
    withFace.faces = [CGRect(x: 0.8, y: 0.1, width: 0.1, height: 0.15)]
    checkEqual(AISubjectFocus.focus(in: withFace, window: window)?.kind, .face, "focus: a face still comes first")
    checkEqual(AISubjectFocus.focus(in: withFace, window: window, textFirst: true)?.kind, .text, "focus=text: only the text")
    let watermarkOnly = AISubjectFocus.FrameFindings(texts: [CGRect(x: 0.86, y: 0.04, width: 0.1, height: 0.03)],
                                                     salient: [CGRect(x: 0.2, y: 0.3, width: 0.2, height: 0.2)])
    checkEqual(AISubjectFocus.focus(in: watermarkOnly, window: window)?.kind, .salient, "focus: one small corner text is not \"lots of text\"")
    let combined = AISubjectFocus.combine(Array(repeating: slide, count: 5), window: window)
    checkEqual(combined?.kind, .text, "focus: five slide frames → text")
    check(abs((combined?.textCut ?? 0) - (0.8 - 0.316) / 0.8) < 0.001, "focus: says how much of the text is wider than the window")
    checkEqual((try? AIFramingRequest(AIToolArguments(["fit": "fill", "focus": "text"])))?.focus, .text, "edit_clip: focus=text")
}
