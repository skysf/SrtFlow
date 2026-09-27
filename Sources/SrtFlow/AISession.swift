import Combine
import Foundation
import SrtFlowCore

// MARK: - AI 这一轮：谁在剪、改了几处、用户按了停止没有
//
// 管什么：横幅上显示的那点状态（`@Published`，只有横幅订阅），「撤销这一轮」要用的快照，
// 停止之后拒绝调用的那段时间。产品口径见 docs/plans/2026-09-27-mcp.md 第 9、10 条，
// 长期约束见 docs/architecture/ai-control-mcp.md。
// 不管什么：工具怎么做（AI*Tools）、调用怎么排队（AIToolRouter）。
//
// **「一轮」按时间划分**：服务器看不到对话，只能这么判断 —— AI 开始改工程时开一轮，
// 连续 `roundIdleSeconds` 秒没有新调用就算这一轮结束（横幅换成「改了 N 处 · 撤销这一轮」）。
//
// **停止**：用户按下之后，AI 接下来的调用一律回「用户按了停止」，直到它安静下来
// `stopQuietSeconds` 秒 —— AI 收到拒绝会停下来问用户，用户再说话时已经过了这段时间，
// 新的一轮照常开。在跑的导出 / 生成字幕 / 翻译当场取消。

@MainActor
final class AISession: ObservableObject {
    static let shared = AISession()

    enum Phase: Equatable {
        case idle
        case working
        case finished
        case stopped
    }

    @Published private(set) var phase: Phase = .idle
    /// 横幅上的客户端名字（「Claude」「Codex」……）。
    @Published private(set) var clientName = ""
    /// 这一轮改了几处（每个改动工程的调用算一处）。
    @Published private(set) var changeCount = 0
    /// 要用户动手的那一句（比如「在弹出的窗口里点下载」）。有它的时候提示条先显示它。
    @Published private(set) var hint: String?

    static let roundIdleSeconds = 30.0
    static let stopQuietSeconds = 10.0

    private var snapshot: TimelineState?
    /// 快照属于哪个工程（换了工程，快照就没意义了）。
    private var snapshotGeneration: Int?
    private var lastCallAt = Date.distantPast
    private var idleTask: Task<Void, Never>?

    private init() {}

    var canUndoRound: Bool {
        snapshot != nil && changeCount > 0
            && snapshotGeneration == VideoEditProject.shared.documentGeneration
    }

    // MARK: 调用进来

    /// 用户按了停止、AI 还在连续调用：回这一句。安静够久了就放行（新的一轮）。
    func refusalAfterStop() -> String? {
        guard phase == .stopped else { return nil }
        let quiet = Date().timeIntervalSince(lastCallAt)
        lastCallAt = Date()
        if quiet < Self.stopQuietSeconds {
            return "The user pressed Stop in SrtFlow. Stop calling tools and ask the user what to do next."
        }
        phase = .idle
        return nil
    }

    func noteCall(client: String?) {
        lastCallAt = Date()
        if let client, !client.isEmpty { clientName = Self.displayName(for: client) }
        if phase == .working { scheduleRoundEnd() }
    }

    /// 要改工程之前调：没在一轮里就开一轮，先把此刻的时间线存下来（「撤销这一轮」退回到这里）。
    func beginRoundIfNeeded(project: VideoEditProject) {
        guard phase != .working else { return }
        snapshot = project.state
        snapshotGeneration = project.documentGeneration
        changeCount = 0
        phase = .working
        scheduleRoundEnd()
    }

    func noteChange() {
        changeCount += 1
    }

    func setHint(_ text: String?) {
        if hint != text { hint = text }
    }

    /// AI 开了 / 建了另一个工程：快照换成新工程此刻的样子，「撤销这一轮」只退这个工程上的改动。
    func rebase(project: VideoEditProject) {
        snapshot = project.state
        snapshotGeneration = project.documentGeneration
        changeCount = 0
    }

    // MARK: 用户的按钮

    func stop() {
        phase = .stopped
        lastCallAt = Date()
        idleTask?.cancel()
        AIJobs.shared.cancelAll()
    }

    /// 把工程退回这一轮开始之前（一步，可以再 ⌘Z 回来）。
    @discardableResult
    func undoRound(project: VideoEditProject) -> Bool {
        guard canUndoRound, let snapshot else { return false }
        project.perform { $0 = snapshot }
        changeCount = 0
        if phase == .finished { phase = .idle }
        return true
    }

    func dismiss() {
        guard phase != .working else { return }
        phase = .idle
    }

    // MARK: 私有

    private func scheduleRoundEnd() {
        idleTask?.cancel()
        idleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.roundIdleSeconds * 1_000_000_000))
            guard let self, !Task.isCancelled, self.phase == .working else { return }
            self.phase = self.changeCount > 0 ? .finished : .idle
        }
    }

    /// 客户端报的名字多半是内部代号，换成人认得的。
    static func displayName(for client: String) -> String {
        let lowered = client.lowercased()
        if lowered.contains("claude-code") || lowered.contains("claude code") { return "Claude Code" }
        if lowered.contains("claude") { return "Claude" }
        if lowered.contains("codex") { return "Codex" }
        if lowered.contains("cursor") { return "Cursor" }
        if lowered.contains("chatgpt") || lowered.contains("openai") { return "ChatGPT" }
        return client
    }
}
