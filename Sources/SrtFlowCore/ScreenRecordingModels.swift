import CoreGraphics
import Foundation

// 录屏的值类型：request / source / result / error / state / 临时文件 manifest。
// 全部是纯数据，放 SrtFlowCore 以便自检覆盖；ScreenCaptureKit 的类型不在这里出现，
// 桥接留给 App 层（计划 §4.2 的职责边界）。

// MARK: - 来源

/// 录制来源的三种形态（计划 §1 已确认的产品决策）。
public enum ScreenRecordingSource: Hashable, Sendable {
    /// 整块显示器。
    case display(displayID: UInt32)
    /// 单个窗口。picker 返回的 filter 直接用，**不为排除控制窗重建**
    /// （计划 §20：单窗口来源保留 picker 原 filter）。
    case window(windowID: UInt32)
    /// 单块显示器内的自定义区域。跨屏不支持。
    case region(displayID: UInt32, rectInPoints: CGRect)

    public var displayID: UInt32? {
        switch self {
        case .display(let id): return id
        case .region(let id, _): return id
        case .window: return nil
        }
    }

    /// 是否需要为排除录制控制窗而重建 filter。
    /// 单窗口来源不需要——picker 给的 filter 本来就只含那个窗口。
    public var needsControlWindowExclusion: Bool {
        switch self {
        case .display, .region: return true
        case .window: return false
        }
    }
}

/// 自定义区域的比例档（计划 §1）。
public enum RegionAspectRatio: String, CaseIterable, Hashable, Sendable, Identifiable {
    case free, wide16x9, tall9x16, standard4x3, tall3x4, square

    public var id: String { rawValue }

    /// 宽 / 高。自由模式返回 nil。
    public var value: CGFloat? {
        switch self {
        case .free: return nil
        case .wide16x9: return 16.0 / 9
        case .tall9x16: return 9.0 / 16
        case .standard4x3: return 4.0 / 3
        case .tall3x4: return 3.0 / 4
        case .square: return 1
        }
    }

    public var title: String {
        switch self {
        case .free: return "Free"
        case .wide16x9: return "16:9"
        case .tall9x16: return "9:16"
        case .standard4x3: return "4:3"
        case .tall3x4: return "3:4"
        case .square: return "1:1"
        }
    }
}

/// 麦克风配置。
///
/// **刻意不用 `Bool + String?`**：那种建模允许「开了麦克风但没有设备 ID」这种
/// 非法状态存在，只能靠运行期检查兜。Phase 0 门槛 2 实测 `captureMicrophone`
/// 必须传**已解析**的 `AVCaptureDevice.uniqueID`，所以设备 ID 是「开启」的
/// 固有组成部分，用关联值表达。
public enum MicrophoneConfiguration: Hashable, Sendable {
    /// 不录麦克风。这是默认（计划 §1）。
    case disabled
    /// 录指定设备。`deviceID` 是 `AVCaptureDevice.uniqueID`，调用方必须先解析。
    case device(id: String)

    public var isEnabled: Bool {
        if case .device = self { return true }
        return false
    }

    public var deviceID: String? {
        if case .device(let id) = self { return id }
        return nil
    }
}

/// 指针与点击效果（计划 §1：指针开、点击效果开/关）。
///
/// 点击效果**只用系统 API 的结果**，不引入事件监听或自绘兜底（计划 §17.1-7）。
/// Phase 0 门槛 7 实测：两个开关都生效，但点击效果只闪现几百毫秒，
/// 单帧取样必然错过 —— 相关自检要连续收帧取峰值。
public struct CursorConfiguration: Hashable, Sendable {
    public var showsCursor: Bool
    public var showsClicks: Bool

    public init(showsCursor: Bool = true, showsClicks: Bool = false) {
        self.showsCursor = showsCursor
        self.showsClicks = showsClicks
    }

    public static let `default` = CursorConfiguration()
}

// MARK: - 请求

/// 一次录制请求。**开始录制时快照，全程不再读界面** ——
/// 录制期间用户可能改画布比例又改回来（计划 §20 点名的用例），
/// 导入时必须拿这份快照比对，而不是读当下的界面值。
public struct ScreenRecordingRequest: Hashable, Sendable {
    /// 本次录制的身份。临时文件名、manifest、异步回调的归属判定全靠它。
    ///
    /// **身份要随触发源传递**——这条是仓库既有的教训（见
    /// `docs/bugfixes/2026-08-06-subtitle-generation-review.md`：
    /// 「进门才读『当前值』等于没有身份」）。
    public let sessionID: UUID
    public let source: ScreenRecordingSource
    /// 录电脑声音。默认开。
    public let capturesSystemAudio: Bool
    /// 麦克风配置。默认 `.disabled`（计划 §1）。
    public let microphone: MicrophoneConfiguration
    public let cursor: CursorConfiguration
    public let frameRate: ProjectFrameRate
    /// 用户在 Save 面板里选的主文件位置。
    public let outputURL: URL

    /// **开录前就冻结的最终捕获像素尺寸。**
    ///
    /// 必须在这里定死，不能录完再算：显示器可能中途改分辨率、拔插、切缩放档。
    /// 值已经过「真实像素 → 硬件编码单边 ≤4096 → 偶数」三道处理
    /// （见 `ScreenRecordingCoordinateMapper.captureSize`）。
    public let capturePixelSize: CGSize

    /// 发起录制时的工程身份代号。导入结果时必须比对 ——
    /// 跨 `await` 回来工程可能已经被切走（仓库既有约束：
    /// `VideoEditProject.documentGeneration`）。
    public let documentGeneration: Int
    /// 开始录制那一刻的工程画布比例快照。
    public let canvasRatioSnapshot: String
    /// 开始录制那一刻的画布编辑代号。值与代号**都**没变，才允许自动套用录制比例
    /// （计划 §20 点名的「录制期间改比例又改回来」用例）。
    public let canvasEditGeneration: Int
    /// 开始录制时工程是否已有视觉素材。有的话不自动改画布。
    public let projectHadVisualMedia: Bool

