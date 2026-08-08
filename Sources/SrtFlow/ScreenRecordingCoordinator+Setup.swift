import AppKit
import AVFoundation
import Foundation
import ScreenCaptureKit
import SrtFlowCore

/// 录制设置项（设置页 → coordinator 的输入）。
struct ScreenRecordingOptions {
    enum SourceKind: String, CaseIterable, Identifiable {
        case display, window, region
        var id: String { rawValue }
        var title: String {
            switch self {
            case .display: return "Entire display"
            case .window: return "A window"
            case .region: return "Custom region"
            }
        }
    }

    var sourceKind: SourceKind = .display
    var regionRatio: RegionAspectRatio = .free
    var capturesSystemAudio = true
    var microphone: MicrophoneConfiguration = .disabled
    var cursor: CursorConfiguration = .default
    /// 用户在设置页里选好的保存位置。
    ///
    /// 保存位置**在设置页里就定下来**，不放到系统 picker 之后再问：
    /// 那个顺序是「先被系统 picker 的 Cancel / Share Entire Screen 问一次，
    /// 再被保存面板问一次」，用户不知道自己走到哪一步了（真机首测反馈）。
    var outputURL: URL?
}

@available(macOS 15.0, *)
extension ScreenRecordingCoordinator {

    // MARK: 来源选择

    func chooseSource(
        options: ScreenRecordingOptions
    ) async throws -> (source: ScreenRecordingSource, filter: SCContentFilter?) {
        switch options.sourceKind {
        case .region:
            // 区域必须自己取 SCDisplay，所以**先**要广域屏幕权限（计划 §11.2-3）。
            guard ScreenRecordingPermissions.screen == .authorized else {
                _ = ScreenRecordingPermissions.requestScreenAccess()
                throw ScreenRecordingError.screenCaptureNotAuthorized
            }
            let panel = ScreenRecordingRegionPanel(ratio: options.regionRatio)
            regionPanel = panel
            defer { regionPanel = nil }
            guard let result = await panel.present() else {
                throw ScreenRecordingSourcePicker.PickerError.cancelled
            }
            return (.region(displayID: result.displayID, rectInPoints: result.rectInPoints), nil)

        case .display, .window:
            // **picker 之前既不做广域 preflight，也不预读 SCShareableContent**：
            // 前者会让「用户取消 picker」也收到权限提示（计划 §11.2-3/4），后者在
            // clean TCC 下必然失败并留下空缓存，导致首跑反推不出来源（复审 P1-5）。
            // 来源解析改在 picker 回调之后进行。
            let picker = ScreenRecordingSourcePicker()
            self.picker = picker
            let selection = try await picker.present(
                mode: options.sourceKind == .display ? .display : .window
            )
            picker.invalidate()
            self.picker = nil
            return (selection.source, selection.filter)
        }
    }

