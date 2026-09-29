import CoreGraphics
import Foundation
import SrtFlowMCPKit

// edit_clip 的画面：铺满 / 完整显示 / 按位置大小摆（AIFrameFit）、参数组合（AIFramingRequest）、
// 摆放「约等于默认就存 nil」（PlacementDefault）、改一段时换上裁切和摆放（AIClipEdit）。
// 编法见 scripts/check-mcp.sh；模型的合同见 docs/architecture/preview-free-transform.md。

func runFramingChecks() {
    checkFillMapsWindowOntoWholeCanvas()
    checkFillAimsAtFocus()
    checkFitAndPlace()
    checkPlacementDefault()
    checkFramingRequestRules()
    checkFramingEdits()
}

/// 一段画面：`width`×`height` 的视频。
private func pictureClip(_ width: Double, _ height: Double) -> EditClip {
    let info = MediaInfo(
        duration: 30, displaySize: CGSize(width: width, height: height), frameRate: 30,
        videoCodec: "h264", audioCodec: "aac", hasAudio: true, audioCanCopyToMP4: true, fileBytes: 1
    )
    return EditClip(sourceURL: media, sourceDuration: 10, info: info)
}

private func framed(_ clip: EditClip, _ framing: AIFrameFit.Framing) -> EditClip {
    var copy = clip
    copy.crop = framing.crop
    copy.placement = framing.placement
    return copy
}

/// 源画面上归一化的一点落在画布的哪儿 —— **照合同自己算一遍**（裁切 → 缩放进摆放框），不借被测代码，
/// 免得两边一起错。
private func canvasPoint(_ source: CGPoint, of clip: EditClip, canvas: CGSize) -> CGPoint {
    let crop = clip.crop ?? ClipCrop()
    let keptX = crop.leading, keptW = 1 - crop.leading - crop.trailing
    let keptY = crop.top, keptH = 1 - crop.top - crop.bottom
    let frame = clip.resolvedPlacement(canvas: canvas).frame(in: canvas)
    return CGPoint(
        x: frame.minX + (source.x - keptX) / keptW * frame.width,
        y: frame.minY + (source.y - keptY) / keptH * frame.height
    )
}

private func close(_ a: CGPoint, _ b: CGPoint, within pixels: Double = 0.5) -> Bool {
    abs(a.x - b.x) <= pixels && abs(a.y - b.y) <= pixels
}

/// 铺满：窗的四个角正好落在画布的四个角上，裁切每边不超过 0.45，画面盖满 —— 各种横竖比例、各种焦点都要成立
/// （窗贴边、超宽画面转竖屏这类只靠裁切表达不了的也在里面）。
private func checkFillMapsWindowOntoWholeCanvas() {
    let displays: [(Double, Double)] = [(1920, 1080), (1080, 1920), (1440, 1080), (3840, 1600), (1080, 1080), (496, 864)]
    let canvases = [CGSize(width: 1080, height: 1920), CGSize(width: 1920, height: 1080),
                    CGSize(width: 1080, height: 1080), CGSize(width: 1080, height: 1440)]
    let stops = [0.0, 0.1, 0.25, 0.5, 0.75, 0.9, 1.0]
    var cases = 0, wrong = 0, overCrop = 0, notFilled = 0
    for (width, height) in displays {
        let clip = pictureClip(width, height)
        for canvas in canvases {
            for fx in stops {
                for fy in stops {
                    cases += 1
                    let focus = CGPoint(x: fx, y: fy)
                    guard let framing = AIFrameFit.fill(clip, canvas: canvas, active: AIFrameFit.wholePicture, focus: focus) else {
                        wrong += 1
                        continue
                    }
                    let result = framed(clip, framing)
                    let window = AIFrameFit.fillWindow(
                        display: CGSize(width: width, height: height), canvas: canvas,
                        active: AIFrameFit.wholePicture, focus: focus
                    )
                    let topLeft = canvasPoint(CGPoint(x: window.minX, y: window.minY), of: result, canvas: canvas)
                    let bottomRight = canvasPoint(CGPoint(x: window.maxX, y: window.maxY), of: result, canvas: canvas)
                    if !close(topLeft, .zero) || !close(bottomRight, CGPoint(x: canvas.width, y: canvas.height)) {
                        wrong += 1
                        if wrong <= 3 { print("  fill \(width)x\(height) → \(canvas) focus \(focus): window lands at \(topLeft)…\(bottomRight)") }
                    }
                    let crop = result.crop ?? ClipCrop()
                    if max(crop.leading, crop.trailing, crop.top, crop.bottom) > 0.45 + 1e-9 { overCrop += 1 }
                    if !AIFrameFit.describe(result, canvas: canvas).fillsFrame { notFilled += 1 }
                }
            }
        }
    }
    checkEqual(wrong, 0, "fill maps its window exactly onto the whole canvas (\(cases) cases)")
    checkEqual(overCrop, 0, "fill never crops more than 0.45 from an edge")
    checkEqual(notFilled, 0, "a filled clip reports fills_frame")
}