    /// 麦克风 sidecar 的**实际**最终路径。
    ///
    /// 默认路径（主文件同名 + `-Mic.m4a`）可能已经被上一次录制占用，而用户
    /// 只在 Save 面板里确认过覆盖**主文件**，从没同意过覆盖 sidecar。所以
    /// coordinator 会在开录前避让出一个空位并从这里传进来（复审 P1-2）。
    private let microphoneOutputOverride: URL?

    public init(
        sessionID: UUID,
        source: ScreenRecordingSource,
        capturesSystemAudio: Bool = true,
        microphone: MicrophoneConfiguration = .disabled,
        cursor: CursorConfiguration = .default,
        frameRate: ProjectFrameRate = .fallback,
        outputURL: URL,
        capturePixelSize: CGSize,
        documentGeneration: Int,
        canvasRatioSnapshot: String,
        canvasEditGeneration: Int,
        projectHadVisualMedia: Bool,
        microphoneOutputURL: URL? = nil
    ) {
        self.microphoneOutputOverride = microphoneOutputURL
        self.sessionID = sessionID
        self.source = source
        self.capturesSystemAudio = capturesSystemAudio
        self.microphone = microphone
        self.cursor = cursor
        self.frameRate = frameRate
        self.outputURL = outputURL
        self.capturePixelSize = capturePixelSize
        self.documentGeneration = documentGeneration
        self.canvasRatioSnapshot = canvasRatioSnapshot
        self.canvasEditGeneration = canvasEditGeneration
        self.projectHadVisualMedia = projectHadVisualMedia
    }

    /// 麦克风的 sidecar 路径：主文件同目录、同名加 `-Mic`、扩展名 `.m4a`。
    /// 该名字被占用时 coordinator 会传入避让后的路径。
    public var microphoneURL: URL {
        microphoneOutputOverride ?? Self.defaultMicrophoneURL(for: outputURL)
    }

    /// 默认 sidecar 路径（未避让）。
    public static func defaultMicrophoneURL(for outputURL: URL) -> URL {
        let base = outputURL.deletingPathExtension().lastPathComponent
        return outputURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(base)-Mic")
            .appendingPathExtension("m4a")
    }

    /// 为 sidecar 找一个不会覆盖任何已有文件的名字。
    ///
    /// 纯函数：占用判定由 `isTaken` 注入，测试才能反证（复审 P1-2）。
    /// 返回 `-Mic.m4a`、`-Mic 2.m4a`、`-Mic 3.m4a`… 里第一个空位。
    public static func availableMicrophoneURL(
        for outputURL: URL, isTaken: (URL) -> Bool
    ) -> URL {
        ScreenRecordingFileNaming.availableURL(
            like: defaultMicrophoneURL(for: outputURL), isTaken: isTaken
        )
    }

    /// 写入期间用的临时文件（同目录 sibling，保证最后是同卷 rename 而不是跨卷拷贝）。
    /// **完整 UUID** 进文件名：8 位短码在「残留 + 新会话」并存的目录里有
    /// 撞名概率，撞上就是互相覆盖。
    public func temporaryURL(for kind: TemporaryKind) -> URL {
        let target = kind == .main ? outputURL : microphoneURL
        let base = target.deletingPathExtension().lastPathComponent
        let ext = target.pathExtension
        return target
            .deletingLastPathComponent()
            .appendingPathComponent(".\(base).\(sessionID.uuidString).partial")
            .appendingPathExtension(ext)
    }

    public enum TemporaryKind: String, Hashable, Sendable {
        case main, microphone
    }
}

// MARK: - 状态机

/// 录制状态机（计划 §12）。允许的迁移见 `canTransition`。
///
/// 比最初的版本细：早先只有 idle/preparing/countingDown/recording/finishing/
/// finished/failed 七个态，问题是 **`.finished` / `.failed` 一到就解除了工程锁**，
/// 而那时导入事务和 partial 决策往往还没做完 —— 用户此刻切工程，素材会进错工程。
public enum ScreenRecordingState: Hashable, Sendable {
    case idle
    /// 在录制设置面板里配来源、音频、比例。还没选目标位置。
    case configuring
    /// 正在等系统 picker 或区域 overlay 的结果。用户可能取消（不是错误）。
    case choosingSource
    /// 正在等 Save 面板。取消不产生任何文件。
    case choosingDestination
    /// 已确认全部参数，正在准备（建 Stop 窗、解析 filter、预检空间）。
    case preparing
    /// 倒计时中，还没真正开录。此时取消是干净的，不产生文件。
    case countingDown(remaining: Int)
    /// 已下达开始指令，等 `SCStream.startCapture()` 返回。
    /// 这一段必须能表达，否则「启动中按 Stop」无处安放。
    case starting
    case recording(startedAt: Date)
    /// 已请求停止，正在让 stream 停下。
    case stopping
    /// stream 停了，writer 在 finalize（endSession + finishWriting + 原子提交）。
    case finishing
    /// 文件已提交，正在做单事务入轨。**工程锁仍然生效**。
    case importing
    /// 结果残缺，等用户决定保留还是丢弃。**工程锁仍然生效**。
    case partialRecovery(ScreenRecordingResult)
    case finished(ScreenRecordingResult)
    case failed(ScreenRecordingError)

    /// 是否处在「录制流程进行中」。
    public var isBusy: Bool {
        switch self {
        case .idle, .finished, .failed:
            return false
        case .configuring, .choosingSource, .choosingDestination, .preparing,
             .countingDown, .starting, .recording, .stopping, .finishing,
             .importing, .partialRecovery:
            return true
        }
    }

