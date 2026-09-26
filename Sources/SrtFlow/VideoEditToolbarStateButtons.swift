import AppKit
import SwiftUI

// MARK: - 工具栏上「能不能点」看别处状态的按钮
//
// 管什么：两组按钮能不能点 —— 看选择的（删除、分离声音），看撤销栈的（撤销、重做）。各自只读自己要的
// 那一份。不管什么：按了做什么（工程的 `deleteSelected` / `detachAudio`、窗口的撤销栈），工具栏上别的
// 按钮（还在根视图里），看播放头的那几个（`.disabled(followingPlayhead:)`）。
//
// 为什么单拎出来（docs/architecture/preview-perf-ratchet.md 第十三节）：工程是 `@Observable`，视图读了
// 哪个属性就只在它变时重算。这几个按钮要读的东西写在根视图里，点选一段（只改了 `selection`）就把整个
// 编辑器（工具栏、检查器、素材库、时间线……）叫醒重算一遍；放在这儿，叫醒的只有这两个按钮。

/// 垃圾桶 + 分离声音。body 直接给出两个按钮、不包容器：它们和以前一样是工具栏那一排的两个孩子。
struct SelectionToolbarButtons: View {
    let project: VideoEditProject

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        ToolbarIcon(icon: "trash", help: "Delete the selection", shortcut: .plain("⌫")) {
            project.deleteSelected()
        }
        // 判据和 ⌫ 那道守卫是**同一个**表达式。少一类，选中标记时垃圾桶
        // 就是灰的，而键盘删得掉 —— 同一个动作两个入口给出两种答案。
        .disabled(project.selection.isEmpty)
        ToolbarIcon(icon: "waveform.badge.minus", help: "Detach the audio onto its own track") {
            if let id = project.selectedClip?.id { project.detachAudio(from: id) }
        }
        .disabled(!canDetach)
    }

    private var canDetach: Bool {
        guard let clip = project.selectedClip else { return false }
        return !clip.isAudioOnly && clip.hasAudio && !clip.isMuted
    }
}

/// 撤销 / 重做。能不能点看窗口的撤销栈 —— `NSUndoManager` 不可观察，所以两路叫醒：
/// - 撤销栈多半和 `state` 一起变（`perform`、撤销 / 重做、换工程清空撤销栈都会写它）：body 读一下
///   `state`，这些时候跟着重算。
/// - 连续修改（拖滑杆、拖块、裁切）是先一路写 `state`、**松手才登记**撤销，那一下 `state` 不变 ——
///   靠撤销栈自己的通知（一组关上了 / 撤销了 / 重做了）补上。以前这一下靠的是两秒后自动保存写
///   `hasUnsavedChanges` 把整个根视图顺带刷新，换 Observation 之后根视图不读它了。
///
/// **别听 `NSUndoManagerCheckpoint`**：`canRedo` 自己就会发它，听了就是一个死循环。
struct UndoRedoToolbarButtons: View {
    let project: VideoEditProject
    @Environment(\.undoManager) private var undoManager
    /// 撤销栈的通知来一次加一：只为让 body 重算、重新问一遍 `canUndo` / `canRedo`。
    @State private var stackChanges = 0

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        let _ = (project.state, stackChanges)
        HStack(spacing: 10) {
            ToolbarIcon(icon: "arrow.uturn.backward", help: "Undo") {
                undoManager?.undo()
            }
            .disabled(!(undoManager?.canUndo ?? false))
            ToolbarIcon(icon: "arrow.uturn.forward", help: "Redo") {
                undoManager?.redo()
            }
            .disabled(!(undoManager?.canRedo ?? false))
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidCloseUndoGroup)) { _ in stackChanges += 1 }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidUndoChange)) { _ in stackChanges += 1 }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidRedoChange)) { _ in stackChanges += 1 }
    }
}