    /// 最终 filter。
    ///
    /// - 单窗口：**沿用 picker 原 filter**，不重建（计划 §20）。
    /// - 整屏 / 区域：用 `SCContentFilter(display:excludingWindows:)` 把 Stop 窗
    ///   排除掉（Phase 0 门槛 9 已像素级验证有效）。
    func finalFilter(
        for source: ScreenRecordingSource,
        pickerFilter: SCContentFilter?,
        excluding controlWindowID: CGWindowID
    ) async throws -> SCContentFilter {
        // **picker 给了 filter 就直接用，不重建。**
        //
        // 重建需要读 `SCShareableContent`，而那要**广域**屏幕录制授权 ——
        // picker 这条路的全部意义恰恰是「只授权用户选中的那块内容」。
        // 真机首测就死在这里：用户走完 picker 和保存面板之后什么都没发生。
        //
        // 控制窗的排除已经改由 `NSWindow.sharingType = .none` 保证
        // （窗口服务器级别，不依赖授权，也没有「窗口还没进可分享列表」的竞态），
        // 所以这里不再需要 `excludingWindows`。
        if let pickerFilter { return pickerFilter }

        // 只剩自定义区域这一条路 —— 它本来就在 `chooseSource` 里要求过广域授权。
        guard let displayID = source.displayID else { throw ScreenRecordingError.sourceUnavailable }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
        } catch {
            // -3801 同样覆盖「从未授权」，文案只能说未获授权。
            throw ScreenRecordingError.screenCaptureNotAuthorized
        }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenRecordingError.sourceUnavailable
        }
        // 控制窗的排除由 `NSWindow.sharingType = .none` 保证，这里不再依赖
        // 「在可分享窗口列表里找到它」—— 那一步有竞态，找不到就得整段失败。
        // 仍然把它放进 excludingWindows 当第二道保险（找不到也不算错）。
        let excluded = content.windows.filter { $0.windowID == controlWindowID }
        return SCContentFilter(display: display, excludingWindows: excluded)
    }

    // MARK: 几何与尺寸

    func geometry(
        for source: ScreenRecordingSource
    ) -> ScreenRecordingCoordinateMapper.DisplayGeometry? {
        guard let displayID = source.displayID else {
            // 单窗口来源没有固定显示器，用主屏的 scale 推算即可。
            return geometry(forDisplayID: CGMainDisplayID())
        }
        return geometry(forDisplayID: displayID)
    }

    private func geometry(
        forDisplayID id: CGDirectDisplayID
    ) -> ScreenRecordingCoordinateMapper.DisplayGeometry? {
        guard let mode = CGDisplayCopyDisplayMode(id) else { return nil }
        return .init(
            boundsInPoints: CGDisplayBounds(id),
            // 真实像素只有 pixelWidth 给。用点会在 Retina 上录成半分辨率糊图。
            pixelSize: CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
        )
    }

    /// 冻结的最终捕获像素尺寸：真实像素 → 单边 ≤4096 → 偶数。
    ///
    /// - Parameter pickerFilter: 单窗口来源的尺寸**只能**从它来（见下）。
    func capturePixelSize(
        for source: ScreenRecordingSource,
        geometry: ScreenRecordingCoordinateMapper.DisplayGeometry,
        pickerFilter: SCContentFilter?
    ) -> CGSize {
        switch source {
        case .region(_, let rect):
            return ScreenRecordingCoordinateMapper.captureSize(
                forRegionInPoints: rect.size, display: geometry
            )
        case .display:
            return ScreenRecordingCoordinateMapper.captureSize(forFullDisplay: geometry)
        case .window:
            // 窗口尺寸与缩放**直接取 picker filter**：`contentRect` 就是那个窗口，
            // `pointPixelScale` 就是它当前所在屏的缩放。早先固定用主屏 scale 推算，
            // 窗口在副屏（尤其 Retina/非 Retina 混插）时分辨率是错的（复审 P1-6）。
            if let pickerFilter {
                let rect = pickerFilter.contentRect
                let scale = pickerFilter.pointPixelScale
                return ScreenRecordingCoordinateMapper.fitToHardwareEncoder(
                    CGSize(
                        width: rect.width * CGFloat(scale),
                        height: rect.height * CGFloat(scale)
                    )
                )
            }
            return ScreenRecordingCoordinateMapper.captureSize(forFullDisplay: geometry)
        }
    }

    // MARK: 目标位置与预检

    // 保存位置改由设置页在开录**之前**选好（`ScreenRecordingOptions.outputURL`），
    // 这里不再弹面板 —— 早先是「系统 picker 问一次、保存面板再问一次」，
    // 用户不知道自己走到哪一步（真机首测反馈）。

    static func suggestedName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return String(format: L10n("Screen Recording %@"), formatter.string(from: Date())) + ".mov"
    }

    /// 目录可写 + 最低安全空间（计划 §9.1，阈值 `max(1 GiB, 两分钟估算)`）。
    func preflightDestination(
        _ url: URL, pixelSize: CGSize, frameRate: ProjectFrameRate
    ) -> ScreenRecordingError? {
        let directory = url.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: directory.path) else {
            return .outputNotWritable
        }
        let required = ScreenRecordingDiskBudget.minimumRequiredBytes(
            pixelSize: pixelSize, frameRate: frameRate
        )
        guard let free = availableBytes(at: url) else { return nil }
        if free < required {
            return .insufficientDiskSpace(requiredBytes: required, availableBytes: free)
        }
        return nil
    }

    func availableBytes(at url: URL) -> Int64? {
        let directory = url.deletingLastPathComponent()
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: 崩溃恢复

    /// 启动时调用。**只处理 manifest 点名的精确路径，禁止 glob。**
    ///
    /// 动作裁决全部交给纯函数 `ScreenRecordingRecoveryPlan.make`（两路都看），
    /// 清账一律走 `ScreenRecordingRecoveryLedger.canClearManifest`。
    /// 早先这里只按主文件裁决分支，会把「主文件已提交、mic 临时文件还在」
    /// 当垃圾删掉，也会把「已提交但没入轨」直接清账（复审 P1-3）。
    func recoverIfNeeded() async {
        // **只跑一次，而且只在完全空闲时跑。**
        //
        // 它挂在 `VideoEditView.task` 上，而那个 task 在「切到别的工具再切回
        // Edit Video」时会重跑。没有这道闸的话，录制进行中切回来会读到
        // **当前正在写的 manifest**，然后 probe、提示、甚至删掉当前临时文件
        // （复审二 P1-5）。
        guard !hasAttemptedRecovery else { return }
        guard state == .idle, manifest == nil, pendingRecovery == nil else { return }
        hasAttemptedRecovery = true

        let loaded: ScreenRecordingManifest?
        do {
            loaded = try store.load()
        } catch {
            // 损坏的 manifest **保留并如实报告**，不静默删除
            // （`docs/architecture/screen-recording-lifecycle.md` 的明文要求）。
            VideoEditProject.shared.notice = L10n(
                "SrtFlow found a damaged screen-recording record from the last session and left it untouched."
            )
            return
        }
        guard let manifest = loaded else { return }

        let plan = ScreenRecordingRecoveryPlan.make(
            manifest: manifest,
            mainObservation: observe(
                temporary: manifest.mainTemporaryPath, final: manifest.mainFinalPath
            ),
            microphoneObservation: manifest.micTemporaryPath.flatMap { temp in
                manifest.micFinalPath.map { observe(temporary: temp, final: $0) }
            }
        )

        switch plan.action {
        case .waitForVolume:
            return   // 卷不可达：保留 manifest，什么都不做

        case .offerSalvage(let mainTemp, let micTemp):
            // 临时文件还在。**决定前不许清账、不许删。**
            //
            // 两路各自独立判定。`mainTemp == nil` 表示主文件**已经提交**、
            // 只有 mic 临时文件可救；早先这里回退到 `manifest.mainTemporaryPath`
            // 去 probe 一个已经不存在的路径，probe 必然失败，于是走进
            // 「救不回来」分支把那份**完好的 mic 录音删掉并清账** ——
            // 自检明明产出了正确的 offerSalvage，生产代码却删了文件（复审二 P1-2）。
            let mainSource: URL? = mainTemp.map { URL(fileURLWithPath: $0) }
                ?? (plan.mainResolution == .committed
                    ? URL(fileURLWithPath: manifest.mainFinalPath) : nil)
            let mainProbe = mainSource == nil ? nil : await ScreenRecordingProbe.info(mainSource!)
            let micSource = micTemp.map { URL(fileURLWithPath: $0) }
            let micUsable = micSource == nil
                ? false
                : await ScreenRecordingProbe.audioDuration(micSource!) != nil

            let mainUsable = (mainProbe?.duration ?? 0) > 0
            guard mainUsable || micUsable else {
                // 两路都救不回来：只删 manifest 点名的临时路径。
                // **删干净了才算了结**（复审四 P1-3）。
                let undeleted = removeExactly([mainTemp, micTemp].compactMap { $0 })
                guard undeleted.isEmpty else {
                    reportUndeleted(undeleted)
                    return   // 账本保留
                }
                clearManifest(plan, disposition: .settled)
                return
            }
            guard let mainSource, mainUsable else {
                // 主文件救不回来、只剩麦克风。
                //
                // **不能把 `.m4a` 塞进 `mainURL` 冒充视频结果** —— 入轨路径
                // 必然按视频 probe，Add 注定失败；计划 §9.2-3 也写明「mic 只有
                // 在能与有效主文件建立对应关系时才提示恢复」（复审三 P1-3）。
                // 按 §9.2-4「至少把精确路径展示给用户」，走纯音频变体：
                // 只给保留/丢弃，不给「加入时间线」。
                present(
                    PendingRecovery(
                        manifest: manifest, plan: plan,
                        kind: .microphoneOnly,
                        needsCommit: micTemp != nil,
                        documentGeneration: VideoEditProject.shared.currentDocumentGeneration,
                        result: ScreenRecordingResult(
                            mainURL: micSource!,
                            duration: 0, pixelSize: .zero, frameRate: .fallback, isPartial: true,
                            partialReason: L10n("Only the microphone audio from the interrupted recording could be recovered — the screen recording itself is unusable.")
                        )
                    )
                )
                return
            }
            present(
                PendingRecovery(
                    manifest: manifest,
                    plan: plan,
                    kind: .recording,
                    // 只有还在临时路径的那部分才需要提交。
                    needsCommit: mainTemp != nil || micTemp != nil,
                    documentGeneration: VideoEditProject.shared.currentDocumentGeneration,
                    result: ScreenRecordingResult(
                        mainURL: mainSource,
                        microphoneURL: micUsable ? micSource : nil,
                        duration: mainProbe?.duration ?? 0,
                        pixelSize: mainProbe?.displaySize ?? .zero,
                        frameRate: .fallback,
                        isPartial: true,
                        partialReason: L10n("SrtFlow quit while this recording was still being written.")
                    )
                )
            )

        case .offerImport(let mainFinal, let micFinal, let microphoneMissing):
            // 文件已经是用户的了，只是上次没来得及入轨 —— 现在补问一次。
            let url = URL(fileURLWithPath: mainFinal)
            guard let probe = await ScreenRecordingProbe.info(url), probe.duration > 0 else {
                clearManifest(plan, disposition: .settled)
                return
            }
            present(PendingRecovery(
                manifest: manifest,
                plan: plan,
                kind: .recording,
                needsCommit: false,
                documentGeneration: VideoEditProject.shared.currentDocumentGeneration,
                result: ScreenRecordingResult(
                    mainURL: url,
                    microphoneURL: micFinal.map { URL(fileURLWithPath: $0) },
                    duration: probe.duration,
                    pixelSize: probe.displaySize,
                    frameRate: .fallback,
                    // 麦克风丢了就**不是完整录制** —— 早先这里写死
                    // `isPartial: false`，用户会以为旁白也成功了（复审四 P1-5）。
                    isPartial: microphoneMissing,
                    partialReason: microphoneMissing
                        ? L10n("This recording was saved but never added to the timeline. Its microphone track is missing.")
                        : L10n("This recording was saved but never added to the timeline.")
                )
            ))

        case .reportMissing(let paths):
            VideoEditProject.shared.notice = String(
                format: L10n("A recording from the last session is no longer where it was saved: %@"),
                paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            )
            clearManifest(plan, disposition: .settled)

        case .discardTemporaries(let paths):
            let undeleted = removeExactly(paths)
            guard undeleted.isEmpty else {
                reportUndeleted(undeleted)
                return   // 账本保留
            }
            clearManifest(plan, disposition: .settled)
        }
    }

    /// 端出恢复提示，**同时进入锁工程的状态**。
    ///
    /// 只设 `pendingRecovery` 是不够的：等用户决定期间状态还是 `.idle`，
    /// 工程可以随便切、新录制可以随便开（复审三 P1-1）。
    private func present(_ pending: PendingRecovery) {
        guard transition(to: .partialRecovery(pending.result)) else { return }
        pendingRecovery = pending
    }

    /// 自动清理的**唯一入口**：精确删除 → **复核路径确实不在了** → 才算了结。
    ///
    /// `try? removeItem` 之后无条件清账是个反复出现的坑：删除一旦失败，
    /// 隐藏的临时文件还在，而唯一的账本没了 —— 那份文件再也没人认领
    /// （复审四 P1-3）。所有自动清理路径都必须走这里，不许各写各的。
    ///
    /// - Returns: 仍然存在（即删除没成功）的路径。空数组才允许 settled。
    @discardableResult
    func removeExactly(_ paths: [String]) -> [String] {
        let manager = FileManager.default
        var remaining: [String] = []
        for path in paths where manager.fileExists(atPath: path) {
            try? manager.removeItem(atPath: path)
            // 复核：以文件系统的实测为准，不信 removeItem 的返回。
            if manager.fileExists(atPath: path) { remaining.append(path) }
        }
        return remaining
    }

    /// 删不掉时如实报告，并**保留账本**。
    func reportUndeleted(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        VideoEditProject.shared.notice = String(
            format: L10n("These files couldn’t be deleted, so the recording is still on record: %@"),
            paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        )
    }

    /// **清 manifest 的唯一入口。** 判据是 ledger，不是文件现场。
    func clearManifest(_ plan: ScreenRecordingRecoveryPlan, disposition: RecoveryDisposition) {
        let ledger = ScreenRecordingRecoveryLedger(
            main: .init(resolution: plan.mainResolution, disposition: disposition),
            microphone: plan.microphoneResolution.map {
                .init(resolution: $0, disposition: disposition)
            }
        )
        guard ledger.canClearManifest else { return }
        try? store.clear()
    }

    /// 观察一对路径。所在卷不可达时返回 `.volumeUnavailable`。
    private func observe(
        temporary: String, final: String
    ) -> ScreenRecordingManifest.DirectoryObservation {
        let directory = (final as NSString).deletingLastPathComponent
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .volumeUnavailable
        }
        return .reachable(
            tempExists: FileManager.default.fileExists(atPath: temporary),
            finalExists: FileManager.default.fileExists(atPath: final)
        )
    }

    /// 用户处理完恢复提示后调用。
    ///
    /// **「保留文件」就是保留。** 早先这个分支实际执行的是删除 —— 按钮写着
    /// Keep file only 却把文件删了，是直接的数据丢失（复审 P1-3）。删除只在
    /// 用户明确选 Discard 时发生。
    func resolveRecovery(_ decision: RecoveryDecision) async {
        guard let pending = pendingRecovery else { return }
        // 状态在 `present()` 时就已经是 `.partialRecovery`（锁着工程切换）。
        pendingRecovery = nil
        defer {
            // **必须无条件回到 idle。**
            //
            // 早先写的是 `if state.isBusy`，而这里的终点恰恰是 `.finished` /
            // `.failed` —— 两者 `isBusy == false`，于是状态永久停在终态，
            // `begin()` 只接受 `.idle`，Record Screen 看着能点、实际再也没反应
            // （复审三 P1-1）。
            transition(to: .idle)
        }

        switch decision {
        case .discard:
            // 只删 manifest 点名的精确路径 —— 而且是**全部**点名路径，
            // 不只是 result 里映射到的那两个（result 可能没带上无效的主临时
            // 文件或 mic 文件，只删 result 会留下孤儿；复审三 P1-3）。
            let undeleted = removeExactly(pending.discardablePaths)
            guard undeleted.isEmpty else {
                // 删除没成功就**不能标 settled** —— 那些文件还在，账本一清
                // 就再也没人认领了（复审三 P1-5）。
                reportUndeleted(undeleted)
                return
            }
            clearManifest(pending.plan, disposition: .settled)

        case .keepFile, .addToTimeline:
            // 先把还在临时路径的文件提交到用户当初选的位置 —— 隐藏的 .partial
            // 文件对用户毫无意义，「保留」必须保留成看得见的文件。
            var result = pending.result
            if pending.needsCommit {
                do {
                    result = try commitRecovered(pending)
                } catch {
                    VideoEditProject.shared.notice = String(
                        format: L10n("That recovered recording couldn’t be saved: %@"),
                        error.localizedDescription
                    )
                    return   // manifest 保留，下次启动再问
                }
            }
            if decision == .addToTimeline, pending.kind == .recording {
                guard transition(to: .importing) else { return }
                let imported = await VideoEditProject.shared.importRecoveredRecording(
                    result, documentGeneration: pending.documentGeneration,
                    sessionID: pending.manifest.sessionID
                )
                guard imported else {
                    // 入轨没成 → 事务未提交 → **不许清账**，下次还要能提示。
                    clearManifest(pending.plan, disposition: .importPending)
                    transition(to: .failed(.writerFailed(message: L10n("The recovered recording wasn’t added to the timeline."))))
                    return
                }
                // **先清账再进解锁态。** `.finished` 是非忙状态，会立刻触发
                // 退出答复；正在 Quit 时进程可能在清账之前就退出了，下次启动
                // 会再提示一次并重复入轨（复审四 P1-4）。
                clearManifest(pending.plan, disposition: .settled)
                transition(to: .finished(result))
                return
            } else {
                VideoEditProject.shared.notice = String(
                    format: L10n("The recovered recording was saved as %@."),
                    result.mainURL.lastPathComponent
                )
            }
            clearManifest(pending.plan, disposition: .settled)
        }
    }

    /// 把恢复出来的临时文件按 journal 协议提交到最终路径。
    ///
    /// 三条约束：
    /// 1. 最终路径已有文件时**避让到空位**，不覆盖：用户在上一次会话里同意的
    ///    是那一次的覆盖，不能拿来授权这一次（复审 P1-3）。
    /// 2. **避让后的目标要先写进 manifest 再持久化意向，然后才动文件**
    ///    —— 反过来会让账本记的路径和文件实际去处不一致（复审二 P1-3）。
    /// 3. **只提交实际存在的临时文件。** 主文件早已提交、只剩 mic 可救时，
    ///    无条件重新提交缺失的 main temp 会直接抛错，把整个恢复毁掉
    ///    （复审二 P1-2）。
    private func commitRecovered(_ pending: PendingRecovery) throws -> ScreenRecordingResult {
        let manager = FileManager.default
        var manifest = pending.manifest
        var result = pending.result
        let isTaken: (URL) -> Bool = { manager.fileExists(atPath: $0.path) }

        // 纯音频恢复时主临时文件已被 probe 判为无效 —— **不能提交它**，
        // 提交等于把一个打不开的文件塞给用户（复审三 P1-3）。
        // 也不能就这么留着：账本随后会被清掉，它就成了无人认领的隐藏文件
        // （复审四 P1-1）。这里精确删除；删不掉的由调用方保留账本。
        if pending.kind == .microphoneOnly {
            reportUndeleted(removeExactly([manifest.mainTemporaryPath]))
        }
        if pending.kind == .recording,
           manager.fileExists(atPath: manifest.mainTemporaryPath) {
            let target = ScreenRecordingFileNaming.availableURL(
                like: URL(fileURLWithPath: manifest.mainFinalPath), isTaken: isTaken
            )
            manifest = manifest.retargetingMain(to: target.path)
            manifest.stage = .committingMain
            try store.persist(manifest)      // ← 栅栏：目标已冻结并落账
            try manager.moveItem(at: URL(fileURLWithPath: manifest.mainTemporaryPath), to: target)
            result.mainURL = target
            manifest.stage = .mainCommitted
            try store.persist(manifest)
        }

        if let micTemp = manifest.micTemporaryPath, let micFinal = manifest.micFinalPath,
           manager.fileExists(atPath: micTemp) {
            let target = ScreenRecordingFileNaming.availableURL(
                like: URL(fileURLWithPath: micFinal), isTaken: isTaken
            )
            manifest = manifest.retargetingMicrophone(to: target.path)
            // **纯 mic 用独立阶段。** 复用 `committingMicrophone` / `allCommitted`
            // 会让 `mainResolution` 无条件认定主文件已提交，而这条流程恰恰
            // 从没提交过主文件（复审四 P1-1）。
            let isMicrophoneOnly = pending.kind == .microphoneOnly
            manifest.stage = isMicrophoneOnly ? .microphoneOnlyCommitting : .committingMicrophone
            try store.persist(manifest)
            try manager.moveItem(at: URL(fileURLWithPath: micTemp), to: target)
            result.microphoneURL = target
            // 纯 mic 时 result.mainURL 原本指向那个**已经被移走**的临时 .m4a，
            // 「saved as」文案会报一个不存在的路径（复审四 P2）。
            if isMicrophoneOnly { result.mainURL = target }
            manifest.stage = isMicrophoneOnly ? .microphoneOnlyCommitted : .allCommitted
            try store.persist(manifest)
        }
        return result
    }

    // MARK: App 退出协调（计划 §12.2）

    /// `applicationShouldTerminate` 调它。返回 false 表示要 `.terminateLater`。
    ///
    /// 两条早先的坑（复审 P1-1）：
    /// - 配置期（configuring/choosingSource/choosingDestination/preparing）被
    ///   `stop()` 的 default 分支静默忽略，`.terminateLater` 永远等不到 reply，
    ///   App 卡死退不掉。现在这些状态一律先撤销会话。
    /// - 收尾完成后直接 `reply(true)`，跳过了
    ///   `VideoEditProject.prepareToCloseDocument()`，未命名工程不会问保存。
    ///   现在由 `settleTerminationIfPossible()` 统一经过文档那一关。
    func prepareToTerminate() -> Bool {
        switch state {
        case .idle, .finished, .failed:
            return true
        case .configuring, .choosingSource, .choosingDestination, .preparing, .countingDown:
            // 还没写过一个字节，撤销即可，不需要等异步收尾。
            invalidateSession()
            return true
        case .starting, .recording, .stopping, .finishing, .importing, .partialRecovery:
            beginTerminationWait()
            Task { @MainActor in
                await self.stop()
                self.settleTerminationIfPossible()
            }
            return false
        }
    }
}

