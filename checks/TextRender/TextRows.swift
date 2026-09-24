import CoreGraphics
import Foundation

// 第 16c 组：文字行的叠放序（`TextOverlay.row`，2026-09-24）—— 行号大的压在上面，**预览和成片
// 同一份序**：数组里 B 排在 A 前面，但 A 在第 0 行、B 在第 1 行，成片里 B 必须贴在 A 之后。
// 合同见 docs/architecture/text-overlays.md「时间线上的行」。

func checkTextRowsStacking(dark: URL) async {
    var state = baseState(dark, seconds: 6)
    var a = whiteTitle(start: 0, duration: 6, text: "AAAA")
    a.row = 0
    a.centerY = 0.3
    var b = whiteTitle(start: 0, duration: 6, text: "BBBB")
    b.row = 1
    b.centerY = 0.7
    state.textOverlays = [b, a]
    checkEqual(state.textOverlaysInStackingOrder.map(\.text), ["AAAA", "BBBB"],
               "叠放序按行号：第 0 行先画、第 1 行后画（和数组顺序无关）")

    guard let aFrame = TextRenderer.render(
              a, canvas: canvas, state: TextAnimator.state(for: a, at: 1, canvas: canvas, frameRate: .fps30)),
          let bFrame = TextRenderer.render(
              b, canvas: canvas, state: TextAnimator.state(for: b, at: 1, canvas: canvas, frameRate: .fps30))
    else {
        check(false, "两段字都该渲得出来")
        return
    }
    guard let graph = await filterGraph(state, name: "textrows") else { return }
    let aOverlay = graph.range(of: "overlay=x=\(Int(aFrame.origin.x)):y=\(Int(aFrame.origin.y))")
    let bOverlay = graph.range(of: "overlay=x=\(Int(bFrame.origin.x)):y=\(Int(bFrame.origin.y))")
    check(aOverlay != nil, "滤镜图里没有 A 的 overlay")
    check(bOverlay != nil, "滤镜图里没有 B 的 overlay")
    if let aOverlay, let bOverlay {
        check(aOverlay.lowerBound < bOverlay.lowerBound,
              "第 1 行的 B 必须贴在第 0 行的 A 之后（压在上面），哪怕数组里 B 在前")
    }
}
