import SwiftUI

// MARK: - 顶上那条「AI 正在剪辑」
//
// 管什么：AI 在剪的时候显示是谁、给一个停止按钮；这一轮结束或被停下之后，给「撤销这一轮」和关掉。
// 只订阅 `AISession`（一个小对象），不读工程 —— 挂在主窗口上，工程每改一下它都不用重算
// （docs/architecture/preview-perf-ratchet.md 第十三节）。
// 不管什么：这一轮怎么算、停止之后拒绝多久（AISession）。

struct AIActivityBanner: View {
    @ObservedObject private var session = AISession.shared

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        switch session.phase {
        case .idle:
            EmptyView()
        case .working:
            bar(icon: "sparkles", message: String(format: L10n("%@ is editing this project…"), clientName)) {
                Button("Stop") { session.stop() }
                    .instantHelp("Stop the AI and cancel its exports and subtitle jobs")
            }
        case .finished:
            bar(icon: "checkmark.circle", message: String(format: L10n("%@ made %d changes."), clientName, session.changeCount)) {
                undoRoundButton
                closeButton
            }
        case .stopped:
            bar(icon: "stop.circle", message: L10n("You stopped the AI.")) {
                if session.canUndoRound { undoRoundButton }
                closeButton
            }
        }
    }

    private var clientName: String {
        session.clientName.isEmpty ? L10n("The AI") : session.clientName
    }

    private var undoRoundButton: some View {
        Button("Undo This Round") { session.undoRound(project: VideoEditProject.shared) }
            .disabled(!session.canUndoRound)
            .instantHelp("Put the project back to how it was before the AI started this round")
    }

    private var closeButton: some View {
        Button {
            session.dismiss()
        } label: {
            Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .instantHelp("Hide this bar")
    }

    private func bar<Buttons: View>(
        icon: String, message: String, @ViewBuilder buttons: () -> Buttons
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(.tint)
                Text(verbatim: message)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                buttons()
                    .controlSize(.small)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.tint.opacity(0.12))
            Divider()
        }
    }
}
