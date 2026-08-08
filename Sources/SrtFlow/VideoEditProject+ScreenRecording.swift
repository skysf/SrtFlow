import AVFoundation
import Foundation
import SrtFlowCore

/// 录屏结果入轨：**一次 `perform`、一次 dirty、一次 undo**（计划 §10.2）。
@available(macOS 15.0, *)
extension VideoEditProject {

    /// 供 coordinator 快照的当前工程代号。
    var currentDocumentGeneration: Int { documentGeneration }

    /// 开始录制时工程是否已有视觉素材（画布自动套用的前置条件之一）。
    var hasVisualMedia: Bool {
        !state.mainClips.isEmpty || state.overlayTracks.contains { !$0.clips.isEmpty }
    }

    /// 把一次录制导入时间线。
    ///
    /// 计划 §10.2 的八条全部在这一个 `perform` 里完成：
    /// 主视频进主轨末尾 → 磁吸后**重读实际起点** → 麦克风单独新轨且起点对齐
    /// → 同一 linkGroup → 画布四条件都成立才自动设 → 选中并把播放头移到起点。
    /// - Returns: 入轨事务是否**成功提交**。false 时调用方必须保留 manifest ——
    ///   文件已经是用户的了，但还没进时间线，下次启动要能补问（复审 P1-8）。
    @discardableResult
    func importScreenRecording(
        _ result: ScreenRecordingResult, request: ScreenRecordingRequest
    ) async -> Bool {
        // 导入前先 probe，拿真实 duration / dimensions；probe 与 identity 都过了
        // 才允许改 timeline / canvas / selection / dirty（计划 §10.1-3）。
        guard let videoInfo = await ScreenRecordingProbe.info(result.mainURL) else {
            notice = L10n("The recording couldn’t be read, so it wasn’t added to the timeline.")
            return false
        }
        var micDuration: Double?
        var microphoneUnreadable = false
        if let micURL = result.microphoneURL,
           FileManager.default.fileExists(atPath: micURL.path) {
            // **必须走 audioDuration，不能走 info()** —— 后者要求视频轨，
            // 对纯音频 sidecar 永远返回 nil（复审二 P1-1）。
            micDuration = await ScreenRecordingProbe.audioDuration(micURL)
            // 读不出来就少一条轨 —— 必须说，不能静默（复审 P1-8）。
            microphoneUnreadable = micDuration == nil
        }
        // 跨 await 回来再查一次工程身份。
        guard isCurrentGeneration(request.documentGeneration) else { return false }

        // 画布自动套用的四个条件（计划 §6.3 + §20）：
        // 开始时空、结束时仍空、比例值未变、canvasEditGeneration 未变。
        let canvasUntouched = state.canvasRatio.rawValue == request.canvasRatioSnapshot
            && canvasEditGeneration == request.canvasEditGeneration
        let shouldSetCanvas = !request.projectHadVisualMedia
            && !hasVisualMedia
            && canvasUntouched

        let linkGroup = UUID()
        let recordedRatio = CanvasRatio.closest(to: videoInfo.displaySize)

        perform { state in
            var clip = EditClip(
                sourceURL: result.mainURL,
                sourceDuration: videoInfo.duration,
                timelineStart: state.mainClips.map(\.timelineEnd).max() ?? 0,
                info: videoInfo
            )
            clip.linkGroup = linkGroup
            state.mainClips.append(clip)
            // 磁吸开着就走既有 pack 规则。
            if self.magnetEnabled { state.packMain() }

            // **pack 之后重新读实际起点** —— 不能沿用 pack 前的估算值（计划 §10.2-3）。
            let actualStart = state.mainClips.last(where: { $0.linkGroup == linkGroup })?
                .timelineStart ?? 0

            if let micURL = result.microphoneURL, let micDuration,
               FileManager.default.fileExists(atPath: micURL.path) {
                // 麦克风**始终新建一条轨**，不与普通导入音频复用（计划 §10.2-4）。
                // `isAudioOnly` + `audioAssetDuration` 缺一不可 —— 与既有的
                // 音频导入路径（`VideoEditProject.addAudio`）保持一致，
                // 少了它们这条块会被当成视频块参与预览与导出（复审二 P1-1）。
                var micClip = EditClip(
                    sourceURL: micURL,
                    isAudioOnly: true,
                    sourceDuration: micDuration,
                    timelineStart: actualStart,
                    audioAssetDuration: micDuration
                )
                micClip.linkGroup = linkGroup
                state.audioTracks.append(EditLane(clips: [micClip]))
            }

            if shouldSetCanvas, let recordedRatio {
                state.canvasRatio = recordedRatio
            }
        }

        // 选中新片段并把播放头移到起点，方便立刻检查（计划 §10.2-7）。
        if let imported = state.allClips.first(where: { $0.linkGroup == linkGroup }) {
            selectedClipIDs = [imported.id]
            clock.seek(to: imported.timelineStart, precise: true)
        }
        if microphoneUnreadable {
            notice = L10n("The screen recording was added, but the microphone track couldn’t be read and was left out.")
        } else if result.isPartial {
            notice = result.partialReason ?? L10n("A partial recording was added to the timeline.")
        } else {
            notice = nil
        }
        return true
    }

