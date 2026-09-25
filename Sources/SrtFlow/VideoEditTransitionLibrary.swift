import SwiftUI

/// 编辑器里预览左边那一栏：常驻的转场库。
///
/// 和检查器里那个入口是两个场景，两处都留着：检查器那个必须先选中片段才出
/// 现，是「对着选中这一段改」；这一栏常驻，不选中也能看见 12 种转场长什么
/// 样，点一下就套到当前接缝上，是「浏览并套用」。
///
/// 只长在「视频剪辑」这一栏的上半区（与预览、检查器同高），时间线仍然通栏
/// —— 和参照的剪映布局一致。
///
/// **自己不画标题行**：这一栏顶上那个「转场 / 滤镜」分段切换就是标题
///（见 `VideoEditLibraryColumn.swift`），再画一行就是一栏里两行标题。
struct TransitionLibraryPanel: View {
    @ObservedObject var project: VideoEditProject
    /// 没有选中片段时目标接缝是「播放头最近的那条」—— 这里的播放头是**停稳了的**那个
    /// （`clock.atRest`，不是时钟本身）：播放中、拖播放头的过程中这一栏一动不动，停稳了刷新一次
    /// （2026-09-25 用户拍板）。点卡片套到的也是这里显示的那条缝，看到哪条改哪条。
    @ObservedObject var playhead: PacedPlayhead
    // 这个视图用 L10n(...) 拼字符串，不是纯 LocalizedStringKey，光靠环境
    // locale 变化不会重新求值 body，所以要显式观察语言选择。
    @ObservedObject private var languageStore = AppLanguageStore.shared

    private var target: TransitionLibraryTarget { project.transitionLibraryTarget(at: playhead.time) }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        VStack(alignment: .leading, spacing: 0) {
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
                onPick: { project.applyTransitionFromLibrary($0, at: playhead.time) },
                isEnabled: { isEnabled($0) }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var seam: TransitionSeam? {
        if case .seam(let seam) = target { return seam }
        return nil
    }

    /// 这一种在当前这条缝上做不做得出来。没有缝时全都不能点。
    private func isEnabled(_ kind: ClipTransition) -> Bool {
        guard let seam else { return false }
        if case .available = TimelineState.transitionCapacity(
            outgoing: seam.outgoing, incoming: seam.incoming, kind: kind
        ) { return true }
        return false
    }

    private var unavailableNote: LocalizedStringKey? {
        switch target {
        case .noSeam: return "Add a second clip to the main track to put a transition between them."
        case .multipleSelection: return "Select just one clip — a transition goes on one seam at a time."
        case .notAdjacent: return "No continuous footage here — a transition needs two clips that touch."
        case .seam where !isEnabled(.crossFade):
            // 缝是成立的，只是片段太短、叠化这类放不下 —— 压黑是两段各自
            // 的渐变，不需要交叠，所以它是亮的。（余料不够已经改成定格补足，
            // 不再是灰掉的理由，2026-09-23。）
            return "These clips are too short to blend, so only Black fade works here."
        case .seam: return nil
        }
    }
}
