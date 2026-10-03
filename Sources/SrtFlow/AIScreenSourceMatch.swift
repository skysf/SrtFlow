import CoreGraphics
import Foundation
import SrtFlowCore

// MARK: - 录哪个窗口、哪块屏幕、哪个麦克风：AI 给的字 → 候选里的哪一个
//
// 管什么：能录的窗口筛哪些、按什么挑（窗口编号 > App 名一样 > App 名里有 > 标题里有，同一档挑最前面的）、
// 屏幕怎么编号（主屏 1，其余从左到右）、区域的比例换成显示器上的点（取整、夹进屏内、太小报错）、麦克风按名字挑。
// 纯值，自检直接喂候选（checks/MCP/ScreenRecordingToolChecks.swift）。
// 不管什么：候选从哪来（AIScreenSources 读系统的窗口表、显示器、麦克风）、开录（AIScreenRecordingTool）。

enum AIScreenSourceMatch {
    struct Window: Equatable {
        let id: UInt32
        let app: String
        /// 窗口标题。没有「屏幕与系统音频录制」授权时系统不给，是空的。
        let title: String
        /// 全局 top-left 点坐标（`kCGWindowBounds`）。
        let frame: CGRect
        /// 窗口层级：0 = 普通窗口；菜单栏、Dock、浮窗都不是 0。
        let layer: Int
        /// 能不能被录：`kCGWindowSharingState` 不是 none（SrtFlow 自己的控制浮窗、区域遮罩都是 none）。
        let shareable: Bool
    }

    struct Display: Equatable {
        let id: UInt32
        let name: String
        /// 全局 top-left 点坐标（`CGDisplayBounds`）。
        let frame: CGRect
        let pixelSize: CGSize
        /// 有菜单栏的那块（`CGDisplayIsMain`）。
        let isMain: Bool
    }

    struct Microphone: Equatable {
        let id: String
        let name: String
    }

    /// 比这还小的窗口不列、不挑（工具条、提示框、隐形的辅助窗口）。
    static let minimumWindowSide: CGFloat = 80

    /// 能录的窗口：普通层、能被录、不太小。顺序照旧（传进来的是从前到后）。
    static func recordable(_ windows: [Window]) -> [Window] {
        windows.filter {
            $0.layer == 0 && $0.shareable && $0.frame.width >= minimumWindowSide && $0.frame.height >= minimumWindowSide
        }
    }

    /// 挑一个窗口：全是数字（可带 #）就按窗口编号；否则 App 名一样 > App 名里有 > 标题里有（不分大小写），同一档挑最前面的。
    static func pickWindow(_ query: String, among windows: [Window]) throws -> Window {
        let candidates = recordable(windows)
        let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = wanted.hasPrefix("#") ? String(wanted.dropFirst()) : wanted
        if let number = UInt32(digits) {
            if let match = candidates.first(where: { $0.id == number }) { return match }
            throw AIToolError("There is no window \(number) to record now; get_status screen=true lists the current ones.")
        }
        let lowered = wanted.lowercased()
        let tiers: [(Window) -> Bool] = [
            { $0.app.lowercased() == lowered },
            { $0.app.lowercased().contains(lowered) },
            { !$0.title.isEmpty && $0.title.lowercased().contains(lowered) }
        ]
        for tier in tiers {
            if let match = candidates.first(where: tier) { return match }
        }
        var seen = Set<String>()
        let apps = candidates.map(\.app).filter { seen.insert($0).inserted }.prefix(12)
        throw AIToolError(
            "No window matches \"\(wanted)\". Windows open now belong to: \(apps.isEmpty ? "none" : apps.joined(separator: ", ")). "
                + "get_status screen=true lists them with titles."
        )
    }

    /// 屏幕编号：主屏（有菜单栏的那块）是 1，其余从左到右、同一列从上到下。
    static func numbered(_ displays: [Display]) -> [Display] {
        displays.sorted { a, b in
            if a.isMain != b.isMain { return a.isMain }
            if a.frame.minX != b.frame.minX { return a.frame.minX < b.frame.minX }
            return a.frame.minY < b.frame.minY
        }
    }

    /// 第几块屏幕（nil = 1，主屏）。
    static func pickDisplay(_ number: Int?, among displays: [Display]) throws -> Display {
        let ordered = numbered(displays)
        guard !ordered.isEmpty else { throw AIToolError("SrtFlow found no display to record.") }
        let wanted = number ?? 1
        guard ordered.indices.contains(wanted - 1) else {
            throw AIToolError("There is no display \(wanted); this Mac has \(ordered.count) (get_status screen=true lists them).")
        }
        return ordered[wanted - 1]
    }

    /// 区域：显示器的比例（左上原点、0…1）→ display-local 点坐标（`SCStreamConfiguration.sourceRect` 要的那种）。
    /// 边取整到整点、夹进屏内；任一边不到 `minimumRegionSide`（同手动拖的区域框）就报错，说出它在这块屏上有多大。
    static func localRect(fractions: CGRect, display: Display) throws -> CGRect {
        let size = display.frame.size
        let left = (fractions.minX * size.width).rounded(), top = (fractions.minY * size.height).rounded()
        let right = min((fractions.maxX * size.width).rounded(), size.width)
        let bottom = min((fractions.maxY * size.height).rounded(), size.height)
        let rect = CGRect(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
        guard ScreenRecordingCoordinateMapper.isUsableRegion(rect) else {
            let side = Int(ScreenRecordingCoordinateMapper.minimumRegionSide)
            throw AIToolError(
                "That area is \(Int(rect.width)) × \(Int(rect.height)) points on this display; it must be at least \(side) × \(side)."
            )
        }
        return rect
    }

    /// 麦克风：「default」= 系统默认的那个（认不出默认就第一个）；其余按名字（一样的优先，再是包含的，不分大小写）。
    static func pickMicrophone(_ query: String, among devices: [Microphone], defaultID: String?) throws -> Microphone {
        guard let first = devices.first else { throw AIToolError("This Mac has no microphone; record without one.") }
        let lowered = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered == "default" { return devices.first { $0.id == defaultID } ?? first }
        if let match = devices.first(where: { $0.name.lowercased() == lowered })
            ?? devices.first(where: { $0.name.lowercased().contains(lowered) }) {
            return match
        }
        throw AIToolError("No microphone matches \"\(query)\". This Mac has: \(devices.map(\.name).joined(separator: ", ")).")
    }
}
