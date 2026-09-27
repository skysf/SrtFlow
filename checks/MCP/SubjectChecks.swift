import CoreGraphics
import Foundation

// 铺满时对准谁（AISubjectFocus）：人脸优先、几张脸放得下对准合起来的中心、放不下对准最大的、没脸看人再看显眼的
// 东西、几帧取中位数不被一两帧带偏、走动大了要说；以及 Vision 的框换成左上原点 —— 真画一张图（黑底左上角一块白）
// 让 Vision 认，认出来的必须在左上（上下弄反的话窗会对到画面下半边去）。编法见 scripts/check-mcp.sh。

func runSubjectChecks() async {
    checkFocusPerFrame()
    checkFocusAcrossFrames()
    checkTopLeftConversion()
    await checkVisionOrientation()
}

/// 16:9 转 9:16 时窗的大小（源宽的 0.316、整个高）。
private let tallWindow = CGSize(width: 0.316, height: 1)

/// 浮点算出来的中心（0.2 + 0.05 之类）不一定逐位等于字面量：差不到十亿分之一就算对。
private func near(_ point: CGPoint?, _ expected: CGPoint) -> Bool {
    guard let point else { return false }
    return abs(point.x - expected.x) < 1e-9 && abs(point.y - expected.y) < 1e-9
}

private func checkFocusPerFrame() {
    let face = CGRect(x: 0.2, y: 0.3, width: 0.1, height: 0.15)
    let one = AISubjectFocus.focus(in: .init(faces: [face], people: [CGRect(x: 0.6, y: 0.2, width: 0.2, height: 0.6)]),
                                   window: tallWindow)
    checkEqual(one?.kind, .face, "a face wins over a person")
    check(near(one?.point, CGPoint(x: 0.25, y: 0.375)), "one face: aim at its centre (got \(String(describing: one?.point)))")

    let pair = AISubjectFocus.focus(in: .init(faces: [CGRect(x: 0.2, y: 0.3, width: 0.05, height: 0.1),
                                                      CGRect(x: 0.35, y: 0.3, width: 0.05, height: 0.1)]),
                                    window: tallWindow)
    check(abs((pair?.point.x ?? 0) - 0.3) < 1e-9, "two faces that fit in the window: aim between them")

    let apart = AISubjectFocus.focus(in: .init(faces: [CGRect(x: 0.05, y: 0.3, width: 0.05, height: 0.1),
                                                       CGRect(x: 0.8, y: 0.2, width: 0.1, height: 0.2)]),
                                     window: tallWindow)
    check(abs((apart?.point.x ?? 0) - 0.85) < 1e-9, "two faces too far apart for the window: aim at the bigger one")

    let person = AISubjectFocus.focus(in: .init(people: [CGRect(x: 0.6, y: 0.2, width: 0.2, height: 0.6)]), window: tallWindow)
    checkEqual(person?.kind, .person, "no face: aim at the person")
    let thing = AISubjectFocus.focus(in: .init(salient: [CGRect(x: 0.7, y: 0.4, width: 0.2, height: 0.2)]), window: tallWindow)
    checkEqual(thing?.kind, .salient, "no face or person: aim at what stands out")
    check(near(thing?.point, CGPoint(x: 0.8, y: 0.5)), "the salient area's centre")
    check(AISubjectFocus.focus(in: .init(), window: tallWindow) == nil, "nothing recognised: no aim for this frame")
}

private func checkFocusAcrossFrames() {
    func faceAt(_ x: Double) -> AISubjectFocus.FrameFindings {
        .init(faces: [CGRect(x: x - 0.05, y: 0.3, width: 0.1, height: 0.1)])
    }
    // 四帧在左边、一帧认错跑到右边：中位数不被带偏。
    let steady = AISubjectFocus.combine([faceAt(0.2), faceAt(0.22), .init(), faceAt(0.21), faceAt(0.23)], window: tallWindow)
    check(abs((steady?.point.x ?? 0) - 0.215) < 1e-9, "several frames: the median of the aims (got \(String(describing: steady?.point)))")
    checkEqual(steady?.frames, 4, "frames with nothing recognised do not count")
    checkEqual(steady.map { AISubjectFocus.movesTooMuch($0, window: tallWindow) }, false, "a steady subject does not move too much")

    let wandering = AISubjectFocus.combine([faceAt(0.2), faceAt(0.21), faceAt(0.8)], window: tallWindow)
    checkEqual(wandering.map { AISubjectFocus.movesTooMuch($0, window: tallWindow) }, true,
               "a subject that crosses the frame is reported as moving too much")
    check(AISubjectFocus.combine([.init(), .init()], window: tallWindow) == nil, "nothing recognised in any frame: no aim")

    let mixed = AISubjectFocus.combine(
        [faceAt(0.3), .init(salient: [CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2)]),
         .init(salient: [CGRect(x: 0.25, y: 0.2, width: 0.2, height: 0.2)])],
        window: tallWindow
    )
    checkEqual(mixed?.kind, .salient, "the kind is the one seen in most frames")
}

private func checkTopLeftConversion() {
    // Vision：左下原点，y 0.7 起、高 0.2 = 离顶上 0.1。
    let turned = AIVision.topLeft(CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.2))
    check(near(turned.origin, CGPoint(x: 0.1, y: 0.1)) && abs(turned.height - 0.2) < 1e-9,
          "Vision boxes are turned into top-left boxes (got \(turned))")
}

/// 真画一张：黑底，**左上角**一块亮色方块。Vision 认出来的显眼区域必须落在左上。
private func checkVisionOrientation() async {
    let width = 640, height = 360
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        check(false, "could not make the Vision test image")
        return
    }
    context.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 1, green: 0.85, blue: 0.2, alpha: 1))
    // CG 原点在左下：y 220…320 是画面的上半边。
    context.fillEllipse(in: CGRect(x: 60, y: 220, width: 110, height: 100))
    guard let image = context.makeImage() else {
        check(false, "could not make the Vision test image")
        return
    }
    let found = await AIVision.analyze(image, .subject).subject.salient
    check(!found.isEmpty, "Vision finds the bright shape on a dark frame (got nothing)")
    if let box = found.first {
        check(box.midX < 0.5 && box.midY < 0.5, "Vision's box is turned so the top-left shape reads as top-left (got \(box))")
    }
}
