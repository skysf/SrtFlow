import AppKit

// MARK: - 冒烟驱动：时间线上的缩放
//
// 管什么：`zoom` 这一步 —— 按捏合处理器同样的调用（`TimelineZoom.pointerAnchor` / `verticalAnchor` 起手
// 定锚点，再逐拍 `horizontal` / `vertical`）缩放，前后各量一次指针底下是第几秒、哪一行的第几成，写进日志。
// 真捏合公开 API 造不出来、合成的 Ctrl + 滚轮又绕不过本地事件监视器（驱动把滚轮直接交给视图），
// 所以这里从捏合处理器的下一层进：事件路由那一截（magnify → 监视器）没变过，变的是锚点那一截。
// 不管什么：步骤表的格式（SmokeScript）、执行和事件（SmokeDriver / SmokeEvents）。
//
//   {"do": "zoom", "at": [x, y], "factor": 2, "steps": 10, "vertical": false}

@MainActor
enum SmokeTimelineSteps {

    static func zoom(_ step: SmokeStep, project: VideoEditProject, window: NSWindow) async throws -> String {
        let at = try SmokeStep.point(step.at, "zoom.at")
        let location = NSPoint(x: at.x, y: window.frame.height - at.y)
        guard let geometry = TimelineScrollGeometry.live else { throw SmokeScriptError("zoom：时间线不在屏幕上") }
        let vertical = step.vertical == true
        let factor = step.factor ?? 2
        let steps = max(1, step.steps ?? 10)
        let perStep = pow(factor, 1 / Double(steps))
        let before = probe(location, window: window, project: project, geometry: geometry)
        if vertical {
            let anchor = TimelineZoom.verticalAnchor(pointerAt: location, in: window, project: project, geometry: geometry)
            for _ in 0..<steps {
                TimelineZoom.vertical(project, by: perStep, around: anchor, geometry: geometry)
                try await Task.sleep(for: SmokeEvents.beat)
            }
        } else {
            let anchor = TimelineZoom.pointerAnchor(
                atWindowPoint: location, in: window, project: project, geometry: geometry
            ) ?? .playheadOrCenter
            for _ in 0..<steps {
                TimelineZoom.horizontal(project, to: project.pixelsPerSecond * perStep, keeping: anchor, geometry: geometry)
                try await Task.sleep(for: SmokeEvents.beat)
            }
        }
        try await Task.sleep(for: .milliseconds(300))
        let after = probe(location, window: window, project: project, geometry: geometry)
        return "缩放（\(vertical ? "纵向" : "横向") ×\(factor)，\(steps) 拍）指针底下：\(before) → \(after)"
    }

    /// 指针底下是第几秒、哪一行的第几成，外加比例和滚动量。
    private static func probe(
        _ location: NSPoint, window: NSWindow, project: VideoEditProject, geometry: TimelineScrollGeometry
    ) -> String {
        guard let point = geometry.location(ofWindowPoint: location, in: window) else { return "（不在时间线上）" }
        let pps = project.pixelsPerSecond
        let y = Double(point.content.y)
        let rows = VideoEditTimelineView.layouts(of: TimelineRowList.rows(for: project), open: nil)
        let row = rows.first { y >= $0.minY && y < $0.maxY }
        let fraction = row.map { (y - $0.minY) / max($0.maxY - $0.minY, 1) }
        return "t=\(round3(Double(point.content.x) / pps)) 行=\(row?.spec.id.prefix(14) ?? "-")"
            + " 行内=\(fraction.map(round3) ?? -1) 行高=\(row.map { round3($0.maxY - $0.minY) } ?? -1)"
            + " pps=\(round3(pps)) 滚动=(\(round3(geometry.offsetX)), \(round3(geometry.offsetY)))"
    }

    private static func round3(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
}