    /// 是否正在往磁盘写。用于「退出时要不要拦」和低空间监测。
    public var isWritingToDisk: Bool {
        switch self {
        case .starting, .recording, .stopping, .finishing: return true
        default: return false
        }
    }

    /// 录制期间必须锁住工程切换（New / Open / Open Recent / Finder 打开）。
    ///
    /// **`.importing` 与 `.partialRecovery` 也要锁** —— 文件虽然写完了，但入轨
    /// 事务还没提交、或用户还没决定 partial 怎么处理，此时切工程会让素材进错工程。
    /// 计划 §3.4：这些动作的**执行入口**要再校验一次，不能只靠按钮 disabled。
    public var locksProjectSwitching: Bool { isBusy }

    /// 状态机合法迁移。重复 Stop、stale 回调都靠它挡掉。
    public static func canTransition(from: Self, to: Self) -> Bool {
        switch (from, to) {
        // 配置阶段：可以在几个选择步骤之间来回，也可以随时取消回 idle
        case (.idle, .configuring),
             (.configuring, .choosingSource), (.configuring, .choosingDestination),
             (.configuring, .idle), (.configuring, .failed),
             (.choosingSource, .configuring), (.choosingSource, .idle),
             (.choosingSource, .failed),
             // **选完来源 → 选保存位置**：`start()` 的正常下一步。
             // 这条边一度缺失，于是 `transition` 静默返回 false
             // （它是 `@discardableResult`），状态卡在 `.choosingSource`，
             // 后面每一步都被挡掉，`runCountdown()` 的 guard 直接 return，
             // **录制永远不会开始** —— 真机首测就是死在这里。
             // 单边逐条验通不代表整条路走得通，见 `checkStartHappyPath`。
             (.choosingSource, .choosingDestination),
             (.choosingDestination, .configuring), (.choosingDestination, .idle),
             (.choosingDestination, .preparing), (.choosingDestination, .failed):
            return true
        // 准备 → 倒计时 → 启动 → 录制。
        // preparing / countingDown 允许直接 → failed：此时还没写过一个字节，
        // 控制窗等资源的拆除是同步的，coordinator 在置 failed 前完成即可。
        case (.preparing, .countingDown), (.preparing, .failed), (.preparing, .idle),
             (.countingDown, .countingDown), (.countingDown, .starting),
             (.countingDown, .idle), (.countingDown, .failed),
             (.starting, .recording), (.starting, .stopping):
            return true
        // 录制 → 停止 → 收尾。
        //
        // **写盘期（starting / recording / stopping）没有任何直达 .failed 的边。**
        // stream/writer 出错也必须走 stopping → finishing：把 stream 停干净、
        // writer finalize 或作废、manifest 按实际情况推进、控制窗拆掉，
        // 然后由 finishing 决定 partialRecovery 还是 failed。
        // 原因：.failed 是解锁工程切换的终态，直达它意味着清理还没做完
        // 用户就能切工程 —— 素材会进错工程（复审 P1）。错误本身由 coordinator
        // 随路携带，不靠状态编码。
        case (.recording, .stopping),
             (.stopping, .finishing),
             (.finishing, .importing), (.finishing, .partialRecovery),
             (.finishing, .failed):
            return true
        // 收尾之后：入轨 / partial 决策 → 终态
        case (.importing, .finished), (.importing, .failed),
             (.partialRecovery, .importing), (.partialRecovery, .idle),
             (.partialRecovery, .failed):
            return true
        // 崩溃恢复：启动时发现上次残留，用户处置期间**同样要锁工程切换**，
        // 所以从 idle 直接进 partialRecovery（复审二 P1-6）。
        // 处置完的去向复用上面 partialRecovery 的那几条边。
        case (.idle, .partialRecovery):
            return true
        // 终态回到空闲
        case (.finished, .idle), (.failed, .idle):
            return true
        default:
            return false
        }
    }
}

// MARK: - 结果

public struct ScreenRecordingResult: Hashable, Sendable {
    public var mainURL: URL
    public var microphoneURL: URL?
    public var duration: Double
    public var pixelSize: CGSize
    public var frameRate: ProjectFrameRate
    /// 结果是否残缺（ENOSPC、stream 中断等）。**残缺必须显式告诉用户**，
    /// 不能当成功处理（Phase 0 门槛 12：音频溢出丢弃、磁盘满都会到这里）。
    public var isPartial: Bool
    /// 残缺原因，用于界面文案。
    public var partialReason: String?

    public init(
        mainURL: URL, microphoneURL: URL? = nil, duration: Double,
        pixelSize: CGSize, frameRate: ProjectFrameRate,
        isPartial: Bool = false, partialReason: String? = nil
    ) {
        self.mainURL = mainURL
        self.microphoneURL = microphoneURL
        self.duration = duration
        self.pixelSize = pixelSize
        self.frameRate = frameRate
        self.isPartial = isPartial
        self.partialReason = partialReason
    }
}

// MARK: - 文件命名避让

/// 「绝不覆盖没被明确确认过的文件」的命名规则。
///
/// 用户只在 Save 面板里确认过**主文件**的覆盖。麦克风 sidecar、崩溃恢复出来的
/// 文件都没经过那一步，所以一律避让到空位而不是替换（复审 P1-2 / P1-3）。
public enum ScreenRecordingFileNaming {
    /// 纯函数：`isTaken` 注入占用判定，测试才能反证。
    /// 返回 `名字.ext`、`名字 2.ext`、`名字 3.ext`… 里第一个空位。
    public static func availableURL(like target: URL, isTaken: (URL) -> Bool) -> URL {
        guard isTaken(target) else { return target }
        let stem = target.deletingPathExtension().lastPathComponent
        let ext = target.pathExtension
        let directory = target.deletingLastPathComponent()
        for index in 2...999 {
            let candidate = directory
                .appendingPathComponent("\(stem) \(index)")
                .appendingPathExtension(ext)
            if !isTaken(candidate) { return candidate }
        }
        return target
    }
}

