import Foundation

// 从 main.swift 拆出去的各组，一律从这里调（main.swift 是登记过的老超标文件，只许降不许涨：
// 以前每加一组就在它身上多一段 do / catch）。每组一个文件，编译方式见
// scripts/check-project-file.sh。一组抛错不拦着后面的组，照样记一条失败。

func runSplitOutGroups(root: URL) {
    let groups: [(name: String, run: (URL) throws -> Void)] = [
        ("轨道行高", checkRowHeights),                // 27：RowHeights.swift
        ("音量曲线与推子", checkVolumeCurveAndMixer),   // 28：VolumeCurve.swift
        ("声音场景", checkSoundScenes),                // 29：SoundScene.swift
        ("素材书签缓存", checkMediaBookmarkCache),      // 30：BookmarkCache.swift
        ("数字等待", checkNumberDelay),               // 31：NumberDelay.swift
        ("文字行", checkTextRows),                    // 32：TextRows.swift
        ("全选与滤镜多选", checkSelectAll),           // 33：SelectAll.swift
    ]
    for group in groups {
        do {
            try group.run(root)
        } catch {
            check(false, "\(group.name)那一组抛错：\(error)")
        }
    }
}
