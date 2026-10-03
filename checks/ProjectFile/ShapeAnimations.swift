import CoreGraphics
import Foundation
import SrtFlowCore

// 第 44 组：形状的入场 / 出场动画（2026-10-03，南极工程：形状只能突然出现、突然消失）。
// 一、存盘：`animation` 按需写键（没设动画的不落）、设了就是 v31 数据（只认 v30 的旧版读进来当没有，存回去就抹掉了）、
//     往返不丢、不认识的效果名读作 none、缺时长读作 0.6。
// 二、求值（`ShapeAnimator`，预览、导出、AI 的「看」同一份）：三段式、和文字动画同一套曲线、入场 + 出场超长按比例收、盖一块不动。
// 三、画什么（`ShapeOutline.drawing`，预览和导出照同一条路径上色）：笔顺、截到哪、线头在长度以内、实心的按同一个方向露出来、
//     擦除从左往右、缩放绕中心只缩几何。像素级的预览 = 成片在 scripts/check-shape-render.sh。

private func near(_ actual: Double, _ expected: Double, _ message: String, tolerance: Double = 1e-6, line: Int = #line) {
    check(abs(actual - expected) <= tolerance, "\(message)：得到 \(actual)，应为 \(expected)", line: line)
}

private func near(_ rect: CGRect, _ expected: CGRect, _ message: String, line: Int = #line) {
    let ok = abs(rect.minX - expected.minX) < 0.01 && abs(rect.minY - expected.minY) < 0.01
        && abs(rect.width - expected.width) < 0.01 && abs(rect.height - expected.height) < 0.01
    check(ok, "\(message)：得到 \(rect)，应为 \(expected)", line: line)
}

func checkShapeAnimations(root: URL) throws {
    try checkShapeAnimationFile(root: root)
    checkShapeAnimator()
    checkShapeDrawing()
}

// MARK: 一、存盘

private func checkShapeAnimationFile(root: URL) throws {
    var state = TimelineState()
    let plain = ShapeAnnotation(kind: .rectangle, timelineStart: 0)
    state.shapes = [plain]
    check(!state.requiresFormatVersion31, "没设动画的形状：不是 v31 数据")
    var ring = ShapeAnnotation(kind: .circle, timelineStart: 1, duration: 3, width: 0.3)
    ring.animation = ShapeAnimation(entrance: .draw, exit: .fade, entranceDuration: 0.8, exitDuration: 0.4)
    state.shapes = [plain, ring]
    check(state.requiresFormatVersion31, "有形状设了动画 → v31 判据为真")

    let path = root.appendingPathComponent("shape-animation.srtflowproj")
    try VideoEditProjectIO.save(state, to: path)
    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
    checkEqual(raw?["formatVersion"] as? Int, 31, "带形状动画的工程写 latest（v31）")
    let rawShapes = ((raw?["timeline"] as? [String: Any])?["shapes"] as? [[String: Any]]) ?? []
    check(rawShapes.count == 2 && rawShapes[0]["animation"] == nil, "没设动画的形状不写 animation 键（按需）")
    let rawAnimation = rawShapes.count == 2 ? rawShapes[1]["animation"] as? [String: Any] : nil
    checkEqual(rawAnimation?["entrance"] as? String, "draw", "入场的效果名落盘")
    checkEqual(rawAnimation?["exitDuration"] as? Double, 0.4, "出场时长落盘")
    let back = try VideoEditProjectIO.load(from: path).timeline
    checkEqual(back.shapes.map(\.animation), [ShapeAnimation(), ring.animation], "往返不丢动画")

    // 宽容：不认识的效果名读作 none、缺时长读作 0.6（手改过的文件、以后加的效果被旧一点的版本读到）。
    var edited = raw ?? [:]
    var timeline = edited["timeline"] as? [String: Any] ?? [:]
    var shapes = timeline["shapes"] as? [[String: Any]] ?? []
    if shapes.count == 2 { shapes[1]["animation"] = ["entrance": "spin", "exit": "wipe"] }
    timeline["shapes"] = shapes
    edited["timeline"] = timeline
    let editedPath = root.appendingPathComponent("shape-animation-lenient.srtflowproj")
    try JSONSerialization.data(withJSONObject: edited).write(to: editedPath)
    let lenient = try VideoEditProjectIO.load(from: editedPath).timeline.shapes.last?.animation
    checkEqual(lenient, ShapeAnimation(entrance: .none, exit: .wipe), "不认识的效果读作 none、缺时长读作 0.6")
}

// MARK: 二、求值

