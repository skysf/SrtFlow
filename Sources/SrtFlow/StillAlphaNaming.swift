import Foundation

// MARK: - 带透明的静帧：文件怎么起名、怎么认
//
// 管什么：真用到了透明的图（透明 PNG 的台标、圆环、字幕条）转出来的两份文件 —— 预乘过的 ProRes 4444 静帧
// （`<指纹>-alpha-v1.mov`）和它的灰度遮罩（同名接 `-matte.mp4`：白 = 不透明，H.264，几何、帧数和静帧一样）——
// 叫什么，以及一段的素材是不是这种静帧。只有这一份：转码那边按它起名，预览、导出、预渲染按它认
// （docs/bugfixes/2026-10-03-png-transparency-lost.md）。
// 不管什么：怎么转、什么样的图才算用到了透明（`StillImageClipFactory`）、怎么合成（预览垫黑底、导出先反预乘、
// 带关键帧的上层轨段用这份遮罩当 matte）。纯 Foundation：自检清单里谁都能带上它。

enum StillAlphaNaming {
    /// 静帧的文件名（照片政策 / 原生分辨率政策）。**改编码参数要 +1 版本**（同 `StillImageClipFactory` 的老规矩）。
    static func stillName(key: String, nativeResolution: Bool) -> String {
        nativeResolution ? "\(key)-alpha-native-v1.mov" : "\(key)-alpha-v1.mov"
    }

    /// 这个文件是不是带透明的静帧。
    static func isAlphaStill(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasSuffix("-alpha-v1.mov") || name.hasSuffix("-alpha-native-v1.mov")
    }

    /// 静帧旁边那份遮罩。
    static func matteURL(forStill still: URL) -> URL {
        still.deletingLastPathComponent()
            .appendingPathComponent(still.deletingPathExtension().lastPathComponent + "-matte.mp4")
    }
}
