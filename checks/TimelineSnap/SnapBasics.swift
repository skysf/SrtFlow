import Foundation

// 第 1 组：起点吸附（老行为，别改坏）。从 main.swift 搬出来（那个文件登记过超标、只许降），
// 断言原样。编译方式见 scripts/check-timeline-snap.sh。

func checkSnapBasics() {

    do {
        let result = TimelineSnap.resolve(
            proposedStart: 9.9, duration: 5, candidates: [0, 10, 30], pixelsPerSecond: pps
        )
        checkClose(result.start, 10, "起点离候选 0.1s，应当吸上去")
        check(result.guides == [10], "吸上了就要亮那条线，得到 \(result.guides)")
    }

    do {
        let result = TimelineSnap.resolve(
            proposedStart: 9.0, duration: 5, candidates: [0, 10, 30], pixelsPerSecond: pps
        )
        checkClose(result.start, 9.0, "离候选 1s 远超阈值，不许吸")
        check(result.guides.isEmpty, "没吸上就不该亮线，得到 \(result.guides)")
    }
}
