import AppKit
import AVFoundation
import Foundation
import ScreenCaptureKit
import SrtFlowCore

/// 录屏的 App 级总闸：状态机、权限、生命周期、提交 journal、崩溃恢复、最终导入。
///
/// 关键约束（全部来自 Phase 0 实测与四轮复审，详见
/// `docs/architecture/screen-recording-lifecycle.md`）：
///
/// - **写盘期没有直达 `.failed` 的路径**：stream/writer 出错也走
///   stopping → finishing，收干净再定终态。`.failed` 是解锁工程切换的终态。
/// - **`.importing` / `.partialRecovery` 仍持有工程锁**。
/// - **journal 提交**：每次 rename 之前先 `ManifestStore.persist()` 成功返回。
/// - **清 manifest 的唯一判据是 `ScreenRecordingRecoveryLedger.canClearManifest`**。
/// - **录制期间必须持有 `beginActivity` 活动断言**，否则 App Nap 拖垮时长
///   （Phase 0 门槛 3 实测：请求 6 秒跑了 18 秒）。
@available(macOS 15.0, *)
@MainActor
final class ScreenRecordingCoordinator: ObservableObject {
    static let shared = ScreenRecordingCoordinator()

    @Published private(set) var state: ScreenRecordingState = .idle
    /// 需要用户处理的 partial 结果。
    @Published private(set) var pendingPartial: ScreenRecordingResult?
    @Published var errorMessage: String?
    /// 崩溃恢复发现的上次残留（启动时填）。
    @Published var pendingRecovery: PendingRecovery?

    private var request: ScreenRecordingRequest?
    private var writer: ScreenRecordingWriter?
    private var engine: ScreenCaptureEngine?
    private var controlPanel: ScreenRecordingControlPanel?
    /// 录制期间盖在被录区域之外的浅遮罩（只有区域来源有）。
    private var regionIndicator: ScreenRecordingRegionIndicator?
    var picker: ScreenRecordingSourcePicker?
    var regionPanel: ScreenRecordingRegionPanel?
    private var filter: SCContentFilter?
    var manifest: ScreenRecordingManifest?
    private var activity: NSObjectProtocol?
    private var timer: Timer?
    private var countdownTask: Task<Void, Never>?
    /// 终止协调：Quit 期间等录制收尾。
    private var terminationPending = false

    /// 会话失效令牌。
    ///
    /// `start()` 里有五个 `await`（picker、Save 面板、filter 重建…），每一个都可能
    /// 在会话已经被撤销之后才返回。没有这个令牌的话，Quit 期间撤销了会话，
    /// `start()` 仍会继续建 writer、写 manifest、起倒计时，把刚清干净的东西
    /// 重新造出来（复审 P1-1 / P1-8）。每个 await 之后都要 `isCurrent(epoch)`。
    private var sessionEpoch = 0

