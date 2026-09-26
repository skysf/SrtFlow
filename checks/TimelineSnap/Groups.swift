import Foundation

// 从 main.swift 拆出去的各组，一律从这里调（main.swift 是登记过的老超标文件，只许降不许涨：
// 以前每加一组就在它身上多两行）。每组一个文件，编译方式见 scripts/check-timeline-snap.sh。

func runSplitOutGroups() {
    checkSnapBasics()       // 1：起点吸附（SnapBasics.swift）
    checkTrim()             // 1b：裁切，一段的范围、一组一起裁（Trim.swift）
    checkAlignmentGuides()  // 1c：对齐点、整组外沿、磁吸也亮线（Guides.swift）
    checkTrimSnap()         // 1d：裁切的吸附与对齐线（TrimSnap.swift）
}
