import Foundation

// MARK: - 时间线引用了哪些文件（存盘配书签、重链接）
//
// 管什么：`mediaURLs`（此刻播放要用的文件：素材、字幕）、`upscaleOriginalURLs`（换成 upscale 文件的段的原片：
// 不用来播，但要配书签，换回去时找得到）、`replaceMedia`（重链接时把旧路径改成新路径，原片的记录也一起改）。
// 从 VideoEditModels.swift 搬出来（2026-10-02，给 `EditClip.upscale` 腾地方）。
// 不管什么：书签怎么建（MediaBookmarkCache）、找回来的四层线索（VideoEditProjectIO.resolve）、缺了之后的提示条。

/// 一段引用的文件：图片段存的是原图（静帧视频是缓存，能重生成），别的是 `sourceURL`。
enum MediaReferences {
    static func fileURL(of clip: EditClip) -> URL { clip.stillImageURL ?? clip.sourceURL }

    /// 把这一段里指向 `old` 的引用改成 `new`：静帧的原图、素材本身、upscale 的原片。
    static func replace(_ old: URL, with new: URL, in clip: inout EditClip) {
        if clip.stillImageURL == old {
            clip.stillImageURL = new
        } else if clip.sourceURL == old {
            clip.sourceURL = new
        }
        if clip.upscale?.originalURL == old { clip.upscale?.originalURL = new }
    }
}

extension TimelineState {
    /// 此刻播放要用的所有文件路径（含字幕文件），去重。存盘时给它们各配一份书签；找不到的进「缺素材」提示条。
    var mediaURLs: [URL] {
        var seen = Set<URL>()
        var result: [URL] = []
        for clip in allClips where seen.insert(MediaReferences.fileURL(of: clip)).inserted {
            result.append(MediaReferences.fileURL(of: clip))
        }
        if let subtitleURL, seen.insert(subtitleURL).inserted { result.append(subtitleURL) }
        return result
    }

    /// 换成 upscale 文件的段的原片：**不在 `mediaURLs` 里**（原片删了不该亮「缺素材」，播放用不着它），
    /// 但存盘时也配书签，换回原片时按书签找得到。
    var upscaleOriginalURLs: [URL] {
        let playing = Set(mediaURLs)
        var seen = Set<URL>()
        var result: [URL] = []
        for clip in allClips {
            guard let original = clip.upscale?.originalURL, !playing.contains(original), seen.insert(original).inserted else { continue }
            result.append(original)
        }
        return result
    }

    /// 把所有指向 `old` 的引用改成 `new`。重新链接素材时用。
    mutating func replaceMedia(_ old: URL, with new: URL) {
        for index in mainClips.indices { MediaReferences.replace(old, with: new, in: &mainClips[index]) }
        for lane in overlayTracks.indices {
            for index in overlayTracks[lane].clips.indices { MediaReferences.replace(old, with: new, in: &overlayTracks[lane].clips[index]) }
        }
        for lane in audioTracks.indices {
            for index in audioTracks[lane].clips.indices { MediaReferences.replace(old, with: new, in: &audioTracks[lane].clips[index]) }
        }
        if subtitleURL == old { subtitleURL = new }
    }
}
