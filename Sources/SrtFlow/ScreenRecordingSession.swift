import Foundation
import SrtFlowCore

// MARK: - 一次录制是谁起的、起它的人要什么
//
// 管什么：手动录（Record Screen 按钮 → 设置页）和 AI 起的录（record_screen）只在这几处不同 —— 设置页弹不弹、倒数几秒、
// 残缺的结果问不问、撞上已有文件能不能替换、浮窗放哪、录完入不入轨、入轨那一下怎么提交、结局告诉谁。
// 协调者只问这一份，不按「是不是 AI」写两套流程（同一条规则只有一处实现）。
// 不管什么：状态机（`ScreenRecordingState`）、怎么录（`ScreenCaptureEngine` / `ScreenRecordingWriter`）、
// AI 那一侧的参数和任务（`AIScreenRecording*`）。产品口径见 docs/plans/2026-10-03-screen-recording-mcp.md，
// 长期约束见 docs/architecture/screen-recording-lifecycle.md「AI 起的会话」。

@available(macOS 15.0, *)
struct ScreenRecordingSession {
    enum Driver: Equatable {
        case user
        case ai
    }

    var driver: Driver = .user
    /// 开录前倒数几秒：手动固定 3；AI 一边录一边操作电脑时给 0。
    var countdownSeconds = 3
    /// 停下来之后放上时间线；false = 只留文件（record_screen 的 add_to_timeline=false）。
    var addsToTimeline = true
    /// 主文件撞上已有文件时能不能替换：手动的在保存面板里点过「替换」才会走到这一步；AI 起的**从不覆盖**，
    /// 提交时撞上了就避让到「名字 2」（MCP 方案第 34 条）。
    var replacesExistingOutput = true
    /// 控制浮窗放哪：手动的在顶部正中；AI 起的放主屏左下角 —— 浮窗在截屏里看不见，AI 一边截屏一边操作时
    /// 顶部正中正好压在浏览器的地址栏上。
    var panelPlacement: ScreenRecordingControlPanel.Placement = .topCenter
    /// 入轨那一下怎么提交、要不要选中。
    var landing = ScreenRecordingLanding.manual
    /// 结局告诉谁（AI 的任务）。手动的没有。
    weak var observer: ScreenRecordingObserver?

    static var user: ScreenRecordingSession { ScreenRecordingSession() }

    /// 设置页、残缺结果的处置框、系统的选择窗口、激活 App 去拖区域框：**只有手动的会话**才会。
    /// AI 起的从不弹（用户 2026-10-03：「授权了以后，日后就不要再自己弹了」），残缺的照样落地、原因写进结果。
    var asksTheUser: Bool { driver == .user }
}

/// 入轨那一下（一次 `perform`）怎么提交、提交完要不要选中新片段并把播放头挪过去。
///
/// AI 起的录制在用户按停止、duration 到点时落地 —— 不是用户事件，也不在 AI 的调用里：**必须**包一层
/// `AIUndoGrouping.step`，不然它的登记落进按事件自动开、却永远关不上的那一组，之后 AI 每一步都嵌进去、撤一步全退
/// （docs/architecture/ai-control-mcp.md 第四节第 1 条）。后台模式不选中、不挪播放头（同 `AIEditorPresenter.reveal`）。
@available(macOS 15.0, *)
struct ScreenRecordingLanding {
    var commit: (() -> Void) -> Void = { $0() }
    var reveals = true

    static var manual: ScreenRecordingLanding { ScreenRecordingLanding() }
}

/// 一次录制的结局（交给 `ScreenRecordingObserver`）。
@available(macOS 15.0, *)
enum ScreenRecordingOutcome {
    /// 放上了时间线：主视频那一段在前，麦克风那一段（有的话）在后。结果可能是残缺的（`isPartial` + 原因）。
    case added(ScreenRecordingResult, clipIDs: [UUID])
    /// 只留了文件。
    case savedOnly(ScreenRecordingResult)
    /// 残缺，等用户在 SrtFlow 的框里决定（只有手动的会话会这样；AI 可以 record_screen action=resolve）。
    case awaitingDecision(ScreenRecordingResult)
    /// 还没开录就停了 / 取消了：什么都没录。
    case nothingRecorded
    case failed(String)
}

/// 想知道一次录制什么时候真开始、最后怎么样了的（AI 的任务）。
@available(macOS 15.0, *)
@MainActor
protocol ScreenRecordingObserver: AnyObject {
    /// 倒数完、capture 起来之后。
    func recordingStarted(session: UUID)
    func recordingEnded(_ outcome: ScreenRecordingOutcome)
}
