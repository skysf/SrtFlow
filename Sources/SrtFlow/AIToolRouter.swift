import Foundation
import SrtFlowMCPKit

// MARK: - 一次工具调用怎么走
//
// 管什么：从通道上收到的调用 → 查停止、记这一轮 → 排队 → 摆出剪辑页 → 交给对应的工具 → 结果。
// switch 对 `MCPToolName` 是穷举的：清单里加了工具、这里没接，编译不过。
// 不管什么：收发（AIBridgeServer）、工具本身（AI*Tools）。
//
// **排队**：改工程的调用一个接一个做，按到达的顺序。Claude 会在一条消息里并排发几个调用，
// 不排队的话「接在 V1 最后」这种落点就看谁先探完素材，每次结果都不一样。
// 只读、会等很久的（get_job 最多等 30 秒）和取消不排队，免得堵住后面的活、或者取消排在被取消的后面。

@MainActor
final class AIToolRouter {
    static let shared = AIToolRouter()

    private var tail: Task<Void, Never>?

    private init() {}

    func handle(_ request: MCPBridge.Request) async -> JSONValue {
        guard request.bridge == MCPBridge.version else {
            return MCPBridge.textResult(
                "This SrtFlow and its AI helper come from different versions. Ask the user to restart the AI app.",
                isError: true
            )
        }
        guard let tool = MCPToolName(rawValue: request.tool) else {
            return MCPBridge.textResult(
                "This SrtFlow does not have the tool \(request.tool). Ask the user to update SrtFlow.", isError: true
            )
        }
        let session = AISession.shared
        if let refusal = session.refusalAfterStop() { return MCPBridge.textResult(refusal, isError: true) }
        session.noteCall(client: request.client)
        let arguments = AIToolArguments(request.arguments)
        let policy = Policy(tool)
        guard policy.serialized else { return await execute(tool, arguments, policy) }
        let previous = tail
        let work = Task { @MainActor () -> JSONValue in
            await previous?.value
            return await self.execute(tool, arguments, policy)
        }
        tail = Task { _ = await work.value }
        return await work.value
    }

    private func execute(_ tool: MCPToolName, _ arguments: AIToolArguments, _ policy: Policy) async -> JSONValue {
        let project = VideoEditProject.shared
        // 排队期间用户按了停止：排在后面的也不做了。
        if policy.startsRound, AISession.shared.phase == .stopped {
            return MCPBridge.textResult(
                "The user pressed Stop in SrtFlow. Stop calling tools and ask the user what to do next.", isError: true
            )
        }
        do {
            if policy.presentsEditor { try await AIEditorPresenter.prepareEditor(project: project) }
            if policy.startsRound { AISession.shared.beginRoundIfNeeded(project: project) }
            let result = try await run(tool, arguments, project)
            guard result.changedProject else { return result.json }
            AISession.shared.noteChange()
            // 改的是一个从来没存过的工程：马上存下来，之后交给自动保存（见那个函数）。
            return AIProjectTools.saveIfNeverSaved(project, after: result).json
        } catch let error as AIToolError {
            return MCPBridge.textResult(error.message, isError: true)
        } catch {
            return MCPBridge.textResult("SrtFlow could not do that: \(error.localizedDescription)", isError: true)
        }
    }

    /// 改工程的同步工具各包一层 `AIUndoGrouping.step`：一个工具 = 一步撤销（为什么不能靠按事件分组，见那个文件）。
    /// 异步的 add_clips 在它自己那一次 perform 外面包；撤销的「一轮」在 AIProjectTools.undo 里包。
    private func run(_ tool: MCPToolName, _ args: AIToolArguments, _ project: VideoEditProject) async throws -> AIToolResult {
        let undo = project.effectiveUndoManager
        switch tool {
        case .getStatus: return AIProjectTools.status(project)
        case .openFolder: return try await AIProjectTools.openFolder(args, project)
        case .openProject: return try await AIProjectTools.openProject(args, project)
        case .newProject: return try AIProjectTools.newProject(args, project)
        case .saveProject: return try AIProjectTools.saveProject(args, project)
        case .undo: return try AIProjectTools.undo(args, project)
        case .seek: return try AIProjectTools.seek(args, project)
        case .getTimeline: return AITimelineTools.timeline(project)
        case .addClips: return try await AITimelineTools.addClips(args, project)
        case .editClip: return try AIUndoGrouping.step(undo) { try AITimelineTools.editClip(args, project) }
        case .splitClip: return try AIUndoGrouping.step(undo) { try AITimelineTools.split(args, project) }
        case .deleteItems: return try AIUndoGrouping.step(undo) { try AITimelineTools.delete(args, project) }
        case .setTransition: return try AIUndoGrouping.step(undo) { try AITimelineTools.transition(args, project) }
        case .setText: return try AIUndoGrouping.step(undo) { try AIOverlayTools.setText(args, project) }
        case .setFilter: return try AIUndoGrouping.step(undo) { try AIOverlayTools.setFilter(args, project) }
        case .setCanvas: return try AIUndoGrouping.step(undo) { try AIOverlayTools.setCanvas(args, project) }
        case .generateSubtitles: return try await AISubtitleTools.generate(args, project)
        case .translateSubtitles: return try await AISubtitleTools.translate(args, project)
        case .getSubtitles: return try AISubtitleTools.read(args, project)
        case .editSubtitles: return try AIUndoGrouping.step(undo) { try AISubtitleTools.edit(args, project) }
        case .exportVideo: return try await AIExportTools.export(args, project)
        case .getJob: return try await AIExportTools.job(args)
        case .cancelJob: return try AIExportTools.cancel(args)
        }
    }

    /// 每个工具的三件事：排不排队、要不要把剪辑页摆出来、算不算这一轮的改动。
    private struct Policy {
        let serialized: Bool
        let presentsEditor: Bool
        let startsRound: Bool

        init(_ tool: MCPToolName) {
            switch tool {
            case .getStatus, .getJob, .cancelJob:
                (serialized, presentsEditor, startsRound) = (false, false, false)
            case .openFolder, .getTimeline, .getSubtitles, .saveProject, .exportVideo:
                (serialized, presentsEditor, startsRound) = (true, false, false)
            case .seek:
                (serialized, presentsEditor, startsRound) = (true, true, false)
            case .openProject, .newProject, .undo, .addClips, .editClip, .splitClip, .deleteItems,
                 .setTransition, .setText, .setFilter, .setCanvas, .generateSubtitles, .translateSubtitles,
                 .editSubtitles:
                (serialized, presentsEditor, startsRound) = (true, true, true)
            }
        }
    }
}
