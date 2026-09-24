import Foundation

// MARK: - 冒烟驱动：记下工程此刻的样子
//
// 管什么：`state` 这一步写进结果 JSON 的那份摘要 —— 选中了谁、每一段在哪、文字的位置和
// 角度、标记几枚、接缝上的转场、音量线上的点。验「拖了之后落在哪」「⌘A 选中了几个」这类问题，读数比看截图准
// （截图只能说明「动了」，数字能说明动了多少、别的值有没有被带偏）。
// 不管什么：执行和事件（SmokeDriver / SmokeEvents）。
//
// id 只留前 8 位：够认，结果文件也好读。

@MainActor
enum SmokeStateDump {
    static func make(_ project: VideoEditProject) -> [String: Any] {
        let state = project.state
        let selection = project.selection
        var clips: [[String: Any]] = []
        for clip in state.allClips {
            guard let location = state.location(of: clip.id) else { continue }
            clips.append([
                "id": short(clip.id),
                "track": trackName(location.track),
                "start": round3(clip.timelineStart),
                "duration": round3(clip.timelineDuration),
                "markers": clip.markers.count,
                // 主轨接缝上的转场（none 就不写）和音量线上的点：验「从卡片点上去」「拖了点」。
                "transition": clip.transitionAfter == .none ? "" : clip.transitionAfter.rawValue,
                "volumePoints": clip.volumeCurve.keys.map { [round3($0.time), round3($0.value)] },
            ])
        }
        let texts: [[String: Any]] = state.textOverlays.map { overlay in
            [
                "id": short(overlay.id),
                "text": overlay.number == nil ? overlay.text : overlay.settledText,
                "start": round3(overlay.timelineStart),
                "duration": round3(overlay.duration),
                "centerX": round3(overlay.centerX),
                "centerY": round3(overlay.centerY),
                "rotation": round3(overlay.rotationDegrees),
                "fontSize": round3(overlay.style.fontSize),
            ]
        }
        let filters: [[String: Any]] = state.filters.map { filter in
            ["id": short(filter.id), "start": round3(filter.timelineStart),
             "duration": round3(filter.duration), "layer": filter.layer]
        }
        return [
            "playhead": round3(project.clock.time),
            "selection": [
                "clips": selection.clipIDs.map(short).sorted(),
                "shapes": selection.shapeIDs.map(short).sorted(),
                "texts": selection.textIDs.map(short).sorted(),
                "cues": selection.subtitleCueIDs.count,
                "marker": selection.markerRef.map { short($0.markerID) } ?? "",
                "transition": selection.transitionSeamID.map(short) ?? "",
                "filter": selection.filterID.map(short) ?? "",
            ],
            "clips": clips,
            "texts": texts,
            "filters": filters,
            "cues": state.subtitle?.cues.count ?? 0,
        ]
    }

    private static func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }

    private static func round3(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }

    private static func trackName(_ slot: TrackSlot) -> String {
        switch slot {
        case .main: return "main"
        case .overlay(let index): return "overlay\(index)"
        case .audio(let index): return "audio\(index)"
        }
    }
}