private func checkShapeAnimator() {
    var shape = ShapeAnnotation(kind: .line, timelineStart: 10, duration: 4)
    shape.animation = ShapeAnimation(entrance: .fade, exit: .pop, entranceDuration: 1, exitDuration: 1)
    near(ShapeAnimator.state(for: shape, at: 10.5).opacity, TextEasing.easeOutCubic(0.5), "淡入走到一半：easeOutCubic(0.5)")
    near(ShapeAnimator.state(for: shape, at: 10).opacity, 0, "入场第一帧还看不见")
    near(ShapeAnimator.state(for: shape, at: 9.9).opacity, 0, "段开头之前（量化落在前一帧）也看不见")
    checkEqual(ShapeAnimator.state(for: shape, at: 12), ShapeAnimationState.identity, "中间一帧不动")
    let popEnd = ShapeAnimator.state(for: shape, at: 14)
    near(popEnd.scale, ShapeAnimator.popStartScale, "弹性缩放出场的最后：缩回起手的大小")
    near(popEnd.opacity, 0, "弹性缩放出场的最后：看不见")
    let popHalf = ShapeAnimator.state(for: shape, at: 13.5)
    near(popHalf.scale, ShapeAnimator.popStartScale + (1 - ShapeAnimator.popStartScale) * TextEasing.easeInCubic(0.5), "出场一半：easeIn 收走")

    shape.animation = ShapeAnimation(entrance: .pop, exit: .wipe, entranceDuration: 1, exitDuration: 1)
    check(ShapeAnimator.state(for: shape, at: 10.6).scale > 1.0001, "弹性缩放入场冲过头（> 1）再回弹")
    near(ShapeAnimator.state(for: shape, at: 13.75).wipe ?? -1, 0.25, "擦除出场倒着走、线性：还剩四分之一")

    shape.animation = ShapeAnimation(entrance: .draw, exit: .none, entranceDuration: 2, exitDuration: 1)
    near(ShapeAnimator.state(for: shape, at: 10.5).drawn ?? -1, 0.25, "画出来：线性，0.5 / 2 秒 = 四分之一")
    checkEqual(ShapeAnimator.state(for: shape, at: 13.9), ShapeAnimationState.identity, "没设出场：到最后都不动")

    // 入场 3 + 出场 3 撞上 4 秒的形状：和文字、声音同一个 FadeWindow，按比例各收到 2 秒。
    shape.animation = ShapeAnimation(entrance: .draw, exit: .draw, entranceDuration: 3, exitDuration: 3)
    near(ShapeAnimator.state(for: shape, at: 11).drawn ?? -1, 0.5, "超长按比例收：入场 2 秒走到一半")
    near(ShapeAnimator.state(for: shape, at: 13).drawn ?? -1, 0.5, "超长按比例收：出场 2 秒走到一半")

    var cover = ShapeAnnotation(kind: .blur, timelineStart: 0, duration: 2)
    cover.animation = ShapeAnimation(entrance: .fade)
    checkEqual(ShapeAnimator.state(for: cover, at: 0.1), ShapeAnimationState.identity, "盖一块没有动画")
}

// MARK: 三、画什么

