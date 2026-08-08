import CoreGraphics
import Foundation

/// 定格的产品常量。
enum FreezeFrame {
    /// 定格段默认插多长。插进去就是普通图片段，拖边缘随便改
    /// （上限 `StillImageClipFactory.stillDuration`）。
    static let defaultDuration = 2.0
}

extension EditClip {

    /// 由这一段在 `time` 处的样子造一个定格段。
    ///
    /// 画面必须和切口左边最后一帧**完全一致**，所以静态变换全部照抄
    /// （PNG 是未裁剪的原始帧，继承 crop 后画面对得上）。
    ///
    /// 有关键帧动画时不能直接抄 `animation`：定格段只有一帧，动画会让它在这
    /// 2 秒里继续飘，接缝处直接跳一下。取那一刻的动画值烘成静态值才对得齐。
    func makeFreezeClip(
        image: URL,
        still: URL,
        info: MediaInfo?,
        at time: Double,
        duration: Double = FreezeFrame.defaultDuration,
        canvas: CGSize,
        isOverlay: Bool
    ) -> EditClip {
        var freeze = EditClip(
            sourceURL: still,
            sourceStart: 0,
            sourceDuration: duration,
            timelineStart: time,
            // 静帧视频本来就没有音轨，静音只是把意图写明白。
            isMuted: true,
            // 切口两边都是硬切。原段自己的转场在 split 里已经跟着右半走了。
            transitionAfter: .none,
            overlayFraction: overlayFraction,
            overlayAnchor: overlayAnchor,
            flippedHorizontally: flippedHorizontally,
            flippedVertically: flippedVertically,
            crop: crop,
            info: info,
            stillImageURL: image
        )
        if isAnimated {
            freeze.placement = animatedPlacement(atTimeline: time, canvas: canvas, isOverlay: isOverlay)
            freeze.rotationDegrees = animatedRotation(atTimeline: time)
            freeze.opacity = animatedOpacity(atTimeline: time)
        } else {
            freeze.placement = placement
            freeze.rotationDegrees = rotationDegrees
            freeze.opacity = opacity
        }
        return freeze
    }
}

// MARK: - 时间线的纯值变换（分割、定格插入）
//
// 这里只动 `TimelineState`，不碰 AVFoundation / ffmpeg / 磁盘 / UI。
// 单独一个文件有两个原因：
//   1. `VideoEditProject.swift` 已经在 AGENTS.md 的超标待瘦身名单上，
//      这些块职责独立，顺手搬出来；
//   2. 自检脚本是**直接挑源文件编**的（SwiftPM 不允许两个 target 共用源文件），
//      纯值变换单独成文件才能脱离整个 App 回归 —— 见
//      `scripts/check-freeze-frame.sh`。

extension TimelineState {

    /// 把主轨数组顺序归一成时间顺序。
    ///
    /// 主轨的下游全都假设「数组顺序 = 时间顺序」：A/B 合成轨的插入游标只会前进
    /// （乱序时 `insertTimeRange` 会把已插好的段往后挤 —— 表现为黑屏/画面错时）、
    /// 转场按数组相邻配对、auto 画布取数组第一段的尺寸。磁吸开着时 `packMain()`
    /// 维持这个不变量；磁吸关掉时拖动只改 `timelineStart`、跨轨挪动直接 append，
    /// 顺序就散了 —— 改动入口和打开工程时都要调这里修正。
    /// 起点相同（理论上不该有）保持原相对顺序，排序结果可复现。
    mutating func sortMainClipsByStart() {
        let ordered = zip(mainClips, mainClips.dropFirst())
            .allSatisfy { $0.timelineStart <= $1.timelineStart }
        guard !ordered else { return }
        mainClips = mainClips.enumerated()
            .sorted { ($0.element.timelineStart, $0.offset) < ($1.element.timelineStart, $1.offset) }
            .map(\.element)
    }

    /// 在 `time` 处把一段切成两半。左半保留原来的身份（id 不变），右半是新的一段。
    mutating func split(clipID: UUID, at time: Double) {
        guard let location = location(of: clipID) else { return }
        var clips = self[track: location.track]
        var left = clips[location.clipIndex]
        guard left.contains(time: time) else { return }

        let leftSourceLength = (time - left.timelineStart) * left.speed
        var right = left
        // 右半是新的一段，得有自己的身份，链接组保持一致。
        right = EditClip(
            sourceURL: left.sourceURL,
            isAudioOnly: left.isAudioOnly,
            sourceStart: left.sourceStart + leftSourceLength,
            sourceDuration: left.sourceDuration - leftSourceLength,
            speed: left.speed,
            timelineStart: time,
            isMuted: left.isMuted,
            volume: left.volume,
            linkGroup: left.linkGroup,
            transitionAfter: left.transitionAfter,
            transitionDuration: left.transitionDuration,
            overlayFraction: left.overlayFraction,
            overlayAnchor: left.overlayAnchor,
            placement: left.placement,
            rotationDegrees: left.rotationDegrees,
            opacity: left.opacity,
            flippedHorizontally: left.flippedHorizontally,
            flippedVertically: left.flippedVertically,
            crop: left.crop,
            // 关键帧锚在源时间上：两半带同一份轨，各自只播自己窗口内的段落，
            // 接缝处数值天然连续。
            animation: left.animation,
            info: left.info,
            audioAssetDuration: left.audioAssetDuration,
            // 图片段的身份必须跟过来：`sourceURL` 只是随时会被系统清掉的静帧缓存，
            // 丢了 `stillImageURL` 的话，右半段会把缓存 mp4 当真实素材写进工程 ——
            // 缓存一清这段就再也无法从原图重建了。
            stillImageURL: left.stillImageURL
        )
        right.needsStillConversion = left.needsStillConversion
        left.sourceDuration = leftSourceLength
        // 切口是硬切，原来的转场跟着右半走。
        left.transitionAfter = .none

        clips[location.clipIndex] = left
        clips.insert(right, at: location.clipIndex + 1)
        self[track: location.track] = clips
    }

