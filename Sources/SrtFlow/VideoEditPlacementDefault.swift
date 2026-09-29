import CoreGraphics
import Foundation

// MARK: - 摆放「约等于默认布局」就存回 nil
//
// 管什么：一份摆放和默认布局（等比完整放进画布、居中）差不到一个可见的输出像素时，就当它是默认 ——
// 存 nil，检查器和预览都当「没摆过」。检查器写摆放（VideoEditProject+Transform）和 AI 摆画面
// （AIFrameFit）都走这一处，别各写一份容差。
// 不管什么：默认布局本身怎么算（`EditClip.defaultPlacement`）、关键帧（检查器那边自己分支）。
//
// 容差必须是**亚像素**（半个输出像素）：固定的 0.001 在 1920 宽的画布上约等于 1.9px，会把检查器的
// ±1px 步进整个吞回默认值、点了没反应。见 docs/architecture/preview-free-transform.md。

enum PlacementDefault {
    static func matches(_ placement: ClipPlacement, _ fallback: ClipPlacement, canvas: CGSize) -> Bool {
        let toleranceX = 0.5 / max(canvas.width, 1)
        let toleranceY = 0.5 / max(canvas.height, 1)
        return abs(placement.centerX - fallback.centerX) < toleranceX
            && abs(placement.centerY - fallback.centerY) < toleranceY
            && abs(placement.width - fallback.width) < toleranceX
            && abs(placement.height - fallback.height) < toleranceY
    }

    /// 约等于默认就是 nil，否则原样。
    static func normalized(_ placement: ClipPlacement, fallback: ClipPlacement, canvas: CGSize) -> ClipPlacement? {
        matches(placement, fallback, canvas: canvas) ? nil : placement
    }
}