    /// 崩溃恢复的录制：主轨 + 麦克风轨。没有 request 快照可比对，所以不动画布。
    ///
    /// - Parameter documentGeneration: 呈现恢复提示那一刻的工程身份。
    ///   跨 `await` 回来必须比对 —— 用户可能在弹窗开着的时候切了工程，
    ///   素材进错工程就是脏数据（复审二 P1-6）。
    /// - Returns: 是否成功入轨（同上，false 时不许清账）。
    @discardableResult
    func importRecoveredRecording(
        _ result: ScreenRecordingResult, documentGeneration: Int, sessionID: UUID
    ) async -> Bool {
        // **幂等**：用 manifest 的 sessionID 当 linkGroup，重复恢复能认出来。
        // 崩溃窗口（入轨已提交、账本还没清）下次启动会再提示一次，
        // 这道检查保证不会重复入轨（复审四 P1-4）。
        if state.allClips.contains(where: { $0.linkGroup == sessionID }) {
            notice = L10n("That recording is already in the timeline.")
            return true
        }
        guard let info = await ScreenRecordingProbe.info(result.mainURL) else {
            notice = L10n("That recovered recording couldn’t be read.")
            return false
        }
        // 恢复出来的麦克风 sidecar 同样要进轨 —— 早先这里完全忽略了它，
        // 崩溃恢复必定丢掉旁白（复审二 P1-1）。
        var micDuration: Double?
        if let micURL = result.microphoneURL,
           FileManager.default.fileExists(atPath: micURL.path) {
            micDuration = await ScreenRecordingProbe.audioDuration(micURL)
        }
        guard isCurrentGeneration(documentGeneration) else { return false }

        let linkGroup = sessionID
        perform { state in
            var clip = EditClip(
                sourceURL: result.mainURL,
                sourceDuration: info.duration,
                timelineStart: state.mainClips.map(\.timelineEnd).max() ?? 0,
                info: info
            )
            clip.linkGroup = linkGroup
            state.mainClips.append(clip)
            if self.magnetEnabled { state.packMain() }

            let actualStart = state.mainClips.last(where: { $0.linkGroup == linkGroup })?
                .timelineStart ?? 0
            if let micURL = result.microphoneURL, let micDuration {
                var micClip = EditClip(
                    sourceURL: micURL,
                    isAudioOnly: true,
                    sourceDuration: micDuration,
                    timelineStart: actualStart,
                    audioAssetDuration: micDuration
                )
                micClip.linkGroup = linkGroup
                state.audioTracks.append(EditLane(clips: [micClip]))
            }
        }
        if let imported = state.allClips.first(where: { $0.linkGroup == linkGroup }) {
            selectedClipIDs = [imported.id]
            clock.seek(to: imported.timelineStart, precise: true)
        }
        if result.microphoneURL != nil, micDuration == nil {
            notice = L10n("The recovered recording was added, but its microphone track couldn’t be read.")
        }
        return true
    }
}

extension CanvasRatio {
    /// 找最接近某个尺寸的固定比例档；差得远就返回 nil（保持 auto）。
    static func closest(to size: CGSize) -> CanvasRatio? {
        guard size.width > 0, size.height > 0 else { return nil }
        let target = Double(size.width / size.height)
        var best: (ratio: CanvasRatio, deviation: Double)?
        for candidate in CanvasRatio.allCases {
            guard let fixed = candidate.fixedSize else { continue }
            let value = Double(fixed.width / fixed.height)
            let deviation = abs(value - target) / target
            if best == nil || deviation < best!.deviation {
                best = (candidate, deviation)
            }
        }
        guard let best, best.deviation < 0.02 else { return nil }
        return best.ratio
    }
}
