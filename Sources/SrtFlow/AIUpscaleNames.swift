import Foundation
import SrtFlowMCPKit

// MARK: - upscale_clip 的词：档位 / 目标 / 范围的名字 ↔ App 的类型（纯值）
//
// 管什么：AI 传来的 `tier` / `target` / `range` 认成 `FalUpscaleTier` / `FalUpscaleTarget` / `UpscaleRangeChoice`，以及反过来写回结果里。
// 词表在小程序那份清单里（MCPVocabulary.upscaleTiers / upscaleTargets / upscaleRanges），自检逐项对账（checks/MCP/UpscaleToolChecks.swift）。
// 不管什么：工具本身（AIUpscaleTool）。

enum AIUpscaleNames {
    /// 没点名档位时用的（面板的默认也是它：最便宜、AI 素材的预设）。
    static let defaultTierID = "bytedance-standard"

    static func tier(_ name: String) -> FalUpscaleTier? { FalUpscaleTiers.tier(name) }

    /// 「1080p」「1440p」「2160p」：按短边叫（4K 写成 2160p，和导出的档位一个口径）。
    static func target(_ name: String) -> FalUpscaleTarget? {
        FalUpscaleTarget.allCases.first { self.name(of: $0) == name }
    }

    static func name(of target: FalUpscaleTarget) -> String { "\(target.shortSide)p" }

    /// 「clip」这一段 / 「longest」工程里最长的那处 / 「file」整个文件。
    static func range(_ name: String) -> UpscaleRangeChoice? {
        switch name {
        case "clip": return .thisClip
        case "longest": return .longestUse
        case "file": return .wholeFile
        default: return nil
        }
    }

    static func name(of range: UpscaleRangeChoice) -> String {
        switch range {
        case .thisClip: return "clip"
        case .longestUse: return "longest"
        case .wholeFile: return "file"
        }
    }
}
