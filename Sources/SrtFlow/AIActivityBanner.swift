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
        if let question = session.question {
            // 要用户点头的问题不管这一轮是什么状态都摆出来：AI 在等结果时这一轮可能早已「结束」，条不能因此收起来。
            // accessibilityIdentifier：冒烟用辅助功能点按钮（SwiftUI 的按钮没有名字可找；docs/testing/gui-smoke-testing.md 四之八）。
            bar(icon: "questionmark.circle", message: question.text) {
                Button(question.declineTitle) { session.answer(false) }
                    .accessibilityIdentifier("ai-banner-decline")
                Button(question.allowTitle) { session.answer(true) }
                    .accessibilityIdentifier("ai-banner-allow")
                Button("Stop") { session.stop() }
                    .accessibilityIdentifier("ai-banner-stop")
                    .instantHelp("Stop the AI and cancel its exports and subtitle jobs")
            }
        } else {
            statusBar
        }
    }

    @ViewBuilder
    private var statusBar: some View {
        switch session.phase {
        case .idle:
            EmptyView()
        case .working:
            // 要用户动手的时候先说这件事（比如去点「下载」），不然用户只看到「正在剪辑」、一直干等。
            bar(icon: session.hint == nil ? "sparkles" : "hand.point.up.left",
                message: session.hint ?? String(format: L10n("%@ is editing this project…"), clientName)) {
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
                // 平时一行；引导用户动手的那句长，允许折到三行、别被截掉关键的那半句。
                Text(verbatim: message)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
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