// MARK: - 错误

public enum ScreenRecordingError: Error, Hashable, Sendable {
    /// 屏幕录制未授权。
    ///
    /// 注意文案：Phase 0 门槛 1 实测 `SCShareableContent` 对**从未授权**的 App
    /// 也返回「user declined」语义的 -3801，所以**不能**写成「你拒绝过」，
    /// 只能写「未获授权」。
    case screenCaptureNotAuthorized
    /// 用户取消了 picker —— 这不是权限问题，不许当成权限拒绝报（计划 §17.1-1）。
    case pickerCancelled
    /// 来源在开始前消失了（窗口关掉、显示器拔了）。
    case sourceUnavailable
    /// 麦克风未授权。主录制照常继续，只是明确告知没录到麦克风（计划 §1）。
    case microphoneNotAuthorized
    /// 开录前空间预检没过。
    case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)
    /// 录制期间磁盘满。已写的部分按 partial 处理。
    case diskFullDuringRecording
    case streamFailed(message: String)
    case writerFailed(message: String)
    /// 目标位置不可写（只读目录、外置盘拔了）。
    case outputNotWritable
    /// 控制窗没能在可分享内容里找到，因而无法把它排除出画面。
    ///
    /// **必须当失败处理，不能带着空排除集继续录**：那样录出来的整屏画面里
    /// 会永远糊着一个 Stop 浮窗，而用户是在录完之后才发现的（复审 P1-5）。
    case controlWindowUnavailable
    /// 选中的来源无法唯一确定（例如两块同尺寸显示器，且系统版本低到拿不到
    /// `includedDisplays`）。宁可报错也**不许猜**——猜错就是录错屏（复审 P1-5）。
    case ambiguousSource

    /// 是否属于「主录制仍然成立、只是少了某部分」。
    public var isNonFatal: Bool {
        switch self {
        case .microphoneNotAuthorized: return true
        default: return false
        }
    }
}

// MARK: - 崩溃恢复 manifest

/// 活跃录制会话的精确清单。由 `ScreenRecordingManifestStore` 原子落盘
/// （**不是 UserDefaults**，原因见 `CommitStage`），下次启动**只处理点名的路径**。
///
/// 计划 §20 硬性要求：**禁止用宽泛 glob 清理**（那会误删用户自己的文件）。
/// Phase 0 门槛 13 补充了前提：writer 必须设 `movieFragmentInterval`，
/// 否则强杀留下的文件根本打不开，恢复无从谈起。
public struct ScreenRecordingManifest: Codable, Hashable, Sendable {
    /// 提交阶段 —— **journal 式**：每次 rename 之前先把「即将 rename」**持久化**，
    /// rename 之后再推进到「已 rename」。
    ///
    /// 为什么三阶段不够（复审 P1）：状态记录和文件 rename **不是一个事务**。
    /// journal 阶段配合「rename 是同卷原子操作」这一事实，让崩溃点可判定：
    /// 处在 committing 阶段时，**临时文件还在 = rename 没发生；
    /// 临时没了且最终在 = 发生了** —— 用 `mainResolution` / `microphoneResolution`
    /// 结合文件系统实况裁决，不能只看 stage。
    ///
    /// **持久化必须走 `ScreenRecordingManifestStore`，不许用 UserDefaults**：
    /// `UserDefaults.set` 是内存立即生效、磁盘**异步**写入（Apple 文档明说）。
    /// 拿它当 journal，「set 返回 → rename → 崩溃」时意向可能根本没落盘，
    /// 重启仍读到旧阶段 —— journal 的全部意义就没了（复审 P1）。
    ///
    /// **提交协议**（coordinator 必须照此顺序；「persist」指
    /// `ManifestStore.persist()` **成功返回**，这就是持久化栅栏）：
    /// 1. stage = .committingMain，persist
    /// 2. rename 主文件 临时 → 最终
    /// 3. stage = .mainCommitted，persist
    /// 4.（有 mic）stage = .committingMicrophone，persist
    /// 5. rename mic 临时 → 最终
    /// 6. stage = .allCommitted，persist
    /// 7. 恢复裁决全部落定（无 volumeUnavailable）后，store.clear()
    public enum CommitStage: String, Codable, Hashable, Sendable {
        /// 还在往临时文件写，谁都没提交。
        case writing
        /// 已持久化「即将 rename 主文件」的意向，rename 可能发生了也可能没有。
        case committingMain
        /// 主文件已原子提交到最终路径，麦克风 sidecar 还没动。
        case mainCommitted
        /// 已持久化「即将 rename mic」的意向。
        case committingMicrophone
        /// 两个 rename 都做完了。正常情况下 manifest 随后就被清除；还能读到
        /// 说明清除之前崩了 —— **仍要先观察两个最终路径再决定**（卷可能不可达、
        /// 文件可能已缺失），不能仅凭 stage 直接删 manifest（复审 P1）。
        case allCommitted

        // MARK: 纯麦克风恢复的独立阶段（复审四 P1-1）
        //
        // **绝不能复用上面那两个 mic 阶段。** `committingMicrophone` /
        // `allCommitted` 的语义前提是「主文件已经提交」，`mainResolution` 会据此
        // 无条件认定主文件已落到最终路径。而纯 mic 恢复的前提恰恰相反 ——
        // 主文件是**无效**的、从没提交过。复用会造出这个确定反例：
        // 主临时文件损坏、主最终路径上原本就有**用户自己的**文件、mic 临时文件
        // 有效；用户选保留 mic，落盘 `committingMicrophone` 后崩溃；重启后
        // 用户那个无关文件会被当成本次录屏，和 mic 一起提示导入。