private func checkFillAimsAtFocus() {
    let wide = pictureClip(1920, 1080)
    let tall = CGSize(width: 1080, height: 1920)
    // 焦点在正中：裁切一次收得下（左右各 0.342），摆放回默认（nil），检查器里看到的只是一个裁切。
    let centred = AIFrameFit.fill(wide, canvas: tall, active: AIFrameFit.wholePicture, focus: CGPoint(x: 0.5, y: 0.5))
    check(centred?.placement == nil, "a centred 16:9 → 9:16 fill is a plain crop (placement stays default)")
    checkEqual(((centred?.crop?.leading ?? 0) * 1000).rounded(), 342, "centred fill crops 0.342 from the left")
    // 焦点偏左（人站在画面左三分之一）：只靠裁切做不到，交给摆放框 —— 焦点正好落在画布正中。
    let aimed = AIFrameFit.fill(wide, canvas: tall, active: AIFrameFit.wholePicture, focus: CGPoint(x: 0.25, y: 0.5))!
    let focusOnCanvas = canvasPoint(CGPoint(x: 0.25, y: 0.5), of: framed(wide, aimed), canvas: tall)
    check(close(focusOnCanvas, CGPoint(x: 540, y: 960)), "fill puts the focus in the middle of the frame (got \(focusOnCanvas))")
    check(aimed.placement != nil, "an off-centre 16:9 → 9:16 fill needs a placement besides the crop")
    // 焦点贴着左边：窗不许出画面，画面的左边缘贴住画布左边。
    let edge = framed(wide, AIFrameFit.fill(wide, canvas: tall, active: AIFrameFit.wholePicture, focus: CGPoint(x: 0, y: 0.5))!)
    check(close(canvasPoint(CGPoint(x: 0, y: 0.5), of: edge, canvas: tall), CGPoint(x: 0, y: 960)),
          "a focus at the picture's edge keeps the window inside the picture")
    // 可用区域（去掉黑边剩下的）：窗只在它里面取。
    let active = CGRect(x: 0, y: 0.12, width: 1, height: 0.76)
    let barred = AIFrameFit.fillWindow(display: CGSize(width: 1920, height: 1080), canvas: CGSize(width: 1920, height: 1080),
                                       active: active, focus: CGPoint(x: 0.5, y: 0.5))
    check(barred.minY >= 0.12 - 1e-9 && barred.maxY <= 0.88 + 1e-9, "the fill window stays inside the usable area (\(barred))")
}