    let store: ScreenRecordingManifestStore

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SrtFlow", isDirectory: true)
        store = ScreenRecordingManifestStore(directory: support)
    }

    /// 录制中必须锁工程切换。**执行入口**要查它，不能只靠按钮 disabled。
    var locksProjectSwitching: Bool { state.locksProjectSwitching }
    var isBusy: Bool { state.isBusy }

    /// 启动恢复已经尝试过。`recoverIfNeeded()` 挂在会重复出现的视图 task 上，
    /// 靠它保证一个进程只跑一次（复审二 P1-5）。
    var hasAttemptedRecovery = false

    /// 存在尚未了结的 manifest（恢复待决，或上一次提交没走完）。
    ///
    /// 开新录制会**覆盖唯一的 manifest**，所以开录前必须挡住
    /// —— 覆盖之后上一份残留就再也没人认领了（复审二 P1-5）。
    /// 判据是**文件是否存在**，不是能否解码。
    /// `try? store.load() != nil` 会把损坏的 JSON 读成「没有账本」，
    /// 下一次 `persist()` 就覆盖了它（复审三 P1-2）。
    var hasUnsettledManifest: Bool {
        pendingRecovery != nil || store.fileExists
    }

    // MARK: - 状态迁移

    @discardableResult
    func transition(to next: ScreenRecordingState) -> Bool {
        guard ScreenRecordingState.canTransition(from: state, to: next) else {
            // 非法迁移一律挡掉（重复 Stop、stale 回调）。
            return false
        }
        state = next
        // 退出等待中的话，每次落到非忙状态都要重新评估能不能答复 ——
        // 这是 `.terminateLater` 唯一的出口，漏了就是 App 卡住退不掉。
        settleTerminationIfPossible()
        return true
    }

    // MARK: - 开始

    /// 点 Record Screen。重复点只激活现有会话（计划 §11.1）。
    func begin() {
        guard state == .idle else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // 上一份残留还没了结就不能开新的：manifest 只有一份，开录会覆盖它，
        // 那份残留就永远无人认领了（复审二 P1-5）。
        guard !hasUnsettledManifest else {
            report(L10n("There’s still an unfinished recording from earlier. Deal with it first."))
            // 让恢复流程重新裁决一次并把弹窗端上来（可能是上次提交没走完
            // 留下的账，那时还没弹过）。
            hasAttemptedRecovery = false
            Task { await recoverIfNeeded() }
            return
        }
        errorMessage = nil
        transition(to: .configuring)
    }

    func cancelConfiguring() {
        guard state == .configuring else { return }
        transition(to: .idle)
    }

    /// 设置页点「开始录制」后的完整流程（计划 §11.2 的十步）。
    func start(
        options: ScreenRecordingOptions,
        project: VideoEditProject
    ) async {
        guard state == .configuring else { return }
        // session 身份在这里生成**一次**，贯穿 picker 回调直到最终 request。
        let sessionID = UUID()
        let epoch = sessionEpoch

        // 1–4. 选来源（保存位置已在设置页里定好，这里只剩「选录什么」）
        transition(to: .choosingSource)
        let picked: (source: ScreenRecordingSource, filter: SCContentFilter?)
        do {
            picked = try await chooseSource(options: options)
        } catch {
            guard isCurrent(epoch) else { return }
            handleSetupFailure(error)
            return
        }
        guard isCurrent(epoch) else { return }

        // 5. 冻结最终像素尺寸
        guard let geometry = geometry(for: picked.source) else {
            handleSetupFailure(ScreenRecordingError.sourceUnavailable)
            return
        }
        let pixelSize = capturePixelSize(
            for: picked.source, geometry: geometry, pickerFilter: picked.filter
        )

        // 6. 目录可写 / 空间预检（保存位置已经在设置页里选好了）
        transition(to: .choosingDestination)
        guard let outputURL = options.outputURL else {
            handleSetupFailure(ScreenRecordingError.outputNotWritable)
            return
        }
        if let error = preflightDestination(
            outputURL, pixelSize: pixelSize, frameRate: project.state.frameRate
        ) {
            handleSetupFailure(error)
            return
        }

        // 麦克风 sidecar 避让已占用的名字：Save 面板只确认过**主文件**的覆盖，
        // sidecar 从没被确认过，不能悄悄替换（复审 P1-2）。
        let microphoneURL: URL? = options.microphone.isEnabled
            ? ScreenRecordingRequest.availableMicrophoneURL(
                for: outputURL, isTaken: { FileManager.default.fileExists(atPath: $0.path) }
            )
            : nil

        let request = ScreenRecordingRequest(
            sessionID: sessionID,
            source: picked.source,
            capturesSystemAudio: options.capturesSystemAudio,
            microphone: options.microphone,
            cursor: options.cursor,
            frameRate: project.state.frameRate,
            outputURL: outputURL,
            capturePixelSize: pixelSize,
            documentGeneration: project.currentDocumentGeneration,
            canvasRatioSnapshot: project.state.canvasRatio.rawValue,
            canvasEditGeneration: project.canvasEditGeneration,
            projectHadVisualMedia: project.hasVisualMedia,
            microphoneOutputURL: microphoneURL
        )
        self.request = request

        // 7. 建 Stop 窗，拿 windowID，重建排除 filter
        transition(to: .preparing)
        let panel = ScreenRecordingControlPanel { [weak self] in
            Task { await self?.stop() }
        }
        panel.show()
        controlPanel = panel
        do {
            let built = try await finalFilter(
                for: picked.source, pickerFilter: picked.filter, excluding: panel.windowID
            )
            guard isCurrent(epoch) else { return }
            filter = built
        } catch {
            guard isCurrent(epoch) else { return }
            handleSetupFailure(error)
            return
        }

        // 8. **先持久化 manifest，再建临时文件和 writer**
        let manifest = ScreenRecordingManifest(
            sessionID: sessionID,
            startedAt: Date(),
            mainTemporaryPath: request.temporaryURL(for: .main).path,
            mainFinalPath: request.outputURL.path,
            micTemporaryPath: request.microphone.isEnabled
                ? request.temporaryURL(for: .microphone).path : nil,
            micFinalPath: request.microphone.isEnabled ? request.microphoneURL.path : nil
        )
        do {
            try store.persist(manifest)
        } catch {
            handleSetupFailure(ScreenRecordingError.writerFailed(message: error.localizedDescription))
            return
        }
        self.manifest = manifest

        do {
            let writer = try ScreenRecordingWriter(
                movURL: request.temporaryURL(for: .main),
                micURL: request.microphone.isEnabled
                    ? request.temporaryURL(for: .microphone) : nil,
                pixelSize: pixelSize,
                frameRate: request.frameRate,
                capturesSystemAudio: request.capturesSystemAudio
            )
            // **先登记所有权再 start()。** 反过来的话，主 writer 已经建好文件、
            // mic writer 启动失败时，`self.writer` 还是 nil，清理路径上的
            // `writer?.cancel()` 就删不到那两个临时文件（复审 P1-8）。
            self.writer = writer
            try writer.start()
            engine = ScreenCaptureEngine(writer: writer, sessionID: sessionID)
            engine?.onStreamStopped = { [weak self] callbackSession, error in
                Task { @MainActor in
                    await self?.handleStreamStopped(session: callbackSession, error: error)
                }
            }
        } catch {
            handleSetupFailure(ScreenRecordingError.writerFailed(message: error.localizedDescription))
            return
        }

        // 录制真的要开始了才记住目录 —— 取消/失败不该改变它。
        ScreenRecordingPreferences.lastDirectory = outputURL.deletingLastPathComponent()

        // 9–10. 倒计时 → 启动
        await runCountdown()
    }

    private func runCountdown() async {
        guard transition(to: .countingDown(remaining: 3)) else { return }
        countdownTask = Task { [weak self] in
            for remaining in stride(from: 3, through: 1, by: -1) {
                guard let self, case .countingDown = self.state else { return }
                self.transition(to: .countingDown(remaining: remaining))
                // 让用户看得见还有几秒，别让浮窗停在 00:00 的红点上。
                self.controlPanel?.setCountdown(remaining)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
            }
            // **不在这里清 countdown。** 清了之后还要等 `startCapture()` 返回，
            // 那段时间浮窗会退回「红点 + 00:00」，看起来已经在录了（复审三 P2）。
            // 由 `launchCapture()` 在真正开录之后清。
            await self?.launchCapture()
        }
        await countdownTask?.value
    }

    private func launchCapture() async {
        guard transition(to: .starting),
              let request, let engine, let filter else { return }
        // 录制期间持活动断言，否则 App Nap 会拖垮时长（门槛 3 实测）。
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .latencyCritical],
            reason: "SrtFlow screen recording"
        )
        do {
            try await engine.start(request: request, filter: filter)
        } catch {
            // 启动失败也走停止链路 —— 不直达 failed。
            await stopAndFinalize(reason: .streamFailed(message: error.localizedDescription))
            return
        }
        guard transition(to: .recording(startedAt: Date())) else {
            await stopAndFinalize(reason: nil)
            return
        }
        // 真正开录之后才把倒计时数字换成红点计时器。
        controlPanel?.setCountdown(nil)
        // 区域来源：盖上浅遮罩，让用户录制全程都看得出边界在哪。
        // **必须在 capture 起来之后再显示**，而且它自己 sharingType = .none，
        // 否则会被录进成片。
        showRegionIndicator(for: request)
        startTicking()
    }

    /// 只有区域来源需要遮罩：整屏全都进画面，窗口会移动（这一版不跟踪）。
    private func showRegionIndicator(for request: ScreenRecordingRequest) {
        guard case .region(let displayID, let localRect) = request.source else { return }
        guard let geometry = geometry(for: request.source),
              let screen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                      .uint32Value == displayID
              }) else { return }
        let mainHeight = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
        let appKitRect = ScreenRecordingCoordinateMapper.appKitRect(
            fromDisplayLocal: localRect, display: geometry,
            mainDisplayHeightInPoints: mainHeight
        )
        regionIndicator = ScreenRecordingRegionIndicator(
            regionInAppKit: appKitRect, screen: screen
        )
        regionIndicator?.show()
    }

    private func startTicking() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard case .recording = state, let writer, let request else { return }
        controlPanel?.update(elapsed: writer.elapsed)
        // 低空间监测（低频）：跌破警戒线主动停止并走正常 finalize。
        let warning = ScreenRecordingDiskBudget.runtimeWarningBytes(
            pixelSize: request.capturePixelSize, frameRate: request.frameRate
        )
        if let free = availableBytes(at: request.outputURL), free < warning {
            controlPanel?.setWarning(L10n("Low disk space — stopping soon."))
            Task { await stop() }
        }
        if writer.currentFailure != nil || writer.hasAudioOverflow {
            Task { await stop() }
        }
    }

    // MARK: - 取消 / 停止

    /// 倒计时期间取消：完整撤销，不留任何痕迹（计划 §11.2 末段）。
    func cancelCountdown() async {
        guard case .countingDown = state else { return }
        countdownTask?.cancel()
        await engine?.stop()
        writer?.cancel()
        controlPanel?.close()
        picker?.invalidate()
        try? store.clear()
        releaseResources()
        transition(to: .idle)
    }

    /// 幂等 Stop。Stop 按钮、Quit、stream error、低空间都走它。
    func stop() async {
        switch state {
        case .recording, .starting:
            await stopAndFinalize(reason: nil)
        case .countingDown:
            await cancelCountdown()
        case .configuring, .choosingSource, .choosingDestination, .preparing:
            // 配置期也要能被叫停（Quit）。早先这里落到 default 静默返回，
            // Quit 就永远等不到 reply（复审 P1-1）。
            invalidateSession()
        case .partialRecovery:
            // 退出时还挂着待决的 partial / 恢复提示。
            //
            // 这里必须收敛，否则 `.terminateLater` 永远等不到 reply ——
            // 用户切离 Edit Video 让 sheet 消失之后再退出就会卡住（复审三 P1-1）。
            // 按**最安全的默认**处置：保留文件、不入轨、不删除。
            if pendingRecovery != nil {
                await resolveRecovery(.keepFile)
            } else if pendingPartial != nil {
                await resolvePartial(import: false)
            } else {
                transition(to: .idle)
            }
        default:
            return   // 重复 Stop 被状态机挡掉
        }
    }

    /// 撤销当前会话：作废令牌、拆掉所有还开着的选择界面、清干净临时产物。
    ///
    /// 只用于**还没写过一个字节**的阶段。写盘期一律走 `stopAndFinalize`。
    func invalidateSession() {
        sessionEpoch &+= 1
        countdownTask?.cancel()
        picker?.invalidate()
        regionPanel?.cancel()
        controlPanel?.close()
        regionIndicator?.close(); regionIndicator = nil
        writer?.cancel()          // 删掉两个临时文件
        try? store.clear()
        releaseResources()
        transition(to: .idle)
    }

    /// 当前会话是否还有效（每个 `await` 之后都要问）。
    func isCurrent(_ epoch: Int) -> Bool { epoch == sessionEpoch }

    private func handleStreamStopped(session: UUID, error: Error) async {
        // 旧会话的迟到回调不许停掉新会话（复审二 P1-7）。
        guard let request, request.sessionID == session else { return }
        guard case .recording = state else { return }
        await stopAndFinalize(reason: .streamFailed(message: error.localizedDescription))
    }

    /// **唯一的收尾路径**：stopping → finishing → (importing | partialRecovery | failed)。
    private func stopAndFinalize(reason: ScreenRecordingError?) async {
        guard transition(to: .stopping) else { return }
        timer?.invalidate(); timer = nil
        // 遮罩先撤：收尾期间不该还盖着一层。
        regionIndicator?.close(); regionIndicator = nil
        controlPanel?.setFinalizing(true)
        await engine?.stop()

        guard transition(to: .finishing), let writer, let request else {
            finishWithFailure(reason ?? .writerFailed(message: "inconsistent state"))
            return
        }
        let result = await writer.finish(stopHostTime: engine?.stopHostTime)
        controlPanel?.close()
        releaseActivity()

        // **先验证临时文件，再提交。**
        //
        // 顺序反过来的话，一个无效或损坏的临时文件会先 rename 到用户选的位置，
        // 把那里原有的文件覆盖掉，之后才发现它不能用 —— 用户既没拿到录制，
        // 又丢了旧文件（复审 P1-2）。临时文件是我们自己的精确路径，
        // 判定无效就地删除是安全的。
        let temporaryMain = request.temporaryURL(for: .main)
        let probe = await ScreenRecordingProbe.info(temporaryMain)

        // 音频的成功契约也要**在提交前**验证，不能只看视频（复审二 P1-8）。
        //
        // 而且**不能只验「有没有轨/时长是否大于零」** —— 麦克风产生一个包就
        // 断线，容器里照样有轨、时长也不为零，这种录制会被判成功（复审三 P1-5）。
        // 判据改成 writer 的实测量：写入采样数 + 每路最后写入时刻，
        // 再与整段时长比对末端差。
        var audioComplaints: [String] = []
        /// 一路音频是否**从头到尾**都覆盖了。
        ///
        /// 容差见 `ScreenRecordingAudioCoverage`：这是完整性判据（抓「缺了几秒」），
        /// 不是对齐判据 —— 拿首包 PTS 配一帧容差会把 AAC priming 判成缺陷
        /// （计划 §8.3 明确禁止；真机首测正是被它误报）。
        func coverageComplaint(_ kind: String, label: String) -> String? {
            if let start = result.firstAppendedSeconds[kind],
               ScreenRecordingAudioCoverage.isSignificant(start) {
                return String(
                    format: L10n("%1$@ starts %2$@ after the recording begins."),
                    label, MediaFormatting.duration(start)
                )
            }
            if let end = result.lastAppendedEndSeconds[kind],
               ScreenRecordingAudioCoverage.isSignificant(result.duration - end) {
                return String(
                    format: L10n("%1$@ stops %2$@ before the end of the recording."),
                    label, MediaFormatting.duration(result.duration - end)
                )
            }
            return nil
        }

        let written = result.counters.written
        let microphoneValid: Bool
        if request.capturesSystemAudio {
            if probe?.hasAudio == false || (written["audio"] ?? 0) == 0 {
                audioComplaints.append(L10n("Computer audio was on, but nothing was recorded on the audio track."))
            } else if let complaint = coverageComplaint("audio", label: L10n("Computer audio")) {
                audioComplaints.append(complaint)
            }
        }
        if request.microphone.isEnabled {
            let micTemp = request.temporaryURL(for: .microphone)
            if let degraded = engine?.microphoneDegraded {
                // stream 起不来时已经降级成「无麦克风」重试过（复审四 P1-2）。
                audioComplaints.append(String(
                    format: L10n("The microphone couldn’t be used, so only the screen was recorded: %@"),
                    degraded
                ))
                microphoneValid = false
            } else if let reason = result.microphoneFailure {
                audioComplaints.append(String(
                    format: L10n("The microphone stopped partway through: %@"), reason
                ))
                microphoneValid = false
            } else if !FileManager.default.fileExists(atPath: micTemp.path)
                        || (written["microphone"] ?? 0) == 0 {
                audioComplaints.append(L10n("The microphone track wasn’t written."))
                microphoneValid = false
            } else if await ScreenRecordingProbe.audioDuration(micTemp) == nil {
                audioComplaints.append(L10n("The microphone track can’t be read."))
                microphoneValid = false
            } else {
                // 「录了一个包就断」「开头缺一截」都由覆盖判据抓住。
                if let complaint = coverageComplaint("microphone", label: L10n("The microphone")) {
                    audioComplaints.append(complaint)
                }
                microphoneValid = true
            }
        } else {
            microphoneValid = false
        }

        guard let probe, probe.duration > 0 else {
            var paths = [temporaryMain.path]
            if request.microphone.isEnabled {
                paths.append(request.temporaryURL(for: .microphone).path)
            }
            // **删干净了才允许清账**：删除失败却清了账，那些隐藏临时文件
            // 就再也没人认领（复审四 P1-3）。
            let undeleted = removeExactly(paths)
            reportUndeleted(undeleted)
            finishWithFailure(
                reason ?? .writerFailed(message: L10n("The recording has no usable video.")),
                clearManifest: undeleted.isEmpty
            )
            return
        }

        // journal 提交：每次 rename 之前先 persist 意向并等它成功返回。
        let committedMicrophoneURL: URL?
        do {
            committedMicrophoneURL = try commitFiles(
                request: request, commitMicrophone: microphoneValid
            )
        } catch {
            // **提交失败绝不清账。** 例如主文件已提交、mic move 失败时清了
            // manifest，那份仍然有效的隐藏 mic 临时文件就永久无人认领
            // （复审二 P1-4）。留着账，下次启动按 journal 继续裁决。
            finishWithFailure(
                .writerFailed(message: error.localizedDescription), clearManifest: false
            )
            return
        }

        // 提交完再核一次最终路径确实可读 —— rename 之后文件仍可能因为卷问题
        // 读不出来，那种情况下不能当成功入轨（复审二 P1-8）。
        // **两个文件都要回读**，不能只看主文件（复审三 P1-5）。
        var finalComplaints = audioComplaints
        if await ScreenRecordingProbe.info(request.outputURL) == nil {
            finalComplaints.append(L10n("The saved recording can’t be read back."))
        }
        if let micURL = committedMicrophoneURL,
           await ScreenRecordingProbe.audioDuration(micURL) == nil {
            finalComplaints.append(L10n("The saved microphone track can’t be read back."))
        }

        let recording = ScreenRecordingResult(
            mainURL: request.outputURL,
            microphoneURL: committedMicrophoneURL,
            duration: probe.duration,
            pixelSize: request.capturePixelSize,
            frameRate: request.frameRate,
            isPartial: result.isPartial || reason != nil || !finalComplaints.isEmpty,
            partialReason: result.partialReason
                ?? reason?.localizedText
                ?? (finalComplaints.isEmpty ? nil : finalComplaints.joined(separator: " "))
        )

        if recording.isPartial {
            pendingPartial = recording
            transition(to: .partialRecovery(recording))
        } else {
            transition(to: .importing)
            await importResult(recording)
        }
    }

    /// journal 提交协议：persist 意向 → rename → persist 已提交。
    /// - Returns: 麦克风 sidecar 的**实际**最终路径（没录麦克风或没产生文件时 nil）。
    /// - Parameter commitMicrophone: sidecar 是否**已通过校验**。
    ///   false 时不提交它 —— 零采样、probe 失败、writer 已知故障却仍残留的
    ///   `.m4a` 一律不能变成用户可见的损坏文件（复审四 P1-2）。
    @discardableResult
    private func commitFiles(
        request: ScreenRecordingRequest, commitMicrophone: Bool
    ) throws -> URL? {
        guard var manifest else { return nil }
        let manager = FileManager.default

        // 临时文件必须在。走到这里它已经被 probe 验证过了；不在就是异常，
        // **不能带着「已提交」的 stage 往下走** —— 那会让最终路径上原有的
        // 旧文件被当成本次录制导入（复审 P1-2）。
        let mainTemp = request.temporaryURL(for: .main)
        guard manager.fileExists(atPath: mainTemp.path) else {
            throw ScreenRecordingError.writerFailed(
                message: L10n("The recording file disappeared before it could be saved.")
            )
        }

        manifest.stage = .committingMain
        try store.persist(manifest)          // ← 栅栏：成功返回才允许 rename
        self.manifest = manifest
        if manager.fileExists(atPath: request.outputURL.path) {
            // 主文件的覆盖是用户在 Save 面板里明确确认过的。
            _ = try manager.replaceItemAt(request.outputURL, withItemAt: mainTemp)
        } else {
            try manager.moveItem(at: mainTemp, to: request.outputURL)
        }
        manifest.stage = .mainCommitted
        try store.persist(manifest)
        self.manifest = manifest

        guard request.microphone.isEnabled, commitMicrophone else {
            // 不提交 sidecar：停在 mainCommitted 是对现场的准确描述。
            // 无效的临时文件精确删掉，别留成孤儿。
            if request.microphone.isEnabled {
                try? manager.removeItem(at: request.temporaryURL(for: .microphone))
            }
            return nil
        }
        let micTemp = request.temporaryURL(for: .microphone)
        guard manager.fileExists(atPath: micTemp.path) else {
            // 开了麦克风却没有 sidecar 文件：**不能推进到 allCommitted**。
            // 推进了就等于宣称两个 rename 都做完了，恢复时会照着 micFinalPath
            // 去认一个根本不存在（或不相干）的文件（复审二 P1-8）。
            // 停在 mainCommitted 是准确的描述：主文件提交了，sidecar 没有。
            return nil
        }

        // **先冻结最终目标、写进 manifest、持久化，然后才 rename。**
        // 顺序反了就是 journal 身份被破坏（复审二 P1-3）。
        let target = ScreenRecordingFileNaming.availableURL(
            like: request.microphoneURL,
            isTaken: { manager.fileExists(atPath: $0.path) }
        )
        manifest = manifest.retargetingMicrophone(to: target.path)
        manifest.stage = .committingMicrophone
        try store.persist(manifest)
        self.manifest = manifest

        try manager.moveItem(at: micTemp, to: target)

        manifest.stage = .allCommitted
        try store.persist(manifest)
        self.manifest = manifest
        return target
    }

    // MARK: - 导入

    /// 用户对 partial 的决定。
    func resolvePartial(import shouldImport: Bool) async {
        guard case .partialRecovery(let result) = state else { return }
        if shouldImport {
            transition(to: .importing)
            await importResult(result)
        } else {
            // 文件已提交到用户选的位置 —— **默认保留，不擅自删除**（计划 §11.4）。
            pendingPartial = nil
            try? store.clear()   // 用户已明确处置 → settled
            releaseResources()
            transition(to: .idle)
        }
    }

    private func importResult(_ result: ScreenRecordingResult) async {
        guard let request else { transition(to: .failed(.writerFailed(message: "no request"))); return }
        let project = VideoEditProject.shared
        // 最后一道 stale-result guard（UI 已阻止切工程，这里仍要查）。
        guard project.isCurrentGeneration(request.documentGeneration) else {
            // 文件已经提交到用户选的位置了 —— **保留 manifest**，下次启动
            // 还能提示「有一段录制没入轨」（复审 P1-8）。
            finishWithFailure(
                .writerFailed(message: String(
                    format: L10n("The project changed, so the recording wasn’t added to the timeline. It’s saved as %@."),
                    result.mainURL.lastPathComponent
                )),
                clearManifest: false
            )
            return
        }
        // 入轨可能失败（probe 读不出等）。失败时同样保留 manifest。
        guard await project.importScreenRecording(result, request: request) else {
            finishWithFailure(
                .writerFailed(message: String(
                    format: L10n("The recording is saved as %@, but it couldn’t be added to the timeline."),
                    result.mainURL.lastPathComponent
                )),
                clearManifest: false
            )
            return
        }
        pendingPartial = nil
        // 入轨事务已提交 → settled → 现在才允许清账。
        // **必须在进入 `.finished` 之前清。** `.finished` 是非忙状态，会立刻
        // 触发退出答复；正在 Quit 时进程可能赶在清账之前退出，下次启动重复
        // 提示并重复入轨（复审四 P1-4）。
        try? store.clear()
        releaseResources()
        transition(to: .finished(result))
        transition(to: .idle)
    }

    // MARK: - 失败与清理

    private func handleSetupFailure(_ error: Error) {
        // 还没写过一个字节：控制窗等资源是同步拆的，可以直接进终态。
        controlPanel?.close()
        picker?.invalidate()
        regionPanel?.cancel()
        writer?.cancel()
        try? store.clear()
        releaseResources()
        if let pickerError = error as? ScreenRecordingSourcePicker.PickerError,
           case .cancelled = pickerError {
            transition(to: .idle)   // 取消不是错误
            return
        }
        if let recordingError = error as? ScreenRecordingError, case .pickerCancelled = recordingError {
            transition(to: .idle)
            return
        }
        // 权限等具体错误必须用 localizedText，不能退化成通用错误码
        // （`ScreenRecordingError` 没实现 LocalizedError；复审 P1-7）。
        let message = (error as? ScreenRecordingError)?.localizedText
            ?? (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        report(message)
        transition(to: .failed(.writerFailed(message: message)))
        transition(to: .idle)
    }

    private func finishWithFailure(_ error: ScreenRecordingError, clearManifest: Bool = true) {
        report(error.localizedText)
        if clearManifest { try? store.clear() }
        // **必须清 pendingPartial。** 留着它，partial 弹窗会继续挂在屏幕上，
        // 而状态已经不是 `.partialRecovery`，两个按钮都会被 guard 挡掉 ——
        // 用户面对一个点什么都没反应的弹窗（复审二 P1-6）。
        pendingPartial = nil
        releaseResources()
        transition(to: .failed(error))
        transition(to: .idle)
    }

    /// 把失败**送到用户真的看得见的地方**。
    ///
    /// 设置页在调 coordinator 之前就 dismiss 了，只写 `errorMessage` 等于没报 ——
    /// picker/权限/目标/writer 的失败在用户眼里就是「点了没反应」（复审 P1-7）。
    /// 工程的 notice 横幅与设置页无关，一定看得到。
    func report(_ message: String) {
        errorMessage = message
        VideoEditProject.shared.notice = message
    }

    /// Quit 期间等录制收尾（计划 §12.2）。
    func beginTerminationWait() { terminationPending = true }

    /// 录制侧收尾完成后，**仍要经过文档那一关**再回复退出。
    ///
    /// 早先这里直接 `reply(true)`，跳过了 `prepareToCloseDocument()`：录制刚入轨
    /// 就按 ⌘Q，未命名工程不会问保存，已有工程也可能来不及落盘（复审 P1-1）。
    func settleTerminationIfPossible() {
        guard terminationPending else { return }
        // partial / 恢复待决时不能退：用户还没决定那份文件怎么处理。
        guard !state.isBusy, pendingPartial == nil, pendingRecovery == nil else { return }
        finishTerminationWait(shouldTerminate: VideoEditProject.shared.prepareToCloseDocument())
    }

    /// **只 reply 一次** —— 反复按 Quit、Stop 与 Quit 同时发生都靠它幂等。
    func finishTerminationWait(shouldTerminate: Bool) {
        guard terminationPending else { return }
        terminationPending = false
        NSApp.reply(toApplicationShouldTerminate: shouldTerminate)
    }

    private func releaseActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    private func releaseResources() {
        releaseActivity()
        timer?.invalidate(); timer = nil
        countdownTask?.cancel(); countdownTask = nil
        writer = nil
        engine = nil
        controlPanel = nil
        regionIndicator?.close()
        regionIndicator = nil
        picker = nil
        regionPanel = nil
        filter = nil
        request = nil
        manifest = nil
        // 这里**不再直接 reply**：那样会在 `.importing` 期间就答复退出，
        // 也会跳过文档的保存询问。收口统一在 `settleTerminationIfPossible()`。
    }
}