        /// 只提交麦克风：已持久化意向，主文件不在本次提交范围内。
        case microphoneOnlyCommitting
        /// 只提交麦克风：rename 完成。主文件**从未提交**。
        case microphoneOnlyCommitted
    }

    /// 恢复时对一条路径所在目录的观察结果。
    ///
    /// 临时文件是最终文件的同目录 sibling（同一个卷），所以一次观察覆盖两条路径。
    /// **「文件不在」和「卷不可达」必须分开**：外置盘没挂载时什么都不能断定，
    /// 更不能清 manifest —— 盘插回来还要继续裁决。
    public enum DirectoryObservation: Hashable, Sendable {
        /// 目录可达；两条路径的存在性是可信的实测。
        case reachable(tempExists: Bool, finalExists: Bool)
        /// 所在卷当前不可达（外置盘未挂载、网络卷断开等）。
        case volumeUnavailable
    }

    /// 恢复时对单个文件的裁决。
    public enum FileResolution: Hashable, Sendable {
        /// 未提交。临时文件（若存在）就是可抢救的 partial；
        /// **最终路径上的文件（若存在）是用户原有的文件，不得动**。
        case notCommitted(tempExists: Bool)
        /// 已落到最终路径且实测存在，是用户的文件，**不得删除**。
        case committed
        /// stage 断定已提交、但最终路径上实测没有文件（卷是可达的）——
        /// 提交后被移动/删除或提交结果异常。**如实报告**，不拿别的文件顶；
        /// 报告完可以清 manifest（留着它也换不回文件）。
        case committedButMissing
        /// 卷不可达：**不做任何决定**，保留 manifest，卷回来后重新裁决。
        case volumeUnavailable
        /// 临时和最终都不在（卷可达）—— 这一份丢了，只能如实报告。
        case lost

        /// 观察本身没有得出结论（卷不可达，什么都断定不了）。
        ///
        /// **这不是「能否清 manifest」** —— 它只描述文件现场。清账要看整个流程
        /// 走到哪了，见 `RecoveryDisposition` / `ScreenRecordingRecoveryLedger`。
        /// 早先叫 `blocksManifestRemoval` 并被当成清账判据，那是把「现场」
        /// 和「流程」混为一谈（复审 P1）。
        public var observationIsInconclusive: Bool { self == .volumeUnavailable }

        /// 现场是否存在一份可抢救的 partial（还没提交的临时文件）。
        public var hasSalvageablePartial: Bool {
            if case .notCommitted(let tempExists) = self { return tempExists }
            return false
        }
    }

    public let sessionID: UUID
    public let startedAt: Date
    /// journal 游标 —— **本类型唯一可变的字段**。身份与四条路径全是 `let`：
    /// 异步代码能改路径的话，文件归属判定就没有根基了（复审 P1）。
    public var stage: CommitStage
    /// 主文件的临时路径。
    public let mainTemporaryPath: String
    /// 主文件的最终路径。
    public let mainFinalPath: String
    /// 麦克风 sidecar 的临时/最终路径（没录麦克风就是 nil）。
    public let micTemporaryPath: String?
    public let micFinalPath: String?

