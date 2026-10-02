import Foundation
import SrtFlowCore

// MARK: - upscale 出来的文件叫什么、放哪（纯值 + 一次文件系统探测）
//
// 管什么：用户 2026-10-02 定的名字 `<原名>_<宽x高>_<档位>.mp4`，放在原片所在的文件夹；撞名加编号（`ExportFileName.unoccupied`，
// 全 App 一个规矩）；原片的文件夹写不进去（只读盘、相机卡、没授权）就退到工程的家，再退到下载。
// 不管什么：文件内容（UpscalePipeline）。

enum UpscaleOutputName {
    /// `Shot_鲸鱼` + 1890×1080 + `topaz-precision` → `Shot_鲸鱼_1890x1080_topaz-precision`。
    static func stem(original: URL, outputSize: CGSize, tier: String) -> String {
        let base = ExportFileName.stem(from: original.lastPathComponent, droppingExtension: original.pathExtension, fallback: "Clip")
        return "\(base)_\(Int(outputSize.width.rounded()))x\(Int(outputSize.height.rounded()))_\(tier)"
    }

    /// 放哪：原片的文件夹写得进去就放那里，否则按候选顺序退（工程的家 → 下载）。
    static func folder(original: URL, fallbacks: [URL], isWritable: (URL) -> Bool = { FileManager.default.isWritableFile(atPath: $0.path) }) -> URL {
        let own = original.deletingLastPathComponent()
        if isWritable(own) { return own }
        return fallbacks.first(where: isWritable) ?? own
    }

    /// 不撞名的完整路径（`stem.mp4`、`stem 2.mp4`、…）。
    static func destination(
        original: URL, outputSize: CGSize, tier: String, fallbacks: [URL], pathExtension: String = "mp4",
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        ExportFileName.unoccupied(
            in: folder(original: original, fallbacks: fallbacks), stem: stem(original: original, outputSize: outputSize, tier: tier),
            pathExtension: pathExtension, exists: exists
        )
    }
}
