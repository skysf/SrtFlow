import SwiftUI

/// 编辑器里预览左边那一栏：常驻的转场库。
///
/// 和检查器里那个入口是两个场景，两处都留着：检查器那个必须先选中片段才出
/// 现，是「对着选中这一段改」；这一栏常驻，不选中也能看见 12 种转场长什么
/// 样，点一下就套到当前接缝上，是「浏览并套用」。
///
/// 只长在「视频剪辑」这一栏的上半区（与预览、检查器同高），时间线仍然通栏
/// —— 和参照的剪映布局一致。
struct TransitionLibraryPanel: View {
    @ObservedObject var project: VideoEditProject
    /// 必须直接订阅时钟：没有选中片段时目标接缝是「播放头最近的那条」，
    /// 只观察 project 的话播放头动了这栏不重算 —— 小样和高亮会停在旧接缝上。
    @ObservedObject var clock: PlayerClock
    // 这个视图用 L10n(...) 拼字符串，不是纯 LocalizedStringKey，光靠环境
    // locale 变化不会重新求值 body，所以要显式观察语言选择。
    @ObservedObject private var languageStore = AppLanguageStore.shared

    private var target: TransitionLibraryTarget { project.transitionLibraryTarget }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let note = unavailableNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            // 卡片**照常显示**（没有接缝时小样退回双色渐变占位）：这一栏的第一
            // 用途是「看看有哪些转场、长什么样」，那件事不需要接缝。不能点的
            // 时候整块压暗并拦掉点击，而不是整块藏起来。
            TransitionPickerGrid(
                selection: seam.map { $0.outgoing.transitionAfter },
                outgoingClip: seam?.outgoing,
                incomingClip: seam?.incoming,
                onPick: { project.applyTransitionFromLibrary($0) }
            )
            .disabled(seam == nil)
            .opacity(seam == nil ? 0.45 : 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 5) {
            Label("Transitions", systemImage: "square.filled.and.line.vertical.and.square")
                .font(.callout)
                .fontWeight(.medium)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .instantHelp("Click a card to put that transition on the current seam")
    }

    private var seam: TransitionSeam? {
        if case .seam(let seam) = target { return seam }
        return nil
    }

    private var unavailableNote: LocalizedStringKey? {
        switch target {
        case .seam: return nil
        case .noSeam: return "Add a second clip to the main track to put a transition between them."
        case .multipleSelection: return "Select just one clip — a transition goes on one seam at a time."
        }
    }
}
