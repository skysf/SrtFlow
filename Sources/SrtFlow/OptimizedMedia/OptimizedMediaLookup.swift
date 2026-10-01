import Foundation

// MARK: - 优化媒体：builder 换源用的那张表（纯值）
//
// 管什么：按源文件记「哪几块已经转好、文件在哪」。builder 插画面时拿它问一段用到的块齐不齐
//（`CompositionClipInsert`），齐了按块插、差一块插原片。
// 不管什么：转哪几块、先转哪块（OptimizedMediaPlan）、怎么转（OptimizedMediaTranscoder）、什么时候重建换源
//（OptimizedMediaCoordinator）。长期约束见 docs/architecture/optimized-media.md。

struct OptimizedMediaLookup: Sendable, Equatable {
    /// 源路径 → 已转好的块（块号 → 块文件）。
    var chunks: [URL: [Int: URL]] = [:]

    /// 什么都不换：预览窗口选了「原片」、或者成片 / 预渲染 / AI 看那几条永远用原片的路。
    static let none = OptimizedMediaLookup()

    var isEmpty: Bool { chunks.isEmpty }

    /// 这一段用到的块都转好了吗（只看它真正要插的那一截 `renderSourceStart` 起 `renderSourceDuration` 长，
    /// 不含两边的余量）。齐了给出块号 → 块文件，差一块就 nil。
    func readyChunks(for clip: EditClip) -> [Int: URL]? {
        guard let ready = chunks[clip.sourceURL], !ready.isEmpty else { return nil }
        let needed = OptimizedMediaPolicy.coveringChunks(
            sourceStart: clip.renderSourceStart, sourceDuration: clip.renderSourceDuration, sourceLength: clip.assetDuration
        )
        var result: [Int: URL] = [:]
        for chunk in needed {
            guard let url = ready[chunk] else { return nil }
            result[chunk] = url
        }
        return result
    }
}
