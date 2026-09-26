import Foundation

// 时间线缩放的锚点自检（纯值）。编译方式见 scripts/check-timeline-zoom.sh。
// 2026-09-26 用户拍板：捏合放大「往两边延伸，延伸的点就是鼠标停留的点」；纵向另有一个整体缩放；
// 工具栏的放大缩小也不许一按画面就跳。长期约束见 docs/architecture/timeline-pinch-zoom.md。

var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL [line \(line)] \(message)")
    }
}

func checkClose(_ actual: Double?, _ expected: Double, _ message: String, line: Int = #line) {
    checks += 1
    guard let actual, abs(actual - expected) < 1e-9 else {
        failures += 1
        print("FAIL [line \(line)] \(message): got \(String(describing: actual)), expected \(expected)")
        return
    }
}

typealias Anchor = TimelineZoomAnchor

// MARK: - 1. 横向：锚点那一刻缩放前后都在视口的同一个 x

do {
    // 24 点/秒、滚到 200：视口 x = 300 那一刻是 (200 + 300) / 24 秒。
    let time = Anchor.time(atViewportX: 300, offsetX: 200, pixelsPerSecond: 24)
    checkClose(time, 500.0 / 24, "视口 x 换成时刻：内容 x = 视口 x + 滚动量")
    for scale in [4.0, 12, 48, 137.5, 4800] {
        let offset = Anchor.offsetX(keeping: time, atViewportX: 300, pixelsPerSecond: scale)
        checkClose(Anchor.time(atViewportX: 300, offsetX: offset, pixelsPerSecond: scale), time,
                   "缩放到 \(scale) 点/秒之后，指针底下还是同一刻（往两边延伸，不往一边跑）")
    }
    // 放大一倍：锚点左边的那一段也跟着变长，滚动量 = 新的内容 x − 视口 x（不是「左边缘不动」）。
    checkClose(Anchor.offsetX(keeping: 10, atViewportX: 300, pixelsPerSecond: 48), 180,
               "10 秒在视口 300 处，48 点/秒 → 滚到 480 − 300")
    // 贴着 0 秒缩小：算出来是负的，交给滚动几何夹到 0 —— 左边没有更早的时间，只能贴左。
    check(Anchor.offsetX(keeping: 1, atViewportX: 300, pixelsPerSecond: 24) < 0,
          "贴着开头缩小时理想的滚动量是负的（由滚动几何夹住，不是这里的事）")
}

// MARK: - 2. 工具栏缩放：播放头在视口里钉播放头，不在就钉视口正中

do {
    // 视口 800 宽、滚到 240、24 点/秒：看得见 10 秒 … 43.3 秒。
    var anchor = Anchor.toolbarAnchor(playhead: 20, offsetX: 240, viewportWidth: 800, pixelsPerSecond: 24)
    checkClose(anchor.time, 20, "播放头在视口里：钉的就是播放头")
    checkClose(anchor.viewportX, 240, "播放头在视口里原来的 x（20 × 24 − 240）")
    anchor = Anchor.toolbarAnchor(playhead: 2, offsetX: 240, viewportWidth: 800, pixelsPerSecond: 24)
    checkClose(anchor.viewportX, 400, "播放头滚出左边：钉视口正中")
    checkClose(anchor.time, (240 + 400) / 24.0, "视口正中那一刻")
    anchor = Anchor.toolbarAnchor(playhead: 90, offsetX: 240, viewportWidth: 800, pixelsPerSecond: 24)
    checkClose(anchor.viewportX, 400, "播放头滚出右边：同样钉视口正中")
    anchor = Anchor.toolbarAnchor(playhead: 10, offsetX: 240, viewportWidth: 800, pixelsPerSecond: 24)
    checkClose(anchor.viewportX, 0, "播放头正好压在左边缘也算看得见")
    anchor = Anchor.toolbarAnchor(playhead: 0, offsetX: 0, viewportWidth: 800, pixelsPerSecond: 24)
    checkClose(anchor.viewportX, 0, "没滚过、播放头在 0：钉 0 秒（放大不会把开头推走）")
}

// MARK: - 3. 纵向：锚点按行认，行高变了按比例跟着走

do {
    // 标尺 26、上层轨 54、主轨 54、音频 34，行距 5、顶上留 2（和 TimelineRowMetrics 同一套数）。
    let before = [
        Anchor.RowSpan(id: "ruler", minY: 2, maxY: 28),
        Anchor.RowSpan(id: "overlay", minY: 33, maxY: 87),
        Anchor.RowSpan(id: "main", minY: 92, maxY: 146),
        Anchor.RowSpan(id: "audio", minY: 151, maxY: 185),
    ]
    // 统一成 100 之后。
    let after = [
        Anchor.RowSpan(id: "ruler", minY: 2, maxY: 28),
        Anchor.RowSpan(id: "overlay", minY: 33, maxY: 133),
        Anchor.RowSpan(id: "main", minY: 138, maxY: 238),
        Anchor.RowSpan(id: "audio", minY: 243, maxY: 343),
    ]

    let middleOfMain = Anchor.rowPoint(at: 119, in: before)
    check(middleOfMain == Anchor.RowPoint(rowID: "main", fraction: 0.5, belowBottom: 0), "主轨正中间 = 主轨的五成处")
    checkClose(middleOfMain.flatMap { Anchor.contentY(of: $0, in: after) }, 188,
               "行高变了，锚点还是主轨的正中间（138 + 50）")

    // 两行之间的缝：按上面那一行的下沿往下多远认，缝不跟着缩放。
    let gap = Anchor.rowPoint(at: 149, in: before)
    check(gap == Anchor.RowPoint(rowID: "main", fraction: nil, belowBottom: 3), "主轨和音频轨之间的缝")
    checkClose(gap.flatMap { Anchor.contentY(of: $0, in: after) }, 241, "缝里的锚点跟着主轨下沿走（238 + 3）")

    // 最后一行下面的空白（时间线填满视口撑出来的那一块）。
    let below = Anchor.rowPoint(at: 300, in: before)
    checkClose(below.flatMap { Anchor.contentY(of: $0, in: after) }, 458, "最后一行下面的空白跟着最后一行的下沿走")

    // 不缩放的行（标尺、字幕这类细行）：行高没变，锚点就在同一个 y。
    let onRuler = Anchor.rowPoint(at: 20, in: before)
    checkClose(onRuler.flatMap { Anchor.contentY(of: $0, in: after) }, 20, "标尺上的锚点不动")

    // 比第一行还高（顶上那 2 点留白）。
    let aboveAll = Anchor.rowPoint(at: 1, in: before)
    checkClose(aboveAll.flatMap { Anchor.contentY(of: $0, in: after) }, 1, "顶上留白里的锚点不动")

    // 同一份排布：原样还原（幂等，连续缩放的每一拍都能复用同一个锚点）。
    for y in stride(from: 0.0, through: 320, by: 7) {
        let point = Anchor.rowPoint(at: y, in: before)
        checkClose(point.flatMap { Anchor.contentY(of: $0, in: before) }, y, "排布没变时锚点原样还原（y = \(y)）")
    }

    check(Anchor.rowPoint(at: 50, in: []) == nil, "没有行就没有锚点")
    let orphan = Anchor.RowPoint(rowID: "gone", fraction: 0.5, belowBottom: 0)
    check(Anchor.contentY(of: orphan, in: after) == nil, "锚点那一行不在了（缩放途中轨被删）就不滚")
}

// MARK: - 收尾

print("TimelineZoom checks: \(checks) 项，失败 \(failures) 项")
if failures > 0 {
    exit(1)
}
print("OK")