private func checkFitAndPlace() {
    let wide = pictureClip(1920, 1080)
    let tall = CGSize(width: 1080, height: 1920)
    // 完整显示：裁切就是可用区域，摆放回默认；16:9 放进 9:16 盖不满。
    let fit = AIFrameFit.fit(active: CGRect(x: 0.1, y: 0, width: 0.8, height: 1))
    checkEqual(fit.placement, nil, "fit puts the picture back to the default layout")
    checkEqual(((fit.crop?.trailing ?? 0) * 100).rounded(), 10, "fit keeps only the usable area")
    check(!AIFrameFit.describe(framed(wide, fit), canvas: tall).fillsFrame, "a 16:9 picture fitted into 9:16 does not fill the frame")
    checkEqual(AIFrameFit.fit(active: AIFrameFit.wholePicture), AIFrameFit.Framing(crop: nil, placement: nil),
               "fit of the whole picture is the plain default")

    // 按位置和大小：右上角、三成大。
    let corner = AIFrameFit.place(wide, canvas: tall, crop: nil, x: 0.8, y: 0.2, scale: 0.3)
    let placed = framed(wide, corner)
    let summary = AIFrameFit.describe(placed, canvas: tall)
    check(abs(summary.x - 0.8) < 1e-9 && abs(summary.y - 0.2) < 1e-9, "place puts the centre where asked")
    check(abs(summary.scale - 0.3) < 1e-9 && !summary.stretched, "place scales the default size evenly (got \(summary.scale))")
    // 只改裁切：中心和大小不动，宽高比跟着裁剩的画面走（不拉变形）。
    let recropped = framed(placed, AIFrameFit.place(placed, canvas: tall, crop: ClipCrop(leading: 0.2, trailing: 0.2),
                                                    x: nil, y: nil, scale: nil))
    let after = AIFrameFit.describe(recropped, canvas: tall)
    check(abs(after.x - 0.8) < 1e-9 && abs(after.scale - 0.3) < 1e-9 && !after.stretched,
          "changing only the crop keeps position and size and does not stretch the picture")
    // 回到正中、大小 1：就是默认布局，存 nil。
    checkEqual(AIFrameFit.place(placed, canvas: tall, crop: nil, x: 0.5, y: 0.5, scale: 1).placement, nil,
               "placing at the centre with scale 1 is the default layout")

    // 放大的画面，中心出到 0–1 外边才够得到边（2026-09-29 验收：放大的幻灯片只看得到中间）：16:9 放进 9:16 放大 3.16 倍
    // 正好盖满高度，x = 1 − 3.16 / 2 让画面的右边落在画布的右边。
    let big = 1920.0 / 1080 * 1920 / 1080          // 盖满高度的倍数
    let rightEdge = framed(wide, AIFrameFit.place(wide, canvas: tall, crop: nil, x: 1 - big / 2, y: 0.5, scale: big))
    let corner1 = canvasPoint(CGPoint(x: 1, y: 1), of: rightEdge, canvas: tall)
    check(abs(corner1.x - tall.width) < 0.5 && abs(corner1.y - tall.height) < 0.5,
          "a centre below 0 brings the right edge of an enlarged picture to the frame's right edge (got \(corner1))")
    let far = AIFrameFit.describe(framed(wide, AIFrameFit.place(wide, canvas: tall, crop: nil, x: -9, y: 9, scale: 2)), canvas: tall)
    check(far.x == AIFrameFit.centerRange.lowerBound && far.y == AIFrameFit.centerRange.upperBound,
          "the centre stops at -2…3 (got \(far.x), \(far.y))")
    // 工具说明里写的范围 = App 认的（edit_clip 的 x / y、set_keyframes 的位置）。
    for tool in ["edit_clip", "set_keyframes"] {
        let definition = MCPToolName.listJSON.arrayValue?.first { $0["name"]?.stringValue == tool }
        var ranges: [(Double?, Double?)] = []
        func walk(_ value: JSONValue) {
            if case .object(let object) = value {
                if case .object(let properties)? = object["properties"] {
                    for key in ["x", "y"] {
                        if let schema = properties[key] { ranges.append((schema["minimum"]?.doubleValue, schema["maximum"]?.doubleValue)) }
                    }
                }
                object.values.forEach(walk)
            } else if case .array(let items) = value {
                items.forEach(walk)
            }
        }
        definition.map(walk)
        check(!ranges.isEmpty && ranges.allSatisfy {
            $0.0 == AIFrameFit.centerRange.lowerBound && $0.1 == AIFrameFit.centerRange.upperBound
        }, "\(tool): x / y in the tool list allow \(AIFrameFit.centerRange) like the app (got \(ranges))")
    }
}

