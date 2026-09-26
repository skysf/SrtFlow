import Foundation

// MARK: - 8c. 电平表的环形缓冲收到 0 之前的位置：丢掉，不许越界崩溃
//
// 2026-09-26 案例 docs/bugfixes/2026-09-26-meter-crash-on-go-to-start.md：播放中按 Return 回到开头，
// tap 报了比 0 早的时间，`SampleRing.add` 拿负数取余当下标，整个 App 在音频线程上崩掉。
// 两种越界都要钉住：位置在 (-256, 0) 时块号是 0、采样下标是负的；位置 ≤ -256 时块号就是负的
// （现场崩在这一种）。修之前这一组直接让自检进程崩溃（非零退出），不会走到后面的断言。

func checkMeterRingBeforeZero() {
    let ring = SampleRing(capacity: 1 << 12)
    let now: UInt64 = 1_000
    // 现场那一种（块号为负）和另一种（块号为 0、下标为负），各加几个。
    for position in [Int64(-300), -256, -255, -1] {
        ring.add(position: position, left: 0.9, right: 0.9, now: now)
    }
    // 0 之前的全丢掉：从 0 开始的块里一个字都没多。
    let before = ring.peak(from: 0, to: 256)
    checkEqual(before.left, Float(0), "0 之前的位置不许写进环里（写进去就是越界或者串到别的位置上）")

    // 0 以后的照常：丢负数不许连带丢正常的采样。
    ring.add(position: 0, left: 0.5, right: 0.25, now: now)
    ring.add(position: 255, left: 0.3, right: 0.3, now: now)
    let after = ring.peak(from: 0, to: 256)
    checkEqual(after.left, Float(0.5), "0 以后的采样照常记下")
    checkEqual(after.right, Float(0.3), "0 以后的采样照常记下（右声道取峰值）")
    // 读的那一侧本来就从 0 起读，负的起点照样安全。
    checkEqual(ring.peak(from: -512, to: 256).left, Float(0.5), "从 0 之前开始读也安全，只读到 0 以后的")
}