    /// 这一段在主轨上牵扯着转场吗（自己往后叠，或者被前一段叠上来）。
    ///
    /// **牵扯转场的段不给定格**，因为转场时长有个「不超过两边任一段 45%」的上限
    /// （`transitionOverlap`）：定格把这一段切短之后，那个上限会跟着缩，于是
    /// `packMain()` 让后面的画面移动的距离**不等于**定格时长，而音频只会老老实实
    /// 顺推一个定格时长 —— 从切口往后声画就永久错开了。
    ///
    /// 实测：A 在 10s 结束、与 B 有 1s 转场，在 A 的 8.5s 定格，B 位移 2.325s
    /// 而音频位移 2.0s，错位 0.325s。
    ///
    /// 要真正支持这种情况，就得按重排后的实际时间映射去推音频（每条转场缩多少
    /// 各不相同，连定格段自己的落点都会变），复杂度远超这个功能该有的分量。
    /// 先禁掉，等有真实需求再说。
    func participatesInMainTransition(clipID: UUID) -> Bool {
        guard let index = mainClips.firstIndex(where: { $0.id == clipID }) else { return false }
        if transitionOverlap(afterMainIndex: index) > 0 { return true }
        if index > 0, transitionOverlap(afterMainIndex: index - 1) > 0 { return true }
        return false
    }

    /// 播放头是不是落在主轨某个转场的**叠化区**里。
    ///
    /// 叠化区显示的是两段合成出来的画面，从单个源素材抽帧必然和眼睛看到的对不上
    /// —— 定格按钮在这里要置灰。（`participatesInMainTransition` 已经覆盖了主轨的
    /// 这一情形，但两条的理由不同，各留各的。）
    func isInsideMainTransition(time: Double) -> Bool {
        for index in mainClips.indices {
            let overlap = transitionOverlap(afterMainIndex: index)
            guard overlap > 0 else { continue }
            let end = mainClips[index].timelineEnd
            if time > end - overlap - 0.001 && time < end + 0.001 { return true }
        }
        return false
    }

    /// 定格插入：把 `clipID` 在 `time` 处切开，同轨切口右边的一切让出
    /// `freeze` 那么长的位置，定格段落进中间。
    ///
    /// 目标在**主轨**时音频轨也跟着让位（= 一次真正的插入编辑）：跨在切口上的
    /// 音频段先切开再推右半，不切的话它的后半段会比画面早一整个定格时长。
    /// 目标在画中画轨时只动那一条轨 —— 一个小窗的定格不该把整条节目的声音推走。
    ///
    /// 字幕、形状标注一律不动（产品决定，见 docs/architecture/）。
    mutating func insertFreeze(_ freeze: EditClip, splitting clipID: UUID, at time: Double) {
        guard let location = location(of: clipID),
              clip(with: clipID)?.contains(time: time) == true else { return }
        let duration = freeze.timelineDuration
        guard duration > 0 else { return }

        split(clipID: clipID, at: time)

        // 同轨让位。切口右边的一切（含刚切出来的右半）整体后挪，定格段填进空档。
        // 磁吸开着时 `packMain()` 之后还会按数组顺序重排一遍，这里的位移是给
        // 磁吸关着的情况用的 —— 一条代码路径两种情况都对。
        var clips = self[track: location.track]
        for index in clips.indices where clips[index].timelineStart >= time - 0.0005 {
            clips[index].timelineStart += duration
        }
        var placed = freeze
        placed.timelineStart = time
        clips.insert(placed, at: location.clipIndex + 1)
        self[track: location.track] = clips

        guard location.track.isMain else { return }

        let straddling = audioTracks.flatMap(\.clips).filter { $0.contains(time: time) }.map(\.id)
        for id in straddling { split(clipID: id, at: time) }
        for lane in audioTracks.indices {
            for index in audioTracks[lane].clips.indices
            where audioTracks[lane].clips[index].timelineStart >= time - 0.0005 {
                audioTracks[lane].clips[index].timelineStart += duration
            }
        }
    }
}