private func checkPlacementDefault() {
    let canvas = CGSize(width: 1920, height: 1080)
    let fallback = ClipPlacement(centerX: 0.5, centerY: 0.5, width: 1, height: 1)
    let nearly = ClipPlacement(centerX: 0.5 + 0.4 / 1920, centerY: 0.5, width: 1, height: 1)
    let off = ClipPlacement(centerX: 0.5 + 0.6 / 1920, centerY: 0.5, width: 1, height: 1)
    checkEqual(PlacementDefault.normalized(nearly, fallback: fallback, canvas: canvas), nil,
               "a placement within half a pixel of the default is stored as the default")
    checkEqual(PlacementDefault.normalized(off, fallback: fallback, canvas: canvas), off,
               "a placement more than half a pixel off is kept")
}

private func checkFramingRequestRules() {
    checkThrows("fit and x/y/scale cannot be combined") { _ = try AIFramingRequest(args(["fit": "fill", "x": 0.5])) }
    checkThrows("focus needs fit=fill") { _ = try AIFramingRequest(args(["focus_x": 0.3])) }
    checkThrows("focus does not go with fit=fit") { _ = try AIFramingRequest(args(["fit": "fit", "focus_x": 0.3])) }
    checkThrows("crop must be an object") { _ = try AIFramingRequest(args(["crop": 5])) }
    checkThrows("scale has a range") { _ = try AIFramingRequest(args(["scale": 10])) }
    let parsed = try? AIFramingRequest(args(["crop": ["left": 0.1, "right": 0.2], "fit": "FILL", "focus_x": 0.3]))
    checkEqual(parsed?.fit, .fill, "fit is read case-insensitively")
    checkEqual(parsed?.crop, ClipCrop(leading: 0.1, trailing: 0.2), "crop edges are read as left/right/top/bottom")
    checkEqual(parsed?.focusPoint, CGPoint(x: 0.3, y: 0.5), "a missing focus coordinate is the centre")
    checkEqual((try? AIFramingRequest(args(["start": 2])))?.touchesPicture, false, "a move does not touch the picture")
}

private func checkFramingEdits() {
    let still = 20.0
    let picture = videoClip(0, 5)
    var state = TimelineState()
    state.mainClips = [picture]
    var change = AIClipChange()
    change.framing = AIFrameFit.Framing(crop: ClipCrop(leading: 0.2, trailing: 0.2),
                                        placement: ClipPlacement(centerX: 0.4, centerY: 0.5, width: 1.2, height: 1))
    let edited = (try? AIClipEdit.apply(change, to: picture.id, linkage: false, stillDuration: still, in: state))?
        .clip(with: picture.id)
    checkEqual(edited?.crop, ClipCrop(leading: 0.2, trailing: 0.2), "edit_clip stores the crop")
    checkEqual(edited?.placement?.centerX, 0.4, "edit_clip stores the placement")

    let sound = audioClip(0, 5)
    var withAudio = TimelineState()
    withAudio.audioTracks = [EditLane(clips: [sound])]
    checkThrows("an audio clip has no picture to place") {
        _ = try AIClipEdit.apply(change, to: sound.id, linkage: false, stillDuration: still, in: withAudio)
    }

    var animated = picture
    var animation = ClipAnimation()
    animation.centerX.set(0.3, atSourceTime: 0, tolerance: 0.01)
    animated.animation = animation
    var keyed = TimelineState()
    keyed.mainClips = [animated]
    checkThrows("a clip whose position is keyframed is not placed statically") {
        _ = try AIClipEdit.apply(change, to: animated.id, linkage: false, stillDuration: still, in: keyed)
    }
}
