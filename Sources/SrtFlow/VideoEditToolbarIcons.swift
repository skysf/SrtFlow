import SwiftUI

// MARK: - 编辑器工具栏上的两种小按钮
//
// 管什么：一个图标按钮（`ToolbarIcon`）和一个开关型图标按钮（`ToolbarToggle`）长什么样、
// 提示和快捷键怎么挂。不管什么：按了做什么（调用方给闭包）。
// 从 VideoEditView.swift 拆出来（那个文件登记过超标、只许降）。

struct ToolbarIcon: View {
    let icon: String
    let help: LocalizedStringKey
    /// 快捷键：显示在提示右边的键帽，能挂等价符的顺手挂上。
    let shortcut: HelpShortcut?
    /// 这个动作正在后台跑：图标原地换成转圈。
    let isBusy: Bool
    let action: () -> Void

    init(
        icon: String, help: LocalizedStringKey, shortcut: HelpShortcut? = nil,
        isBusy: Bool = false, action: @escaping () -> Void
    ) {
        self.icon = icon
        self.help = help
        self.shortcut = shortcut
        self.isBusy = isBusy
        self.action = action
    }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        Button(action: action) {
            // 忙的时候原地换成转圈。**尺寸写在外层、和图标完全一样** ——
            // 写在分支里的话两种内容的固有尺寸不同，工具栏会在转圈出现和消失时
            // 各跳一下。
            Group {
                if isBusy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: icon)
                }
            }
            .frame(width: 20, height: 18)
        }
        .buttonStyle(.borderless)
        .instantHelp(help, shortcut: shortcut)
    }
}

struct ToolbarToggle: View {
    let icon: String
    let help: LocalizedStringKey
    var shortcut: HelpShortcut?
    @Binding var isOn: Bool

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        Toggle(isOn: $isOn) {
            Image(systemName: icon)
                .frame(width: 20, height: 18)
        }
        .toggleStyle(.button)
        .buttonStyle(.borderless)
        .tint(.teal)
        .instantHelp(help, shortcut: shortcut)
    }
}

// MARK: - 形状叠层

/// 画面上的形状：按归一化坐标画在预览框里，选中可拖动。

// MARK: - 工具栏右边那组开关

/// 磁吸 / 吸附 / 联动 / 播放跟随四个开关。单拎成小视图：拨一个只重算这一小块，不叫醒整个编辑器；
/// 四个都记在 `EditorToggles`（默认值也在那儿），这里只是把它们摆出来。磁吸跟着工程走（`state.mainMagnet`），拨它只走 `setMagnet`。
struct TimelineToolbarToggles: View {
    @Bindable var project: VideoEditProject

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        ToolbarToggle(
            icon: "arrow.right.and.line.vertical.and.arrow.left", help: "Main track magnet (auto close gaps)",
            isOn: Binding(get: { project.magnetEnabled }, set: { project.setMagnet($0) })
        )
        ToolbarToggle(icon: "arrow.down.to.line.compact", help: "Auto snapping while dragging", isOn: $project.snappingEnabled)
        ToolbarToggle(icon: "link", help: "Linkage: what sits on a V1 clip moves and deletes with it", isOn: $project.linkageEnabled)
        // 播放跟随默认关（2026-10-01 用户拍板）：开着时播放头快出视口就翻一页，关着时轨道区域停在哪就停在哪。
        ToolbarToggle(
            icon: "arrow.right.to.line", help: "Follow the playhead during playback (page the timeline when it reaches the edge)",
            isOn: $project.timelineFollowsPlayhead
        )
    }
}