@available(macOS 15.0, *)
extension ScreenRecordingError {
    var localizedText: String {
        switch self {
        case .screenCaptureNotAuthorized:
            // **不能写「你拒绝过」** —— -3801 同样覆盖「从未授权」（门槛 1）。
            return L10n("SrtFlow doesn’t have permission to record the screen yet. Turn it on in System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording. If the switch is already on, turn it off and on again.")
        case .pickerCancelled:
            return L10n("Source selection was cancelled.")
        case .sourceUnavailable:
            return L10n("That source is no longer available.")
        case .microphoneNotAuthorized:
            return L10n("SrtFlow doesn’t have microphone permission, so narration wasn’t recorded. The screen recording itself is fine.")
        case .insufficientDiskSpace(let required, let available):
            return String(
                format: L10n("Not enough free space: %@ needed, %@ available."),
                MediaFormatting.bytes(required), MediaFormatting.bytes(available)
            )
        case .diskFullDuringRecording:
            return L10n("The disk ran out of space, so the recording is incomplete.")
        case .streamFailed(let message), .writerFailed(let message):
            return message
        case .outputNotWritable:
            return L10n("That folder can’t be written to. Pick another location.")
        case .controlWindowUnavailable:
            return L10n("SrtFlow couldn’t hide its own recording controls from the capture, so it didn’t start. Try again.")
        case .ambiguousSource:
            return L10n("SrtFlow couldn’t tell which display you picked (two look identical). Record a window or a custom region instead, or update to macOS 15.2 or later.")
        }
    }
}

