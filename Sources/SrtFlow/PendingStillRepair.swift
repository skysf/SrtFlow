import Foundation

// MARK: - 已经转完静帧的占位图片块，补成真素材
//
// 管什么：时间线上还标着「在转静帧」的图片块（`needsStillConversion`），缓存里已经有转好的视频了 —— 换上视频、
// 去掉占位标记、带上探测到的信息。纯值：给一份时间线和「查探测信息」的办法，回一份补好的；没有可补的回 nil。
// 不管什么：转静帧本身（`StillImageClipFactory`）、什么时候补（撤销 / 重做 / 整轮换回之后，`VideoEditProject.adopt`）。

enum PendingStillRepair {
    static func repaired(_ state: TimelineState, info: (URL) -> MediaInfo?) -> TimelineState? {
        var next = state
        var changed = false
        for clip in next.allClips where clip.needsStillConversion {
            // 查缓存要带上这一段自己的分辨率政策，见 `needsNativeResolution` 的注释。
            guard let image = clip.stillImageURL,
                  let video = StillImageClipFactory.cachedStillVideo(
                    for: image,
                    nativeResolution: StillImageClipFactory.needsNativeResolution(for: clip.info?.displaySize)
                  ) else { continue }
            let probed = info(video)
            next.update(clip.id) { pending in
                pending.sourceURL = video
                pending.needsStillConversion = false
                if let probed { pending.info = probed }
            }
            changed = true
        }
        return changed ? next : nil
    }
}
