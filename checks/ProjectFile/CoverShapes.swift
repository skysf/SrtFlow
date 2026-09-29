import Foundation
import SrtFlowCore

// 第 38 组：盖一块（模糊 / 马赛克，2026-09-29，MCP 方案第 56 条）。
// `ShapeKind.blur / .mosaic` 和 `ShapeAnnotation.coverAmount` 是 v26 数据：按需写键（只有盖一块落 coverAmount）、缺键读作这个种类的默认力度、
// 判据和写键同源；不认识的种类宽容回落成长方形（旧版就是这么读它的，所以要抬版本）。盖一块不进 `renderedShapes`、不算总长、
// 藏起来的不进 `renderedCovers`。编法见 scripts/check-project-file.sh。

func checkCoverShapes(root: URL) throws {
    let outline = ShapeAnnotation(kind: .rectangle, timelineStart: 0)
    var blur = ShapeAnnotation(kind: .blur, timelineStart: 1, duration: 2, centerX: 0.3, centerY: 0.9, width: 0.6, height: 0.12, coverAmount: 36)
    var mosaic = ShapeAnnotation(kind: .mosaic, timelineStart: 0, duration: 5)
    check(blur.kind.isCover && mosaic.kind.isCover && !outline.kind.isCover, "isCover：模糊和马赛克是盖一块，长方形不是")
    check(mosaic.coverAmount == ShapeKind.mosaic.defaultCoverAmount, "不指定力度就是这个种类的默认")
    check(blur.frame(in: CGSize(width: 1000, height: 500)) == CGRect(x: 0, y: 420, width: 600, height: 60), "盖一块的框和长方形同一套几何")

    var state = TimelineState()
    state.shapes = [outline]
    check(!state.requiresFormatVersion26, "只有画出来的形状：不是 v26 数据（按需）")
    let path = root.appendingPathComponent("cover-shapes.srtflowproj")
    try VideoEditProjectIO.save(state, to: path)
    let cleanRaw = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
    let cleanShapes = ((cleanRaw?["timeline"] as? [String: Any])?["shapes"] as? [[String: Any]]) ?? []
    check(!cleanShapes.isEmpty && cleanShapes.allSatisfy { $0["coverAmount"] == nil }, "别的形状不写 coverAmount 键（与判据同源）")

    state.shapes = [outline, blur, mosaic]
    check(state.requiresFormatVersion26, "有盖一块 → v26 判据为真")
    try VideoEditProjectIO.save(state, to: path)
    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
    checkEqual(raw?["formatVersion"] as? Int, 26, "带盖一块的工程写 latest（v26）")
    let back = try VideoEditProjectIO.load(from: path).timeline
    checkEqual(back.shapes.map(\.kind), [.rectangle, .blur, .mosaic], "往返不丢种类")
    checkEqual(back.shapes[1].coverAmount, 36, "往返不丢力度")
    checkEqual(back.shapes[1].centerY, 0.9, "往返不丢位置")

    // 缺键读作默认力度（写盘时没有力度的 mosaic 也一样）：把 coverAmount 键从文件里抠掉再读。
    var stripped = raw ?? [:]
    if var timeline = stripped["timeline"] as? [String: Any], var shapes = timeline["shapes"] as? [[String: Any]] {
        for index in shapes.indices { shapes[index].removeValue(forKey: "coverAmount") }
        timeline["shapes"] = shapes
        stripped["timeline"] = timeline
    }
    let strippedPath = root.appendingPathComponent("cover-shapes-stripped.srtflowproj")
    try JSONSerialization.data(withJSONObject: stripped).write(to: strippedPath)
    let strippedShapes = try VideoEditProjectIO.load(from: strippedPath).timeline.shapes
    checkEqual(strippedShapes[1].coverAmount, ShapeKind.blur.defaultCoverAmount, "缺键读作模糊的默认力度")
    checkEqual(strippedShapes[2].coverAmount, ShapeKind.mosaic.defaultCoverAmount, "缺键读作马赛克的默认力度")

    // 清单：藏起来的不进 renderedCovers；盖一块不进 renderedShapes、不算总长；只剩盖一块也不是「空工程」。
    mosaic.isHidden = true
    blur.timelineStart = 0
    blur.duration = 50
    state.shapes = [outline, blur, mosaic]
    checkEqual(state.renderedCovers.map(\.id), [blur.id], "藏起来的盖一块不进成片")
    checkEqual(state.renderedShapes.map(\.id), [outline.id], "盖一块不进 renderedShapes")
    check(state.duration < 10, "盖一块不算总长（50 秒的盖一块不把工程撑到 50 秒）")
    state.shapes = [blur]
    check(!state.isEmpty, "只有一块盖一块的工程也是有内容的（不能被当成空工程丢掉）")
}
