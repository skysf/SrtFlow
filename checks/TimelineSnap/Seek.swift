import Foundation

// 第 1e 组：点一下播放头落到哪（`TimelineSeek`，2026-09-30）。
//
// 1. 全局夹紧 [0, 总长]：点右边那片空白落在片尾、负数落在 0、空工程落在 0。
// 2. 点在块上：落在指针底下那一刻；最右不越过块的最后一帧（`end − 一帧`）—— 落到 `end` 就是
//    下一段的第一帧，工具栏「播放头得落在片段内」的按钮会认成隔壁那段；块比一帧还短就落在起点。
// 3. 指针的 x 在块的框以内（负的当 0）；缩放为 0 或负数时不除 0，落在起点。
// 合同见 docs/architecture/timeline-drag-gestures.md §5f；接线守卫 checks/timeline-drag-wiring/playhead-click.sh。

func checkSeek() {
    // ---- 1. 全局夹紧 ----
    checkClose(TimelineSeek.clamped(12.5, duration: 60), 12.5, "总长以内原样")
    checkClose(TimelineSeek.clamped(75, duration: 60), 60, "点到工程之外落在片尾")
    checkClose(TimelineSeek.clamped(-3, duration: 60), 0, "负数落在 0")
    checkClose(TimelineSeek.clamped(4, duration: 0), 0, "空工程落在 0")

    // ---- 2. 点在块上 ----
    // 块 [10, 14)，24 点/秒，30 fps（一帧 1/30 秒）。
    let frame = 1.0 / 30
    func land(_ x: Double) -> Double {
        TimelineSeek.timeInBlock(x: x, start: 10, end: 14, pps: 24, frameDuration: frame)
    }
    checkClose(land(48), 12, "点在块中间：指针底下那一刻（10 + 48/24）")
    checkClose(land(0), 10, "点在左沿：起点")
    checkClose(land(96), 14 - frame, "点在右沿：块的最后一帧，不是下一段的第一帧")
    checkClose(land(95.9), 14 - frame, "离右沿不到一帧：也夹到最后一帧")
    check(land(96) < 14, "落点严格小于块的终点")
    checkClose(land(-5), 10, "x 是负的（把手那几个点）当 0")
    checkClose(land(500), 14 - frame, "x 越出块的宽度也不出这一块")

    // ---- 3. 比一帧短的块、坏的缩放 ----
    checkClose(
        TimelineSeek.timeInBlock(x: 3, start: 20, end: 20.02, pps: 24, frameDuration: frame), 20,
        "0.02 秒的碎块（不到一帧）落在起点"
    )
    checkClose(
        TimelineSeek.timeInBlock(x: 3, start: 20, end: 20.02, pps: 0, frameDuration: frame), 20,
        "缩放为 0 不除 0，落在起点"
    )
    // 播放头落进块之后，块要认它在自己范围里（形状 / 文字 / 滤镜的 contains 是 [start, end)）。
    let shape = ShapeAnnotation(kind: .rectangle, timelineStart: 10, duration: 4)
    check(shape.contains(time: land(96)), "落在右沿时形状块仍认播放头在自己范围里")
    check(shape.contains(time: land(0)), "落在左沿时也认")
}
