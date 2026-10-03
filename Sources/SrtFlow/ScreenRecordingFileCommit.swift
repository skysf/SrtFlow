import Foundation
import SrtFlowCore

// MARK: - 录完把临时文件提交到最终位置（journal 协议）
//
// 管什么：主文件、麦克风 sidecar 从隐藏的 `.partial` 临时文件变成用户看得见的文件 —— 每次 rename 之前先把意向
// （阶段 + 最终路径）持久化，之后再推进到「已提交」（docs/architecture/screen-recording-lifecycle.md「提交 journal」）。
// 不管什么：提交之前的验证（协调者先 probe 临时文件）、提交之后的回读和入轨（协调者）、崩溃恢复那一份提交（`commitRecovered`）。
// 2026-10-03 从 ScreenRecordingCoordinator.swift 搬出来（那个文件超过 600 行，只许降），同时加了 AI 起的录制「从不覆盖」。

@available(macOS 15.0, *)
struct ScreenRecordingFileCommit {
    /// 提交完的样子。
    struct Committed {
        var manifest: ScreenRecordingManifest
        /// 主文件**实际**落在哪：手动的就是用户选的位置；AI 起的撞上已有文件时避让到「名字 2」。
        var mainURL: URL
        /// 麦克风 sidecar 实际落在哪（没录、或没通过校验时 nil）。
        var microphoneURL: URL?
    }

    let store: ScreenRecordingManifestStore
    let manager = FileManager.default

    /// journal 提交协议：persist 意向 → rename → persist 已提交。
    ///
    /// - Parameter commitMicrophone: sidecar 是否**已通过校验**。false 时不提交它 —— 零采样、probe 失败、writer 已知故障却仍残留的
    ///   `.m4a` 一律不能变成用户可见的损坏文件（复审四 P1-2）。
    /// - Parameter replacesExistingOutput: 主文件撞上已有文件时能不能替换。手动的在保存面板里点过「替换」；AI 起的从不覆盖：
    ///   避让后的目标**先写进 manifest、持久化，然后才动文件**（同麦克风那一路，复审二 P1-3）。
    /// - Parameter persisted: 每次持久化成功之后交出当时的 manifest（协调者据此跟着更新自己手里那份）。
    func commit(
        request: ScreenRecordingRequest, manifest start: ScreenRecordingManifest,
        commitMicrophone: Bool, replacesExistingOutput: Bool,
        persisted: (ScreenRecordingManifest) -> Void
    ) throws -> Committed {
        var manifest = start
        func persist(_ stage: ScreenRecordingManifest.CommitStage) throws {
            manifest.stage = stage
            try store.persist(manifest)          // ← 栅栏：成功返回才允许 rename
            persisted(manifest)
        }

        // 临时文件必须在。走到这里它已经被 probe 验证过了；不在就是异常，
        // **不能带着「已提交」的 stage 往下走** —— 那会让最终路径上原有的
        // 旧文件被当成本次录制导入（复审 P1-2）。
        let mainTemp = request.temporaryURL(for: .main)
        guard manager.fileExists(atPath: mainTemp.path) else {
            throw ScreenRecordingError.writerFailed(
                message: L10n("The recording file disappeared before it could be saved.")
            )
        }

        var mainURL = request.outputURL
        if !replacesExistingOutput, manager.fileExists(atPath: mainURL.path) {
            mainURL = ScreenRecordingFileNaming.availableURL(
                like: mainURL, isTaken: { manager.fileExists(atPath: $0.path) }
            )
            manifest = manifest.retargetingMain(to: mainURL.path)
        }
        try persist(.committingMain)
        if manager.fileExists(atPath: mainURL.path) {
            // 只有手动的会走到这里：主文件的覆盖是用户在 Save 面板里明确确认过的。
            _ = try manager.replaceItemAt(mainURL, withItemAt: mainTemp)
        } else {
            try manager.moveItem(at: mainTemp, to: mainURL)
        }
        try persist(.mainCommitted)

        guard request.microphone.isEnabled, commitMicrophone else {
            // 不提交 sidecar：停在 mainCommitted 是对现场的准确描述。
            // 无效的临时文件精确删掉，别留成孤儿。
            if request.microphone.isEnabled {
                try? manager.removeItem(at: request.temporaryURL(for: .microphone))
            }
            return Committed(manifest: manifest, mainURL: mainURL, microphoneURL: nil)
        }
        let micTemp = request.temporaryURL(for: .microphone)
        guard manager.fileExists(atPath: micTemp.path) else {
            // 开了麦克风却没有 sidecar 文件：**不能推进到 allCommitted**。
            // 推进了就等于宣称两个 rename 都做完了，恢复时会照着 micFinalPath
            // 去认一个根本不存在（或不相干）的文件（复审二 P1-8）。
            // 停在 mainCommitted 是准确的描述：主文件提交了，sidecar 没有。
            return Committed(manifest: manifest, mainURL: mainURL, microphoneURL: nil)
        }

        // **先冻结最终目标、写进 manifest、持久化，然后才 rename。**
        // 顺序反了就是 journal 身份被破坏（复审二 P1-3）。
        let target = ScreenRecordingFileNaming.availableURL(
            like: request.microphoneURL,
            isTaken: { manager.fileExists(atPath: $0.path) }
        )
        manifest = manifest.retargetingMicrophone(to: target.path)
        try persist(.committingMicrophone)
        try manager.moveItem(at: micTemp, to: target)
        try persist(.allCommitted)
        return Committed(manifest: manifest, mainURL: mainURL, microphoneURL: target)
    }
}
