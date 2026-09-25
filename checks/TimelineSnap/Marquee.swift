import CoreGraphics
import Foundation

// 第 15 组：框选 —— 相交即选中、跳过隐藏轨、最小宽度和画出来的一致、加选并集一类都不丢。
// 从 main.swift 搬出来（那个文件登记过超标、只许降），断言原样，外加 2026-09-25 的滤镜段加选
// （docs/bugfixes/2026-09-25-marquee-additive-drops-filters.md）。
// 长期约束见 docs/architecture/timeline-drag-gestures.md 的「框选」一节。编译方式见 scripts/check-timeline-snap.sh。

func checkMarquee() {
    let a = UUID(), b = UUID(), tiny = UUID(), shape = UUID(), cue = UUID(), hidden = UUID()
    // 24 点/秒：A=[0,5]→[0,120]，B=[10,15]→[240,360]，tiny 是 0.05 秒的碎块。
    let rows = [
        TimelineMarquee.Row(minY: 0, maxY: 40, items: [
            TimelineMarquee.Item(id: a, start: 0, end: 5, kind: .clip),
            TimelineMarquee.Item(id: b, start: 10, end: 15, kind: .clip),
            TimelineMarquee.Item(id: tiny, start: 20, end: 20.05, kind: .clip),
        ]),
        TimelineMarquee.Row(minY: 46, maxY: 66, items: [
            TimelineMarquee.Item(id: shape, start: 3, end: 4, kind: .shape),
        ]),
        TimelineMarquee.Row(minY: 72, maxY: 86, items: [
            TimelineMarquee.Item(id: cue, start: 1, end: 2, kind: .subtitleCue),
        ]),
        TimelineMarquee.Row(minY: 92, maxY: 132, isHidden: true, items: [
            TimelineMarquee.Item(id: hidden, start: 0, end: 5, kind: .clip),
        ]),
    ]

    // 相交即选中：框只压住 A 右边一丁点，也算中。要求「整个框住」的话，
    // 放大之后选一段长素材得把框拖出好几屏。
    var hit = TimelineMarquee.hits(
        rect: CGRect(x: 118, y: 10, width: 4, height: 4), rows: rows, pixelsPerSecond: 24
    )
    checkEqual(hit.clips, [a], "框碰到块的边就算选中（相交即选）")

    // 横着扫一条零高度的细线：一整排都该中。
    hit = TimelineMarquee.hits(
        rect: CGRect(x: 0, y: 20, width: 400, height: 0), rows: rows, pixelsPerSecond: 24
    )
    checkEqual(hit.clips, [a, b], "横扫一条细线选中一整排")
    check(hit.shapes.isEmpty && hit.cues.isEmpty, "细线只在自己那一行里选，不许穿到别的行")

    // 三类一次框中。
    hit = TimelineMarquee.hits(
        rect: CGRect(x: 0, y: 0, width: 400, height: 90), rows: rows, pixelsPerSecond: 24
    )
    checkEqual(hit.clips, [a, b], "整片框：剪辑")
    checkEqual(hit.shapes, [shape], "整片框：形状")
    checkEqual(hit.cues, [cue], "整片框：字幕 cue")

    // 隐藏轨整轨跳过：看不见的东西被框走、跟着一起被拖被删是纯粹的惊吓。
    hit = TimelineMarquee.hits(
        rect: CGRect(x: 0, y: 0, width: 400, height: 200), rows: rows, pixelsPerSecond: 24
    )
    check(!hit.clips.contains(hidden), "隐藏轨上的块不许被框中")

    // 最小宽度：0.05 秒的碎块按真实时长只有 1.2 点宽，用户明明框过了那个可见的
    // 小方块却什么都没选中 —— 判定必须和**画出来的**宽度一致。
    let tinyX = 20 * 24.0
    hit = TimelineMarquee.hits(
        rect: CGRect(x: tinyX + 3, y: 10, width: 1, height: 4), rows: rows, pixelsPerSecond: 24
    )
    checkEqual(hit.clips, [tiny], "碎块按画出来的最小宽度判定（\(TimelineMarquee.clipMinimumWidth) 点）")

    // 空框（点一下空白）什么都不选。
    hit = TimelineMarquee.hits(
        rect: CGRect(x: 200, y: 10, width: 0, height: 0), rows: rows, pixelsPerSecond: 24
    )
    check(hit.isEmpty, "空白处的空框什么都不选")

    // 会话：加选在原有选择上并集，不加选则整个替换。
    let chosenFilter = UUID()
    var session = TimelineMarquee.Session(
        anchor: CGPoint(x: 0, y: 10), additive: true,
        base: TimelineMarquee.Hit(clips: [b], shapes: [], texts: [], cues: [], filters: [chosenFilter])
    )
    session.update(current: CGPoint(x: 120, y: 30), rows: rows, pixelsPerSecond: 24)
    checkEqual(session.hit.clips, [a, b], "⌘/⇧ 拖框 = 在原有选择上加选")
    checkEqual(session.hit.filters, [chosenFilter], "加选不许丢掉原来选中的滤镜段（框外的也留着）")

    session = TimelineMarquee.Session(
        anchor: CGPoint(x: 0, y: 10), additive: false,
        base: TimelineMarquee.Hit(clips: [b], shapes: [], texts: [], cues: [], filters: [chosenFilter])
    )
    session.update(current: CGPoint(x: 120, y: 30), rows: rows, pixelsPerSecond: 24)
    checkEqual(session.hit.clips, [a], "空手拖框 = 丢掉旧选择")
    check(session.hit.filters.isEmpty, "空手拖框 = 连原来选中的滤镜段一起丢掉")

    // 往左上方向拉的框（current 在 anchor 左边）同样要成立。
    session = TimelineMarquee.Session(anchor: CGPoint(x: 400, y: 60), additive: false, base: .init())
    session.update(current: CGPoint(x: 0, y: 0), rows: rows, pixelsPerSecond: 24)
    // x 只到 400 点（≈16.7 秒），20 秒处的碎块够不着。
    checkEqual(session.hit.clips, [a, b], "反向拉框一样算")
    checkEqual(session.hit.shapes, [shape], "反向拉框跨行一样算")

    // union 一类都不许丢：夹具每一类都不空（Mirror 数一遍 —— Hit 新加一类却没进夹具就红），
    // 并上空的、空的并上它，都得原样回来（2026-09-25：union 漏了 filters）。
    let full = TimelineMarquee.Hit(
        clips: [UUID()], shapes: [UUID()], texts: [UUID()], cues: [UUID()], filters: [UUID()]
    )
    for child in Mirror(reflecting: full).children {
        check((child.value as? Set<UUID>)?.isEmpty == false,
              "夹具里 \(child.label ?? "?") 是空的：Hit 加了一类，这里和 union 都要跟上")
    }
    checkEqual(full.union(TimelineMarquee.Hit()), full, "并上空的 = 原样（union 漏了哪一类就在这儿红）")
    checkEqual(TimelineMarquee.Hit().union(full), full, "空的并上它 = 它")
}