private func checkShapeDrawing() {
    let stroke = 10.0
    let line = ShapeAnnotation(kind: .line, timelineStart: 0, width: 0.5)
    let whole = ShapeOutline.drawing(for: line, size: CGSize(width: 200, height: 0), strokeWidth: stroke)
    near(whole.path.boundingBoxOfPath, CGRect(x: 5, y: 0, width: 190, height: 0), "线：圆线头在长度以内（两端各收半个线宽）")
    checkEqual(whole.lineCap, .round, "线是圆线头")
    let half = ShapeOutline.drawing(for: line, size: CGSize(width: 200, height: 0), strokeWidth: stroke, state: ShapeAnimationState(drawn: 0.5))
    near(half.path.boundingBoxOfPath, CGRect(x: 5, y: 0, width: 95, height: 0), "线画一半：从左端起")
    check(ShapeOutline.drawing(for: line, size: CGSize(width: 200, height: 0), strokeWidth: stroke,
                               state: ShapeAnimationState(drawn: 0)).path.isEmpty, "画了 0：空路径（圆线头的零长线段会画出一个点）")
    var down = line
    down.rotationDegrees = 90
    let downHalf = ShapeOutline.drawing(for: down, size: CGSize(width: 200, height: 0), strokeWidth: stroke, state: ShapeAnimationState(drawn: 0.5))
    near(downHalf.path.boundingBoxOfPath, CGRect(x: 100, y: -95, width: 0, height: 95), "转了 90° 的线：从上端起往下画")

    let square = ShapeAnnotation(kind: .square, timelineStart: 0, width: 0.2)
    let size = CGSize(width: 100, height: 100)
    let squareQuarter = ShapeOutline.drawing(for: square, size: size, strokeWidth: stroke, state: ShapeAnimationState(drawn: 0.25))
    near(squareQuarter.path.boundingBoxOfPath, CGRect(x: 5, y: 5, width: 90, height: 0), "正方形画四分之一：上边，从左上角起")
    checkEqual(squareQuarter.lineCap, .butt, "长方形 / 正方形是平线头")
    let squareMore = ShapeOutline.drawing(for: square, size: size, strokeWidth: stroke, state: ShapeAnimationState(drawn: 0.375))
    near(squareMore.path.boundingBoxOfPath, CGRect(x: 5, y: 5, width: 90, height: 45), "再往下：顺时针转到右边")
    let popped = ShapeOutline.drawing(for: square, size: size, strokeWidth: stroke, state: ShapeAnimationState(scale: 0.5))
    near(popped.path.boundingBoxOfPath, CGRect(x: 27.5, y: 27.5, width: 45, height: 45), "缩放绕框的中心、只缩几何")

    let circle = ShapeAnnotation(kind: .circle, timelineStart: 0, width: 0.2)
    let circleQuarter = ShapeOutline.drawing(for: circle, size: size, strokeWidth: stroke, state: ShapeAnimationState(drawn: 0.25))
    near(circleQuarter.path.boundingBoxOfPath, CGRect(x: 50, y: 5, width: 45, height: 45), "圆画四分之一：12 点到 3 点（顺时针）")
    var arc = ShapeAnnotation(kind: .arc, timelineStart: 0, width: 0.2)
    arc.arcSweep = 180
    let arcHalf = ShapeOutline.drawing(for: arc, size: size, strokeWidth: stroke, state: ShapeAnimationState(drawn: 0.5))
    near(arcHalf.path.boundingBoxOfPath, CGRect(x: 50, y: 5, width: 45, height: 45), "圆弧画一半：从它的起点顺时针扫一半")

    var disc = circle
    disc.isFilled = true
    let discQuarter = ShapeOutline.drawing(for: disc, size: size, strokeWidth: stroke, state: ShapeAnimationState(drawn: 0.25))
    near(discQuarter.path.boundingBoxOfPath, CGRect(x: 0, y: 0, width: 100, height: 100), "实心圆画出来：路径是整个圆，不截")
    check(discQuarter.reveal?.contains(CGPoint(x: 75, y: 25)) == true, "实心圆画四分之一：右上那一块露出来")
    check(discQuarter.reveal?.contains(CGPoint(x: 25, y: 75)) == false, "实心圆画四分之一：左下还没露")
    var block = square
    block.isFilled = true
    let blockHalf = ShapeOutline.drawing(for: block, size: size, strokeWidth: stroke, state: ShapeAnimationState(drawn: 0.5))
    check(blockHalf.reveal?.contains(CGPoint(x: 20, y: 50)) == true && blockHalf.reveal?.contains(CGPoint(x: 80, y: 50)) == false,
          "实心正方形画出来：从左往右露")

    let rectangle = ShapeAnnotation(kind: .rectangle, timelineStart: 0, width: 0.3, height: 0.2)
    let wiped = ShapeOutline.drawing(for: rectangle, size: CGSize(width: 100, height: 50), strokeWidth: stroke,
                                     state: ShapeAnimationState(wipe: 0.3))
    check(wiped.reveal?.contains(CGPoint(x: 25, y: 25)) == true && wiped.reveal?.contains(CGPoint(x: 40, y: 25)) == false,
          "擦除三成：可见框左边三成露出来")
    near(wiped.path.boundingBoxOfPath, CGRect(x: 5, y: 5, width: 90, height: 40), "擦除不截路径")
    let faded = ShapeOutline.drawing(for: rectangle, size: CGSize(width: 100, height: 50), strokeWidth: stroke,
                                     state: ShapeAnimationState(opacity: 0.4))
    near(faded.opacity, 0.4, "不透明度原样交给上色的一方")

    // 还什么都没露出来：给空路径、不给裁剪区 —— CoreGraphics 拿空路径 clip 等于没裁，导出会把整块画出来。
    for (name, shape, state) in [("擦了 0", rectangle, ShapeAnimationState(wipe: 0)),
                                 ("实心圆画了 0", disc, ShapeAnimationState(drawn: 0)),
                                 ("实心正方形画了 0", block, ShapeAnimationState(drawn: 0))] {
        let nothing = ShapeOutline.drawing(for: shape, size: size, strokeWidth: stroke, state: state)
        check(nothing.path.isEmpty && nothing.reveal == nil, "\(name)：空路径、不裁（不能靠裁到一块空区域）")
    }
    check(faded.reveal == nil, "没在擦除也没在画：不裁")
}
