import AppKit
import SwiftUI
import Foundation
import UniformTypeIdentifiers

// 把一条音频库素材放到时间线上：拖拽载荷 + 落点。
//
// 和滤镜 / 转场的拖拽同一套地基（理由见 `VideoEditFilterDrag.swift` 的文件头）：
// **自定义载荷类型**（别和 `.onDropOfFiles` 打架）、**起手时记一笔拖的是哪条**
//（读 `NSItemProvider` 是异步的，落点框要同步算出来）。
//
// 和那两个的结构差别：音频**先要有文件**。滤镜落下去就是一段参数，这里落下去
// 之前得把 m4a 下到本地。两条路：
//
// - **缓存里已经有** → 同步落块，和滤镜一样快（翻库时反复试同一首，这是常态）；
// - **还没下过** → 松手后开始下，**下完才落块**，落点用松手那一刻算好的。
//
// 为什么不先落一个占位块再无感替换（图片转静帧那套）：那要给 `EditClip` 再加一个
// 「正在下载」的状态，而它会渗进预览、导出、存盘每一条路径。几 MB 的 m4a 只要
// 一两秒，进度在库面板那一行看得见 —— 为了省这一两秒去换一个全局的新状态不划算。
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

/// 松手之后这一段落在哪：起点、时长、哪条音频轨。
///
/// **画框和落地走同一个 plan**，不各算一次 —— 滤镜和转场都踩过这条
///（框画在这儿、东西落到别处，是最难查的一种错）。
struct AudioLibraryDropPlan: Equatable {
    var start: Double
    var duration: Double
    /// 落进第几条音频轨；`nil` = 指针不在任何音频轨上，交给 `place` 自己找。
    var laneIndex: Int?
    /// 落点框画在哪个 y 和多高。
    var rowY: Double
    var rowHeight: Double
    /// 要亮的对齐参考线。
    var guides: [Double]

    var end: Double { start + duration }
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
    ///（重链接的头一层线索，见 `requiresFormatVersion18` 和
    /// `VideoEditProjectIO.relinkRemoteLibraryMedia`）。
    ///
    /// `start` 为 nil 时落在播放头上（按 `+` 的口径），非 nil 是拖放算好的落点。
    /// `laneIndex` 同理：拖放指到了哪条轨就用哪条，指不到就让 `place` 自己找。
    func addLibraryAudio(
        url: URL, remoteKey: String, duration: Double,
        at start: Double? = nil, laneIndex: Int? = nil
    ) {
        let where_ = start ?? clock.time
        perform { state in
            let clip = EditClip(
                sourceURL: url,
                isAudioOnly: true,
                sourceDuration: duration,
                timelineStart: where_,
                audioAssetDuration: duration,
                remoteKey: remoteKey
            )
            // 指名了轨就落那条，但**放不下时不硬塞** —— 叠在别的块上会让两段
            // 同时出声，而用户看到的是一条轨上两个块重叠在一起。退回 `place`
            // 去找一条放得下的，和按 `+` 同一套规则。
            if let laneIndex, state.audioTracks.indices.contains(laneIndex),
               !state.audioTracks[laneIndex].isHidden,
               state.audioTracks[laneIndex].clips.allSatisfy({
                   $0.timelineStart >= clip.timelineEnd - 0.001
                       || clip.timelineStart >= $0.timelineEnd - 0.001
               }) {
                state.audioTracks[laneIndex].clips.append(clip)
                state.audioTracks[laneIndex].clips.sort { $0.timelineStart < $1.timelineStart }
            } else {
                _ = state.place(clip, intoAudio: true)
            }
        }
    }

    /// 拖放松手：缓存里有就立刻落，没有就下完再落。
    ///
    /// 下载期间**不放占位块**（理由见文件头）。进度在库面板那一行看得见。
    func dropLibraryAudio(_ item: AudioLibraryItem, plan: AudioLibraryDropPlan) {
        if let local = AudioLibraryCache.shared.localURL(for: item.id) {
            addLibraryAudio(url: local, remoteKey: item.id, duration: item.duration,
                            at: plan.start, laneIndex: plan.laneIndex)
            return
        }
        let generation = documentGeneration
        trackImportTask(Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await AudioLibraryCache.shared.download(item)
                // 下载期间用户可能已经换了工程：这份素材是上一个工程的，别往新的里塞
                //（同 addVideos 那条代号守卫）。
                guard self.isCurrentGeneration(generation) else { return }
                self.addLibraryAudio(url: url, remoteKey: item.id, duration: item.duration,
                                     at: plan.start, laneIndex: plan.laneIndex)
            } catch {
                if self.isCurrentGeneration(generation) {
                    self.notice = error.localizedDescription
                }
            }
        })
    }
}