    public init(
        sessionID: UUID, startedAt: Date, stage: CommitStage = .writing,
        mainTemporaryPath: String, mainFinalPath: String,
        micTemporaryPath: String? = nil, micFinalPath: String? = nil
    ) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.stage = stage
        self.mainTemporaryPath = mainTemporaryPath
        self.mainFinalPath = mainFinalPath
        self.micTemporaryPath = micTemporaryPath
        self.micFinalPath = micFinalPath
    }

    /// 换一个麦克风 sidecar 的最终路径，返回新的 manifest。
    ///
    /// **必须在持久化 `committingMicrophone` 意向之前调用**，把最终目标先写进
    /// 账本再动文件。反过来（先落意向、再临时挑一个避让名字）会让 manifest
    /// 记的路径和文件实际去处不一致：rename 之后、stage 更新之前崩溃，恢复时
    /// 观察的是旧路径 —— 要么产生无人认领的孤儿文件，要么把恰好占着旧路径的
    /// 无关文件认成本次 sidecar（复审二 P1-3）。
    ///
    /// 身份（`sessionID`）不变，四条路径依旧是 `let`：这里构造的是新值，
    /// 不是就地修改。
    public func retargetingMicrophone(to finalPath: String) -> ScreenRecordingManifest {
        ScreenRecordingManifest(
            sessionID: sessionID, startedAt: startedAt, stage: stage,
            mainTemporaryPath: mainTemporaryPath, mainFinalPath: mainFinalPath,
            micTemporaryPath: micTemporaryPath, micFinalPath: finalPath
        )
    }

    /// 同上，用于崩溃恢复时主文件也要避让的情形。
    public func retargetingMain(to finalPath: String) -> ScreenRecordingManifest {
        ScreenRecordingManifest(
            sessionID: sessionID, startedAt: startedAt, stage: stage,
            mainTemporaryPath: mainTemporaryPath, mainFinalPath: finalPath,
            micTemporaryPath: micTemporaryPath, micFinalPath: micFinalPath
        )
    }

    // MARK: 恢复裁决（纯函数：stage × 目录观察 → 结论）

    /// 主文件的裁决。
    public func mainResolution(_ observation: DirectoryObservation) -> FileResolution {
        guard case .reachable(let tempExists, let finalExists) = observation else {
            return .volumeUnavailable
        }
        switch stage {
        case .writing:
            // 协议保证 rename 前必先持久化 committingMain，所以 writing 阶段
            // rename 从未开始。final 上有文件也只可能是用户原有的（选择覆盖时）。
            return .notCommitted(tempExists: tempExists)
        case .committingMain:
            // rename 是同卷原子操作：临时还在 = 没发生；临时没了且最终在 = 发生了。
            if tempExists { return .notCommitted(tempExists: true) }
            return finalExists ? .committed : .lost
        case .mainCommitted, .committingMicrophone, .allCommitted:
            // stage 断定 rename 已发生，但**文件此刻在不在仍要看实测**（复审 P1）。
            return finalExists ? .committed : .committedButMissing
        case .microphoneOnlyCommitting, .microphoneOnlyCommitted:
            // 纯 mic 流程从没提交过主文件。最终路径上若有文件，那是**用户原有的**
            // （当初在 Save 面板选了覆盖），绝不能认成本次录屏（复审四 P1-1）。
            return .notCommitted(tempExists: tempExists)
        }
    }

    /// 麦克风 sidecar 的裁决。没录麦克风返回 nil。
    public func microphoneResolution(_ observation: DirectoryObservation) -> FileResolution? {
        guard micTemporaryPath != nil else { return nil }
        guard case .reachable(let tempExists, let finalExists) = observation else {
            return .volumeUnavailable
        }
        switch stage {
        case .writing, .committingMain, .mainCommitted:
            return .notCommitted(tempExists: tempExists)
        case .committingMicrophone, .microphoneOnlyCommitting:
            if tempExists { return .notCommitted(tempExists: true) }
            return finalExists ? .committed : .lost
        case .allCommitted, .microphoneOnlyCommitted:
            return finalExists ? .committed : .committedButMissing
        }
    }

    // MARK: 路径清单

    /// 本清单点名的全部临时路径。恢复时只碰这些，别的一律不动。
    public var temporaryPaths: [String] {
        [mainTemporaryPath, micTemporaryPath].compactMap { $0 }
    }

    /// 本阶段**可能**还需要恢复处理的临时路径（存在与否要现场核对）。
    public var pendingTemporaryPaths: [String] {
        switch stage {
        case .writing, .committingMain: return temporaryPaths
        case .mainCommitted, .committingMicrophone: return [micTemporaryPath].compactMap { $0 }
        case .allCommitted: return []
        // 纯 mic 流程：主临时文件仍可能残留（它被判无效但未必删得掉），
        // 提交前 mic 临时文件也还在。
        case .microphoneOnlyCommitting: return temporaryPaths
        case .microphoneOnlyCommitted: return [mainTemporaryPath]
        }
    }

    /// 仅凭 stage 就能断定 rename 已发生的最终路径。**不得删除**；
    /// 此刻是否真的存在要另行观察（见裁决函数）。
    public var committedFinalPaths: [String] {
        switch stage {
        case .writing, .committingMain: return []
        case .mainCommitted, .committingMicrophone: return [mainFinalPath]
        case .allCommitted: return [mainFinalPath, micFinalPath].compactMap { $0 }
        // 纯 mic 流程**从未提交主文件** —— 主最终路径上的东西是用户自己的。
        case .microphoneOnlyCommitting: return []
        case .microphoneOnlyCommitted: return [micFinalPath].compactMap { $0 }
        }
    }

    /// 一个路径是否属于本会话。恢复前必须逐条校验，防止同目录相似文件被误伤。
    /// **禁止用 glob 匹配代替它**（计划 §20）。
    public func owns(path: String) -> Bool {
        temporaryPaths.contains(path)
    }
}

/// manifest 的持久化栅栏：单一 JSON 文件 + 原子写。
///
/// `persist()` **成功返回后**，manifest 已通过「写临时文件 + 原子 rename」进入
/// 文件系统命名空间 —— 进程级崩溃（含 kill -9）后必然能读回。这正是 journal
/// 协议里「persist 之后才许 rename」这道栅栏的实现。
///
/// 威胁模型是 **App 崩溃**，不是整机掉电：掉电级持久性需要 F_FULLFSYNC，
/// 计划未要求；若将来要，加在 persist() 里，不改协议。
///
/// `load()` 读到损坏文件会抛错 —— 调用方应当如实报告「恢复信息损坏」，
/// **不许**因此退回 glob 扫描。
public struct ScreenRecordingManifestStore: Sendable {
    public let fileURL: URL

    /// - Parameter directory: manifest 所在目录（App 层传 Application Support 子目录）。
    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("active-recording-manifest.json")
    }

    /// 原子落盘。**返回成功之后，调用方才允许做对应的 rename。**
    public func persist(_ manifest: ScreenRecordingManifest) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: fileURL, options: .atomic)
    }

    /// 账本文件**是否存在** —— 与「能否解码」无关。
    ///
    /// 「有没有未了结的账」必须以它为准，不能用 `try? load() != nil`：
    /// 那样一份**损坏**的 JSON 会被读成「没有账本」，下一次录制的 `persist()`
    /// 就把它覆盖掉了，上一段录制的唯一索引随之消失。解码失败同样是
    /// unsettled，**不允许 fail-open**（复审三 P1-2）。
    public var fileExists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    public func load() throws -> ScreenRecordingManifest? {
        guard fileExists else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(ScreenRecordingManifest.self, from: data)
    }

    /// 幂等清除。
    ///
    /// **调用前必须先问 `ScreenRecoveryLedger.canClearManifest`** ——
    /// 光看文件现场（`FileResolution`）是不够的：writing 阶段崩溃留下的 partial
    /// 现场是 `notCommitted(tempExists: true)`，现场本身「没问题」，但用户还没
    /// 决定这份 partial 怎么处理，此时清账会让它变成无人认领的隐藏文件。
    public func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

// MARK: - 恢复清账合同

