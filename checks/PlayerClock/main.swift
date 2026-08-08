import Foundation

// PlayerClock 悬停预览（peek）状态机的自检。编译方式见 scripts/check-player-clock.sh。
//
// 背景（docs/bugfixes/2026-08-08-hover-ghost-playhead.md）：悬停扫块以前直接
// seek，用户点定的播放头会被悄悄拖走。peek 的合同是：画面可以去别处看一眼，
// 但 `time`（播放头）必须原地不动；任何真正的定位/播放/换片都终结 peek。

var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL [line \(line)] \(message)")
    }
}

let clock = PlayerClock()

// 1. 基线：seek 移动播放头，displayTime 跟随
clock.seek(to: 8)
check(clock.time == 8, "seek 后播放头在 8")
check(clock.peekTime == nil, "seek 后不该有 peek")
check(clock.displayTime == 8, "displayTime 无 peek 时等于播放头")

// 2. peek：画面时间变，播放头不动
clock.peek(at: 15)
check(clock.time == 8, "peek 期间播放头必须原地不动")
check(clock.peekTime == 15, "peekTime 记录悬停位置")
check(clock.displayTime == 15, "displayTime 跟随 peek")

// 3. endPeek：回播放头
clock.endPeek()
check(clock.peekTime == nil, "endPeek 清掉影子指针")
check(clock.displayTime == 8, "endPeek 后画面回播放头")

// 4. 没在 peek 时 endPeek 是无害 no-op
clock.endPeek()
check(clock.time == 8, "空 endPeek 不动播放头")

// 5. peek 中真正 seek（点标尺/点字幕）：peek 终结、播放头移动
clock.peek(at: 12)
clock.seek(to: 3)
check(clock.peekTime == nil, "seek 终结 peek")
check(clock.time == 3, "seek 把播放头移过去")
check(clock.displayTime == 3, "displayTime 回到播放头")

// 6. peek 中开始播放：必须从播放头起播，peek 终结
clock.peek(at: 17)
clock.togglePlayback()
check(clock.peekTime == nil, "播放终结 peek（从播放头起播，不是从悬停处）")
check(clock.time == 3, "播放起点是播放头")
clock.pause()

// 7. peek 中换条目（预览重建）：peek 清干净
clock.peek(at: 9)
clock.detach()
check(clock.peekTime == nil, "detach 清掉 peek")
check(clock.time == 0, "detach 归零")

// 8. 负数入参收口
clock.peek(at: -5)
check(clock.peekTime == 0, "peek 负数收口到 0")
clock.endPeek()

print("\(checks) checks, \(failures) failures")
if failures == 0 { print("All checks passed") }
exit(failures == 0 ? 0 : 1)
