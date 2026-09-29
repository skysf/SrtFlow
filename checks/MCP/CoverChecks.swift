import CoreGraphics
import Foundation
import SrtFlowMCPKit

// 盖一块（模糊 / 马赛克，2026-09-30，方案第 56 条）的 AI 这一侧：
// - set_shape 认 blur / mosaic（默认大小同长方形、strength 夹在 2…80、不画东西所以没有颜色 / 线宽 / 实心 / 旋转；写回给 AI 的样子）；
//   工具目录里的种类词表和 App 里的 `ShapeKind` 逐项对账（小程序不链接 App 的代码，词表是抄的）；
// - look text_scan 对时间线上的一段，把源画面上的框换成画布上的框（裁切 → 翻转 → 缩放进摆放框 → 绕框中心旋转）、
//   写成 set_shape 直接能抄的参数（字幕带要盖整条画面宽，报出来的左右不可靠）。
// 编法见 scripts/check-mcp.sh。

private func clip(crop: ClipCrop? = nil, placement: ClipPlacement? = nil, flipped: Bool = false, rotation: Double = 0,
                  size: CGSize = CGSize(width: 1920, height: 1080)) -> EditClip {
    let info = MediaInfo(duration: 10, displaySize: size, frameRate: 30, videoCodec: "h264", audioCodec: nil,
                         hasAudio: false, audioCanCopyToMP4: false, fileBytes: 1)
    var clip = EditClip(sourceURL: URL(fileURLWithPath: "/tmp/x.mp4"), sourceDuration: 10, timelineStart: 10, info: info)
    clip.crop = crop
    clip.placement = placement
    clip.flippedHorizontally = flipped
    clip.rotationDegrees = rotation
    return clip
}

private func close(_ a: CGRect?, _ b: CGRect, _ message: String) {
    guard let a else { check(false, "\(message): got nil"); return }
    check(abs(a.minX - b.minX) < 1e-6 && abs(a.minY - b.minY) < 1e-6 && abs(a.width - b.width) < 1e-6 && abs(a.height - b.height) < 1e-6,
          "\(message): got \(a), expected \(b)")
}

