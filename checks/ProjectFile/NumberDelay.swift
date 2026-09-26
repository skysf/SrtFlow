import Foundation

// 第 31 组：数字元件的等待（`NumberRoll.delay`，2026-09-24 用户拍板）。
//
// 1. 没设等待的工程不是 v21 数据、不落 `delay` 键（按需写入，同 v8 的标记）；
// 2. 设了等待就是 v21 数据，存盘写 `delay`、读回来原样；
// 3. 读盘夹紧：负数 / NaN 回 0，超过上限夹到上限（等 60 秒已经没有意义）。
// 合同见 docs/architecture/text-overlays.md「等待」。

func checkNumberDelay(root: URL) throws {
    let dir = root.appendingPathComponent("numberdelay")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    var state = TimelineState()
    var overlay = TextOverlay(timelineStart: 1, duration: 5)
    overlay.number = NumberRoll(
        from: 0, to: 365, fractionDigits: 0, groupsThousands: true,
        prefix: "", suffix: "", style: .count, duration: 2
    )
    state.textOverlays = [overlay]
    check(state.requiresFormatVersion13, "数字元件是 v13 数据（v21 是因为行号，见第 32 组）")

    let plainFile = dir.appendingPathComponent("no-delay.srtflowproj")
    try VideoEditProjectIO.save(state, to: plainFile)
    let plainRaw = try JSONSerialization.jsonObject(with: Data(contentsOf: plainFile)) as? [String: Any]
    let plainNumber = ((plainRaw?["timeline"] as? [String: Any])?["textOverlays"] as? [[String: Any]])?
        .first?["number"] as? [String: Any]
    check(plainNumber != nil && plainNumber?["delay"] == nil, "没等待时不该写 delay 键")

    state.textOverlays[0].number?.delay = 1.5
    check(state.requiresFormatVersion21, "设了等待就是 v21 数据")
    let delayFile = dir.appendingPathComponent("delay.srtflowproj")
    try VideoEditProjectIO.save(state, to: delayFile)
    let delayRaw = try JSONSerialization.jsonObject(with: Data(contentsOf: delayFile)) as? [String: Any]
    checkEqual(delayRaw?["formatVersion"] as? Int, 23, "带等待的工程写 latest（v23）")
    let back = try VideoEditProjectIO.load(from: delayFile).timeline.textOverlays.first?.number
    checkEqual(back?.delay, 1.5, "等待往返不变")
    checkEqual(back?.duration, 2, "滚动时长不受等待影响")

    // 夹紧：坏值不入模型。
    var hostile = state.textOverlays[0].number!
    hostile.delay = -3
    hostile.clampToValidRange()
    checkEqual(hostile.delay, 0, "负的等待夹回 0")
    hostile.delay = .nan
    hostile.clampToValidRange()
    checkEqual(hostile.delay, 0, "NaN 回 0")
    hostile.delay = 1000
    hostile.clampToValidRange()
    checkEqual(hostile.delay, NumberRoll.delayRange.upperBound, "超上限夹到上限")
}