/// 恢复流程对一份文件的**处置进度**（不是文件现场）。
///
/// 现场由 `ScreenRecordingManifest.FileResolution` 描述；能不能清账要看**用户/
/// 事务走到哪了**。两者混用是复审抓到的 P1：writing 阶段崩溃留下的 partial，
/// 现场是「未提交且临时文件在」，看着无异常，但用户还没决定怎么处理它 ——
/// 此时清 manifest，那份隐藏的临时文件就再也没人认领了。
public enum RecoveryDisposition: Hashable, Sendable {
    /// 还没给用户呈现，或用户尚未选择。
    case pendingUserDecision
    /// 用户选了「导入到工程」，但入轨事务还没成功提交。
    case importPending
    /// 已彻底处置完：入轨成功、或用户明确选择「仅保留文件」/「删除」、
    /// 或错误已呈现并被确认。
    case settled
}

/// 恢复清账合同：**只有每一路都既「现场有结论」又「处置已了结」，才允许清
/// manifest**。
///
/// 反例（都必须保留 manifest）：
/// - writing 崩溃 → partial 在 → 恢复 UI 还没弹或用户没选 → 再崩就成孤儿文件；
/// - allCommitted 之后、入轨事务提交之前崩溃 → 文件已是用户的，但没进轨道，
///   清了账就再也提示不了「有一段录制没入轨」；
/// - 卷不可达 → 什么都没法断定。
public struct ScreenRecordingRecoveryLedger: Hashable, Sendable {
    public struct Entry: Hashable, Sendable {
        public let resolution: ScreenRecordingManifest.FileResolution
        public let disposition: RecoveryDisposition

        public init(
            resolution: ScreenRecordingManifest.FileResolution,
            disposition: RecoveryDisposition
        ) {
            self.resolution = resolution
            self.disposition = disposition
        }

        /// 本路是否已可从账上抹掉。
        public var isClearable: Bool {
            // 现场没结论（卷不可达）：一律保留，等卷回来重新裁决。
            if resolution.observationIsInconclusive { return false }
            // 现场有结论，但处置没走完：保留。
            return disposition == .settled
        }

        /// 保留原因（给日志/界面用；nil 表示可清）。
        public var retentionReason: String? {
            if resolution.observationIsInconclusive { return "所在卷不可达，无法裁决" }
            switch disposition {
            case .pendingUserDecision: return "等待用户决定如何处理"
            case .importPending: return "入轨事务尚未提交"
            case .settled: return nil
            }
        }
    }

    public let main: Entry
    /// 没录麦克风时为 nil。
    public let microphone: Entry?

    public init(main: Entry, microphone: Entry? = nil) {
        self.main = main
        self.microphone = microphone
    }

    /// **清 manifest 的唯一判据。** 任何一路没了结都不许清。
    public var canClearManifest: Bool {
        main.isClearable && (microphone?.isClearable ?? true)
    }

    /// 全部保留原因（按 main、mic 顺序）。
    public var retentionReasons: [String] {
        [main.retentionReason, microphone?.retentionReason].compactMap { $0 }
    }
}

// MARK: - 崩溃恢复的动作裁决

/// 启动时对上一次残留该做什么。
///
/// **两路都要看。** 早先的实现只看主文件裁决就分支，导致
/// 「主文件已提交 + 麦克风临时文件还在」时把可恢复的 mic 临时文件当垃圾删掉
/// （复审 P1-3）。这里把动作定义成纯函数，测试能对每一格反证。
public enum ScreenRecordingRecoveryAction: Hashable, Sendable {
    /// 什么都不做，保留 manifest（卷不可达）。
    case waitForVolume
    /// 有可抢救的临时文件，交给用户决定。**决定前不许清账、不许删。**
    case offerSalvage(mainTemporaryPath: String?, micTemporaryPath: String?)
    /// 文件已经是用户的了，但上次没来得及入轨 —— 提示可以补进时间线。
    ///
    /// - Parameter microphoneMissing: 本次录制**开了麦克风**，但 sidecar 既不在
    ///   最终路径也没有可抢救的临时文件。必须带出来告警 —— 早先这里只在
    ///   `mic == .committed` 时填 `micFinalPath`，其余一律静默丢弃，
    ///   用户会以为旁白也成功了（复审四 P1-5）。
    case offerImport(mainFinalPath: String, micFinalPath: String?, microphoneMissing: Bool)
    /// 该在的文件不见了，如实报告（报告完可以清账）。
    case reportMissing(paths: [String])
    /// 只剩无效残留：精确删除这些路径后清账。**路径由 manifest 点名，禁止 glob。**
    case discardTemporaries(paths: [String])
}

public struct ScreenRecordingRecoveryPlan: Hashable, Sendable {
    public let action: ScreenRecordingRecoveryAction
    public let mainResolution: ScreenRecordingManifest.FileResolution
    public let microphoneResolution: ScreenRecordingManifest.FileResolution?

