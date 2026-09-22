import AppKit
import Foundation
import UniformTypeIdentifiers

// 把一条音频库素材放到时间线上：拖拽载荷 + 落点。
//
// 和滤镜 / 转场的拖拽同一套地基（理由见 `VideoEditFilterDrag.swift` 的文件头）：
// **自定义载荷类型**（别和 `.onDropOfFiles` 打架）、**起手时记一笔拖的是哪条**
//（读 `NSItemProvider` 是异步的，落点框要同步算出来）。
//
// 和那两个的结构差别：音频**先要有文件**。滤镜落下去就是一段参数，而这里落下去
// 之前得把 m4a 下到本地 —— 所以拖放的终点是一个 async 的下载，落点框在下载期间
// 要先占住位置。这一刀先做点 `+` 的路径（有进度可看），拖拽落点在第二刀补。
//
// 顶层类型和扩展放在同一个文件里是有意的：`checks/check-script-source-lists.sh`
// 认不出只有 extension 的文件（那是它写明的盲区），开一个纯扩展文件会让源文件
// 清单守卫漏掉这里。

enum AudioLibraryDrag {
    /// 从音频库拖一条素材到时间线。载荷是 manifest 的 `id`。
    static let typeIdentifier = "com.srtflow.audio-library-item"
    static let type = UTType(exportedAs: typeIdentifier, conformingTo: .data)

    /// 起手时记下拖的是哪一条。理由同滤镜：落点框要**同步**算出来，
    /// 而读 `NSItemProvider` 是异步的。
    @MainActor static var pending: AudioLibraryItem?

    @MainActor
    static func itemProvider(for item: AudioLibraryItem) -> NSItemProvider {
        pending = item
        return NSItemProvider(item: item.id as NSString, typeIdentifier: typeIdentifier)
    }
}

@MainActor
extension VideoEditProject {
    /// 把一条音频库素材落到音频轨上。
    ///
    /// **原样落下，不按工程总长裁短**（plan 第二节的产品决策）：一首三分钟的曲子
    /// 拖进来就是三分钟。替用户裁掉的话他想用后半段还得先想明白为什么变短了 ——
    /// 而剪掉多余的部分本来就是一个拖动作。
    ///
    /// `remoteKey` 是这一刀的关键：它让这段素材在缓存被清掉之后还找得回来
    ///（重链接的第一层线索，见 `requiresFormatVersion18` 的说明）。
    func addLibraryAudio(url: URL, remoteKey: String, duration: Double) {
        let playhead = clock.time
        perform { state in
            let clip = EditClip(
                sourceURL: url,
                isAudioOnly: true,
                sourceDuration: duration,
                timelineStart: playhead,
                audioAssetDuration: duration,
                remoteKey: remoteKey
            )
            _ = state.place(clip, intoAudio: true)
        }
    }
}
