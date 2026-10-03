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
        ("单个隐藏（剪辑 / 文字 / 形状 / 滤镜）", checkHiddenItems),  // 24：HiddenItems.swift
        ("两条字幕轨", checkSubtitleTracks),           // 34：SubtitleTracks.swift
        ("字幕生成：只用选中的片段", checkSubtitleSources),  // 35：SubtitleSources.swift
        ("实心的形状", checkFilledShapes),             // 36：FilledShapes.swift
        ("工程自己的字幕样式与逐词高亮", checkSubtitleLook),  // 37：SubtitleLook.swift
        ("盖一块（模糊 / 马赛克）", checkCoverShapes),   // 38：CoverShapes.swift
        ("关键帧的缓动", checkKeyframeEasing),          // 39：KeyframeEasing.swift
        ("标记：所有块 + 标尺", checkMarkersEverywhere),  // 40：Markers.swift
        ("片段换成 upscale 文件 / 换回原片", checkUpscaleSwap),  // 41：Upscale.swift
        ("圆和圆弧", checkCircleArcShapes),             // 43：CircleArcShapes.swift
        ("磁吸跟着工程走", checkMainMagnet),             // 42：MainMagnet.swift
        ("形状的入场 / 出场动画", checkShapeAnimations),  // 44：ShapeAnimations.swift
    ]
    for group in groups {
        do {
            try group.run(root)
        } catch {
            check(false, "\(group.name)那一组抛错：\(error)")
        }
    }
}