    /// `stage × 两路观察 → 动作`。
    ///
    /// 优先级（高到低）：卷不可达 → 可抢救 partial → 已提交待入轨 → 文件缺失
    /// → 清理无效残留。
    public static func make(
        manifest: ScreenRecordingManifest,
        mainObservation: ScreenRecordingManifest.DirectoryObservation,
        microphoneObservation: ScreenRecordingManifest.DirectoryObservation?
    ) -> ScreenRecordingRecoveryPlan {
        let main = manifest.mainResolution(mainObservation)
        let mic: ScreenRecordingManifest.FileResolution? = microphoneObservation
            .flatMap { manifest.microphoneResolution($0) }

        func plan(_ action: ScreenRecordingRecoveryAction) -> ScreenRecordingRecoveryPlan {
            .init(action: action, mainResolution: main, microphoneResolution: mic)
        }

        // 任一路没结论就整体等待 —— 半边裁决会把另半边的文件判错。
        if main.observationIsInconclusive || (mic?.observationIsInconclusive ?? false) {
            return plan(.waitForVolume)
        }

        // 任一路还有可抢救的临时文件，都要先问用户。
        let salvageableMain = main.hasSalvageablePartial ? manifest.mainTemporaryPath : nil
        let salvageableMic = (mic?.hasSalvageablePartial ?? false) ? manifest.micTemporaryPath : nil
        if salvageableMain != nil || salvageableMic != nil {
            return plan(.offerSalvage(
                mainTemporaryPath: salvageableMain, micTemporaryPath: salvageableMic
            ))
        }

        // 主文件已落到用户选的位置，但 manifest 还在 —— 说明上次没走完入轨。
        if main == .committed {
            // 录了麦克风却既没提交、也没有可抢救的临时文件 = 旁白丢了，要告警。
            // （走到这里说明前面的 offerSalvage 分支没命中，即 mic 临时文件不在。）
            let expectedMicrophone = manifest.micTemporaryPath != nil
            let microphoneMissing = expectedMicrophone && mic != .committed
            return plan(.offerImport(
                mainFinalPath: manifest.mainFinalPath,
                micFinalPath: mic == .committed ? manifest.micFinalPath : nil,
                microphoneMissing: microphoneMissing
            ))
        }

        var missing: [String] = []
        if main == .committedButMissing || main == .lost { missing.append(manifest.mainFinalPath) }
        if let mic, mic == .committedButMissing || mic == .lost,
           let path = manifest.micFinalPath { missing.append(path) }
        if !missing.isEmpty { return plan(.reportMissing(paths: missing)) }

        // 剩下的只可能是「未提交且临时文件也不在」——没有任何可救的东西。
        var stale: [String] = []
        if case .notCommitted(false) = main { stale.append(manifest.mainTemporaryPath) }
        if let mic, case .notCommitted(false) = mic, let path = manifest.micTemporaryPath {
            stale.append(path)
        }
        return plan(.discardTemporaries(paths: stale))
    }
}

// MARK: - 磁盘空间预检

/// 收尾时判断「某一路音频有没有覆盖整段录制」。
///
/// **这是完整性判据，不是对齐判据。** 两者的尺度差一个数量级：
///
/// - 对齐（计划 §8.3）要求「末端差不超过一个工程帧」，但那条标准的验收方式是
///   **解码后 PCM 的拍手 / click 峰值位置**，属于 Phase 5 的实机项。
/// - 这里能拿到的只有「首包 / 末包的 PTS」。计划 §8.3 同一段明确写着：
///   Apple AAC encoder 前置 priming 约 2112 samples（48 kHz 下 ≈ 44 ms），
///   **已经略大于 24 fps 的一帧**，所以「不能把编码包的首 PTS 直接当同步结论」。
///
/// 早先这里用「一个工程帧」当容差，等于把 priming 本身判成缺陷 —— 真机首测
/// 录了 8 秒全程正常，却弹出
/// 「Computer audio starts 0:00 after the recording begins」
/// （差值小到连格式化都显示成 0:00）。
///
/// 要抓的是「音频缺了好几秒」这种真缺陷，所以容差取 0.5 秒：足够盖住
/// AAC priming（44 ms）+ 音频设备启动 + 分包抖动，又远小于用户能察觉的缺失。
public enum ScreenRecordingAudioCoverage {
    public static let toleranceSeconds: Double = 0.5

    /// 这个间隙是否值得报给用户。
    public static func isSignificant(_ gap: Double) -> Bool {
        gap > toleranceSeconds
    }
}

public enum ScreenRecordingDiskBudget {
    /// 无论画面多小都要留的绝对下限。计划 §9.1 规定 `max(1 GiB, 两分钟估算)`。
    public static let absoluteFloorBytes: Int64 = 1024 * 1024 * 1024

    /// 估算窗口：两分钟。
    public static let estimateWindowSeconds: Double = 120

    /// 开录前要求的最小可用字节 = `max(1 GiB, 两分钟码率估算)`。
    ///
    /// 这是**阈值**不是容量保证 —— 计划 §20 明确「不承诺事前算出最终体积」。
    /// 码率按 H.264 屏幕内容粗估 0.1 bit/像素/帧。
    public static func minimumRequiredBytes(
        pixelSize: CGSize, frameRate: ProjectFrameRate,
        seconds: Double = estimateWindowSeconds
    ) -> Int64 {
        let pixels = Double(pixelSize.width * pixelSize.height)
        let bytesPerSecond = pixels * 0.1 * Double(frameRate.fps) / 8
        return Int64(max(bytesPerSecond * seconds, Double(absoluteFloorBytes)))
    }

    /// 录制期间的低空间警戒线：跌破它就主动 Stop 并走正常 finalize。
    ///
    /// **必须严格小于开录阈值**，否则会出现「刚通过预检就立刻触发主动停止」
    /// 这种自相矛盾的行为。取开录阈值的 1/4，且不低于 256 MiB。
    public static func runtimeWarningBytes(
        pixelSize: CGSize, frameRate: ProjectFrameRate
    ) -> Int64 {
        let start = minimumRequiredBytes(pixelSize: pixelSize, frameRate: frameRate)
        return max(start / 4, 256 * 1024 * 1024)
    }

    /// 不变量：警戒线必须严格小于开录阈值。产品代码与自检都靠它。
    public static func isConsistent(
        pixelSize: CGSize, frameRate: ProjectFrameRate
    ) -> Bool {
        runtimeWarningBytes(pixelSize: pixelSize, frameRate: frameRate)
            < minimumRequiredBytes(pixelSize: pixelSize, frameRate: frameRate)
    }
}