/// 时间线那块滚动内容的落点代理。
///
/// 结构和 `FilterDropDelegate` 一字不差（挂在整块内容上而不是某一行 —— 落在哪条
/// 音频轨由指针的纵向位置决定，挂一行就拿不到 y 了），差别只在：**落点框的高度
/// 跟着音频行走**，而且松手之后可能要先下载。
struct AudioLibraryDropDelegate: DropDelegate {
    let project: VideoEditProject
    let pps: Double
    let rowLayouts: [VideoEditTimelineView.RowLayout]
    /// 横向滚动量的唯一来源（现读，不缓存 —— 见 timeline-drag-gestures.md §5b）。
    let geometry: TimelineScrollGeometry
    let autoScroller: TimelineAutoScroller
    let viewport: CGSize
    @Binding var preview: AudioLibraryDropPlan?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [AudioLibraryDrag.type])
    }

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated { preview = plan(at: info.location) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        MainActor.assumeIsolated {
            // **用刚算出来的局部值判，不要回读 `preview`**：`@Binding` 的写入不是
            // 同步可见的，回读会让「能不能落」整整晚一帧（同滤镜、转场两条）。
            let next = plan(at: info.location)
            preview = next
            autoScroll(contentX: info.location.x, contentY: info.location.y)
            // `.forbidden`：不能用 `.cancel`，理由见 TimelineDropRouter.dropUpdated。
            return DropProposal(operation: next == nil ? .forbidden : .copy)
        }
    }

    func dropExited(info: DropInfo) {
        MainActor.assumeIsolated {
            preview = nil
            autoScroller.stop()
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            defer {
                preview = nil
                AudioLibraryDrag.pending = nil
                autoScroller.stop()
            }
            guard let item = AudioLibraryDrag.pending, let plan = plan(at: info.location) else {
                return false
            }
            project.dropLibraryAudio(item, plan: plan)
            return true
        }
    }

    @MainActor
    private func plan(at location: CGPoint) -> AudioLibraryDropPlan? {
        guard let item = AudioLibraryDrag.pending else { return nil }
        let duration = item.duration
        // **左边缘对齐指针**（2026-09-23 用户拍板，同从 Finder 拖文件）：整首音乐
        // 动辄两三分钟，中点对齐时起点要退回一分多钟，拖到哪都落不到指针那儿。
        let proposed = max(0, location.x / pps)
        let resolved = TimelineSnap.resolve(
            proposedStart: proposed,
            duration: duration,
            candidates: project.snapCandidates(moving: []),
            pixelsPerSecond: pps
        )

        // 指针在哪一行 → 落进哪条音频轨。不在音频轨上（视频轨、标尺、滤镜行……）
        // 就交给 `place` 自己找一条放得下的，和按 `+` 完全一致。
        let row = rowLayouts.first { location.y >= $0.minY && location.y <= $0.maxY }
        let laneIndex: Int? = {
            if case .audio(let index) = row?.spec.slot { return index }
            return nil
        }()
        // 框画在指到的那条轨上；指不到就画在最下面那条音频轨下方（新轨会长在那儿，
        // 所以框先画在那儿是诚实的）—— 一条音频轨都没有时退回最后一行。
        let fallback = rowLayouts.last { $0.spec.slot?.isAudio == true } ?? rowLayouts.last
        let target = (laneIndex == nil ? fallback : row) ?? fallback
        guard let target else { return nil }

        return AudioLibraryDropPlan(
            start: resolved.start,
            duration: duration,
            laneIndex: laneIndex,
            rowY: target.minY,
            rowHeight: target.maxY - target.minY,
            guides: resolved.guides
        )
    }

    /// 指针停在视口边缘时把时间线推走。**只横着滚**：纵向滚会把音频行滚出视口、
    /// 落点当场消失（同滤镜、转场两条，传 `height: 0` 让心跳的纵向那一半跳过）。
    @MainActor
    private func autoScroll(contentX: Double, contentY: Double) {
        let viewportX = contentX - geometry.offsetX
        autoScroller.update(
            pointer: CGPoint(x: viewportX, y: 0),
            viewport: CGSize(width: viewport.width, height: 0)
        ) {
            preview = plan(at: CGPoint(x: viewportX + geometry.offsetX, y: contentY))
        }
    }
}
