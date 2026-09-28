import Foundation

// look 的 shots（AIShotDetector）：相邻两帧差多少、在哪切、镜头按区间裁和翻页。变化量是合成的数列（24 fps），
// 每一种都对着一种真画面：硬切、摇镜头、动作里的硬切、几帧的转场、淡出淡入、闪光、太近的两刀、片尾、片头的黑。
// 真解码在测试版冒烟里（docs/reports/2026-09-28-mcp-slice4-report.md）。编法见 scripts/check-mcp.sh。

func runShotChecks() {
    checkChangeAndBrightness()
    checkCuts()
    checkShotRangesAndPages()
}

private let fps = 24.0

private func times(_ count: Int) -> [Double] { (0..<count).map { Double($0) / fps } }

/// `count` 帧，底子是 `base`（带一点抖动），`spikes` 里的帧换成给的值。
private func changes(_ count: Int, base: Double = 0.01, spikes: [Int: Double] = [:]) -> [Double] {
    var values: [Double] = []
    for index in 0..<count {
        let jitter = 0.004 * Double(index % 3)
        values.append(spikes[index] ?? (index == 0 ? 0 : base + jitter))
    }
    return values
}

private func cuts(_ changes: [Double], brightness: [Double]? = nil) -> [Int] {
    AIShotDetector.cutIndices(
        changes: changes, brightness: brightness ?? Array(repeating: 0.5, count: changes.count), times: times(changes.count)
    )
}

private func checkChangeAndBrightness() {
    let grey = [UInt8](repeating: 128, count: 12)
    checkEqual(AIShotDetector.change(grey, grey), 0, "the same picture: no change")
    checkEqual(AIShotDetector.change([UInt8](repeating: 0, count: 12), [UInt8](repeating: 255, count: 12)), 1, "black to white: all")
    checkEqual(AIShotDetector.change(grey, [UInt8](repeating: 128, count: 9)), 1, "a different size counts as a new picture")
    checkEqual(AIShotDetector.brightness([UInt8](repeating: 0, count: 12)), 0, "black is 0")
    check(abs(AIShotDetector.brightness([UInt8](repeating: 255, count: 12)) - 1) < 1e-9, "white is 1")
}

private func checkCuts() {
    checkEqual(cuts(changes(144, spikes: [48: 0.3, 96: 0.2])), [48, 96], "two hard cuts, found at their frames")
    checkEqual(cuts(changes(144, base: 0.08)), [], "a pan: every frame changes a lot, none stands out")
    checkEqual(cuts(changes(144, base: 0.07, spikes: [60: 0.4])), [60], "a hard cut in the middle of motion")
    checkEqual(cuts(changes(144, spikes: [50: 0.10, 51: 0.25, 52: 0.15, 53: 0.08])), [51],
               "a wipe over four frames: one cut, on the frame that changes most")
    checkEqual(cuts(changes(144, base: 0.07, spikes: (40..<60).reduce(into: [:]) { $0[$1] = 0.09 })), [],
               "a longer run of change (more than half a second) is motion, not a transition")
    var fade = Array(repeating: 0.5, count: 144)
    for index in 40...44 { fade[index] = 0.02 }
    checkEqual(cuts(changes(144), brightness: fade), [42], "fade out and in: cut in the middle of the dark part")
    checkEqual(cuts(changes(144, spikes: [30: 0.3, 31: 0.3])), [30], "a flash: two changes in a row make one cut, not two")
    checkEqual(cuts(changes(144, spikes: [30: 0.3, 36: 0.3])), [30], "two cuts a quarter second apart: only the first")
    checkEqual(cuts(changes(144, spikes: [142: 0.3])), [], "a cut in the last frames is not a shot")
    var darkStart = Array(repeating: 0.5, count: 144)
    for index in 0...10 { darkStart[index] = 0.01 }
    checkEqual(cuts(changes(144), brightness: darkStart), [], "black at the very start is not a cut")
    checkEqual(cuts([]), [], "no frames")
}

private func checkShotRangesAndPages() {
    let shots = AIShotDetector.shots(cutTimes: [2, 5, 9], from: 0, to: 12)
    checkEqual(shots.map(\.start), [0, 2, 5, 9], "shots start at 0 and at every cut")
    checkEqual(shots.map(\.end), [2, 5, 9, 12], "and end at the next cut or the end")
    checkEqual(AIShotDetector.shots(shots, within: 3...10).map { [$0.start, $0.end] }, [[3, 5], [5, 9], [9, 10]],
               "a clip's part: shots cut to it")
    let many = AIShotDetector.shots(cutTimes: (1..<30).map(Double.init), from: 0, to: 30)
    let first = AIShotDetector.page(many, from: nil, size: 24)
    checkEqual(first.items.map(\.number), Array(1...24), "the first page numbers the shots from 1")
    checkEqual(first.next, 24, "next page starts where shot 25 starts")
    let second = AIShotDetector.page(many, from: first.next, size: 24)
    checkEqual(second.items.map(\.number), Array(25...30), "the second page keeps counting")
    check(second.next == nil, "…and is the last")
    checkEqual(AIShotDetector.page(many, from: 7.5, size: 3).items.map(\.number), [8, 9, 10],
               "from in the middle of a shot starts with that shot")
}