func runCoverChecks() {
    // ---- set_shape：盖一块
    let blur = try? AIShapeChange(args(["kind": "blur", "strength": 500, "rotation": 30, "color": "#FF0000", "filled": true])).makeShape(at: 2)
    checkEqual(blur?.kind, .blur, "kind=blur adds a cover")
    checkEqual(blur?.coverAmount, 80, "strength stops at 80")
    checkEqual(blur.map { [$0.width, $0.height] }, [0.3, 0.22], "a new cover is 0.3 × 0.22 like a rectangle")
    checkEqual(blur?.rotationDegrees, 0, "a cover does not turn")
    check(blur?.isFilled == false, "a cover is never filled")
    checkEqual((try? AIShapeChange(args(["kind": "mosaic"])).makeShape(at: 0))?.coverAmount, ShapeKind.mosaic.defaultCoverAmount, "no strength → the kind's default")
    checkEqual((try? AIShapeChange(args(["kind": "blur", "strength": 0.1])).makeShape(at: 0))?.coverAmount, 2, "strength starts at 2")
    if var existing = blur {
        (try? AIShapeChange(args(["strength": 12, "height": 0.1])))?.apply(to: &existing)
        checkEqual(existing.coverAmount, 12, "changing only the strength keeps the rest")
        checkEqual(existing.height, 0.1, "height of a cover follows like a rectangle")
        var state = TimelineState()
        state.shapes = [existing]
        let summary = AIShapeChange.summary(existing, ids: AIShortIDs(state: state))
        check(summary["strength"]?.doubleValue == 12 && summary["color"] == nil && summary["line_width"] == nil && summary["kind"]?.stringValue == "blur",
              "a cover is reported with its strength, without colour or line width")
    }
    let catalog = MCPToolName.setShape.definition
    let kinds = catalog.inputSchema["properties"]?["kind"]?["enum"]?.arrayValue?.compactMap(\.stringValue)
    checkEqual(kinds, ShapeKind.allCases.map(\.rawValue), "set_shape's kind list matches ShapeKind")
    check(catalog.inputSchema["properties"]?["strength"] != nil && catalog.description.contains("blur"), "set_shape says what blur / mosaic and strength are")

    // ---- 源画面上的框 → 画布上的框
    let wide = CGSize(width: 1920, height: 1080), tall = CGSize(width: 1080, height: 1920)
    let box = CGRect(x: 0.2, y: 0.1, width: 0.3, height: 0.2)
    close(AICoverBox.canvasRect(of: box, on: clip(), canvas: wide), box, "16:9 clip on a 16:9 canvas: the box stays where it is")
    // 横屏素材放进竖屏画布：宽铺满、高 = 0.3164（9:16 画布里的 16:9），上下各留 0.3418。
    close(AICoverBox.canvasRect(of: CGRect(x: 0, y: 0.5, width: 1, height: 0.5), on: clip(), canvas: tall),
          CGRect(x: 0, y: 0.5, width: 1, height: 0.5 * 607.5 / 1920), "the lower half of a 16:9 clip in a 9:16 canvas")
    // 右边裁掉 0.4（剩 0.6 宽 = 1152 × 1080）：画布正好是裁后的样子，摆放框铺满。
    let cropped = clip(crop: ClipCrop(trailing: 0.4))
    let croppedCanvas = CGSize(width: 1152, height: 1080)
    check(AICoverBox.canvasRect(of: CGRect(x: 0.7, y: 0, width: 0.2, height: 1), on: cropped, canvas: croppedCanvas) == nil, "a box that was cropped away has no place on the canvas")
    close(AICoverBox.canvasRect(of: CGRect(x: 0.5, y: 0, width: 0.2, height: 1), on: cropped, canvas: croppedCanvas),
          CGRect(x: 0.5 / 0.6, y: 0, width: 1 - 0.5 / 0.6, height: 1), "half the box is cropped, the rest is kept and lands at the right edge")
    close(AICoverBox.canvasRect(of: CGRect(x: 0, y: 0, width: 0.25, height: 1), on: clip(flipped: true), canvas: wide),
          CGRect(x: 0.75, y: 0, width: 0.25, height: 1), "a flipped clip mirrors the box")
    let placed = clip(placement: ClipPlacement(centerX: 0.75, centerY: 0.5, width: 0.5, height: 0.5))
    close(AICoverBox.canvasRect(of: CGRect(x: 0, y: 0, width: 1, height: 1), on: placed, canvas: wide), CGRect(x: 0.5, y: 0.25, width: 0.5, height: 0.5),
          "a placed clip: the whole picture lands in its placement box")
    let square = CGSize(width: 1000, height: 1000)
    close(AICoverBox.canvasRect(of: CGRect(x: 0, y: 0, width: 0.5, height: 1), on: clip(rotation: 90, size: square), canvas: square),
          CGRect(x: 0, y: 0, width: 1, height: 0.5), "turned 90° clockwise, the left half becomes the top half")

    // ---- set_shape 的参数：中心 + 宽高，四周留一圈，收进画布
    let args = AICoverBox.shapeArguments(covering: CGRect(x: 0.5, y: 0.8, width: 0.5, height: 0.2), margin: 0.01)
    // 四周各留 0.01：右边和下边探出画布的部分收掉，所以宽 0.51、高 0.21，中心跟着挪。
    checkEqual(args["width"]?.doubleValue, 0.51, "the margin stops at the frame's edge")
    checkEqual(args["x"]?.doubleValue, 0.745, "x is the centre of the padded, clamped box")
    checkEqual(args["y"]?.doubleValue, 0.895, "y is the centre of the padded, clamped box")
    checkEqual(args["height"]?.doubleValue, 0.21, "the height is clamped too")
    checkEqual(AICoverBox.bandSource(CGRect(x: 0.3, y: 0.88, width: 0.4, height: 0.09)), CGRect(x: 0, y: 0.87, width: 1, height: 0.13), "the band's strip is the whole width down to the bottom")

    // ---- text_scan 的结果里补上 cover：字幕带（整条宽）、固定的字（框 + 一圈）、时间用时间线秒
    let watermark = AITextRegions.Fixed(text: "Sky Studio", box: CGRect(x: 0.02, y: 0.9, width: 0.06, height: 0.05), coverage: 0.8)
    let band = AITextRegions.Band(box: CGRect(x: 0.3, y: 0.88, width: 0.4, height: 0.09), coverage: 0.6, from: 3, to: 20)
    let report = AITextRegions.Report(band: band, fixed: [watermark], heavy: nil)
    let timelineClip = clip()
    let timeline: (Double) -> Double = { timelineClip.timelineTime(atSource: $0) }
    var payload = AITextRegions.json(report, timeline: timeline)
    AICoverBox.annotate(&payload, report: report, clip: timelineClip, canvas: wide, timeline: timeline)
    let bandCover = payload["subtitle_band"]?["cover"]
    checkEqual(bandCover?["x"]?.doubleValue, 0.5, "the subtitle band's cover is the whole picture width")
    checkEqual(bandCover?["width"]?.doubleValue, 1, "… full width")
    checkEqual(bandCover?["start"]?.doubleValue, 13, "the band's cover starts at the timeline second it first shows (source 3 s + clip start 10 s)")
    checkEqual(bandCover?["duration"]?.doubleValue, 17, "and lasts as long as the band was seen")
    let markCover = payload["fixed_text"]?.arrayValue?.first?["cover"]
    checkEqual(markCover?["start"]?.doubleValue, 10, "a watermark's cover covers the whole clip")
    checkEqual(markCover?["duration"]?.doubleValue, 10, "… for the clip's length")
    check((markCover?["width"]?.doubleValue ?? 0) > 0.06 && (markCover?["width"]?.doubleValue ?? 1) < 0.1, "… with a margin around the box")
    check(payload["cover_hint"]?.stringValue?.contains("set_shape kind=blur") == true, "the hint tells the AI how to use it")
    var bare = AITextRegions.json(AITextRegions.Report(), timeline: { $0 })
    AICoverBox.annotate(&bare, report: AITextRegions.Report(), clip: timelineClip, canvas: wide, timeline: { $0 })
    check(bare["cover_hint"] == nil, "nothing found → no cover suggestion")
}