/// 崩溃恢复的三选一。**「保留文件」不得删除文件**（复审 P1-3）。
enum RecoveryDecision {
    /// 明确丢弃：删除 manifest 点名的精确路径。
    case discard
    /// 保留成看得见的文件，但不进时间线。
    case keepFile
    /// 保留并加入时间线。
    case addToTimeline
}

/// 待用户处置的上次残留。带着 manifest 和裁决结果，
/// 这样处置完才能按 ledger 决定要不要清账。
@available(macOS 15.0, *)
struct PendingRecovery: Identifiable {
    /// 这份残留是什么。
    enum Kind {
        /// 有可用的主视频（可以入轨）。
        case recording
        /// 主视频不可用，只剩麦克风音频。
        ///
        /// **不提供「加入时间线」** —— 入轨路径按视频 probe，纯音频必然失败；
        /// 计划 §9.2-3 也规定 mic 只有能与有效主文件对应时才提示恢复。
        /// 这里按 §9.2-4 把精确路径展示给用户，让他保留或丢弃（复审三 P1-3）。
        case microphoneOnly
    }

    let manifest: ScreenRecordingManifest
    let plan: ScreenRecordingRecoveryPlan
    let kind: Kind
    /// 文件还在临时路径、需要先提交到最终位置。
    let needsCommit: Bool
    /// 呈现恢复提示那一刻的工程身份。用户可能在弹窗开着时切工程，
    /// 入轨前必须比对（复审二 P1-6）。
    let documentGeneration: Int
    let result: ScreenRecordingResult

    var id: String { result.mainURL.path }

    /// 能不能提供「丢弃」。
    ///
    /// 文件已经提交到用户选的位置时**不给** —— 那已经是用户的文件了，
    /// 一个恢复提示不该顺手把它删掉。
    ///
    /// 判据是「**没有任何一路已经提交**」，不是 `needsCommit`：
    /// 「主文件已提交、只剩 mic 临时文件待处理」的混合态里 `needsCommit`
    /// 为真，却仍会显示 Discard，与合同不符（复审四 P2）。
    var allowsDiscard: Bool {
        needsCommit
            && plan.mainResolution != .committed
            && plan.microphoneResolution != .committed
    }

    /// 丢弃时要删的**全部**精确路径（只取 manifest 点名的临时路径）。
    ///
    /// 不能只删 `result` 里的两个 URL：主临时文件 probe 无效时不会进 result，
    /// 只删 result 会把它留成孤儿（复审三 P1-3）。最终路径一律不删。
    var discardablePaths: [String] {
        [manifest.mainTemporaryPath, manifest.micTemporaryPath].compactMap { $0 }
    }
}
