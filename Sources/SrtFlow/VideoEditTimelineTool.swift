import Foundation

// MARK: - 时间线的鼠标工具
//
// 管什么：选择（A）/ 分割（B）两种工具的名字、图标、菜单上显示的键。
// 不管什么：按键怎么接（`VideoEditView.handleEvent`）、工具在哪儿生效（块的把手、分割）。
// 从 VideoEditProject.swift 拆出来（那个文件在行数基线里只许降，见 docs/architecture/coding-standards.md）。

/// 时间线的鼠标工具（对齐 CapCut：选择 A / 分割 B）。
enum TimelineTool: String, CaseIterable, Identifiable {
    case select
    case split

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: return "Select"
        case .split: return "Split"
        }
    }

    var icon: String {
        switch self {
        case .select: return "cursorarrow"
        case .split: return "rectangle.split.2x1"
        }
    }

    /// 菜单里展示的单键快捷键。
    var shortcutLabel: String {
        switch self {
        case .select: return "A"
        case .split: return "B"
        }
    }
}
