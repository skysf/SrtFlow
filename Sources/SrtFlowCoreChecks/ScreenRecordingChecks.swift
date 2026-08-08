import Foundation
import SrtFlowCore

// 录屏坐标换算、录屏值类型、工程帧率的纯逻辑自检。
//
// **为什么单独一个文件**：`main.swift` 是顶层脚本，Swift 把整份文件当**一个
// 作用域**做类型推断，断言堆多了类型检查会指数级变慢。本轮把近百条塞进去后
// 编译卡了 20 分钟没编完；拆成函数就把作用域切开了。
// 以后成组的新检查一律放独立文件的函数里，别再往 main.swift 顶层加。

// check / checkEqual 是 main.swift 里的模块级函数，直接用。

// MARK: - 坐标换算

private func checkCoordinateMapper() {
    typealias M = ScreenRecordingCoordinateMapper

    // 本机真实拓扑：主屏 (0,0) 1440x900 点 / 2880x1800 像素；
    // 副屏在**左上方**，CGDisplayBounds=(-279,-1080)，两个分量都是负的。
    let main = M.DisplayGeometry(
        boundsInPoints: CGRect(x: 0, y: 0, width: 1440, height: 900),
        pixelSize: CGSize(width: 2880, height: 1800)
    )
    let secondary = M.DisplayGeometry(
        boundsInPoints: CGRect(x: -279, y: -1080, width: 1920, height: 1080),
        pixelSize: CGSize(width: 3840, height: 2160)
    )
    let nonRetina = M.DisplayGeometry(
        boundsInPoints: CGRect(x: 1440, y: 0, width: 1280, height: 1024),
        pixelSize: CGSize(width: 1280, height: 1024)
    )

    checkEqual(main.pointPixelScale, 2, "主屏 scale=2")
    checkEqual(nonRetina.pointPixelScale, 1, "非 Retina scale=1")

    // ---- 点 vs 像素（Phase 0 门槛 10 的核心陷阱）----
    checkEqual(M.captureSize(forFullDisplay: main), CGSize(width: 2880, height: 1800),
               "整屏捕获必须用真实像素而非点")
    checkEqual(M.captureSize(forFullDisplay: nonRetina), CGSize(width: 1280, height: 1024),
               "非 Retina 屏点=像素")

    // ---- 硬件编码单边上限：与总像素无关 ----
    checkEqual(M.fitToHardwareEncoder(CGSize(width: 3840, height: 2160)),
               CGSize(width: 3840, height: 2160), "4K 不超限，原样")
    checkEqual(M.fitToHardwareEncoder(CGSize(width: 5120, height: 2880)),
               CGSize(width: 4096, height: 2304), "5K 等比缩到单边 4096")
    let ultrawide = M.fitToHardwareEncoder(CGSize(width: 5120, height: 1440))
    checkEqual(ultrawide.width, 4096, "超宽屏按单边缩（像素总数少于 4K 也要缩）")
    checkEqual(ultrawide.height, 1152, "超宽屏等比缩后的高")
    checkEqual(M.fitToHardwareEncoder(CGSize(width: 4096, height: 4096)),
               CGSize(width: 4096, height: 4096), "双边正好到上限不缩")

    // ---- 偶数像素 ----
    checkEqual(M.evenPixels(CGSize(width: 1921, height: 1081)),
               CGSize(width: 1920, height: 1080), "奇数向下取偶")
    checkEqual(M.evenPixels(CGSize(width: 1, height: 1)),
               CGSize(width: 2, height: 2), "下限保 2")

    // ---- AppKit(bottom-left) ↔ CG(top-left) ----
    //
    // 翻转轴是**主屏高度**，不是屏幕并集顶边。这条曾经写错过：并集公式**也能
    // 自反往返**，所以「往返一致」根本测不出错 —— 必须拿实测数据对账。
    // 实测：副屏 NSScreen.frame=(-279, 900, 1920, 1080)
    //       副屏 CGDisplayBounds=(-279, -1080, 1920, 1080)
    let mainHeight: CGFloat = 900
    let secondaryAppKit = CGRect(x: -279, y: 900, width: 1920, height: 1080)
    let secondaryCG = M.cgRect(fromAppKit: secondaryAppKit, mainDisplayHeightInPoints: mainHeight)
    checkEqual(secondaryCG, CGRect(x: -279, y: -1080, width: 1920, height: 1080),
               "副屏 AppKit→CG 必须命中实测的 CGDisplayBounds")
    check(secondaryCG.minY != 0, "反例守卫：用屏幕并集顶边会得到 0，那是错的")
    checkEqual(M.cgRect(fromAppKit: CGRect(x: 0, y: 0, width: 1440, height: 900),
                        mainDisplayHeightInPoints: mainHeight),
               CGRect(x: 0, y: 0, width: 1440, height: 900), "主屏两个坐标系重合")
    checkEqual(M.appKitRect(fromCG: secondaryCG, mainDisplayHeightInPoints: mainHeight),
               secondaryAppKit, "换算要能往返（必要但不充分）")

    // ---- 一步到位：AppKit → display-local，并验证真的落在目标屏内 ----
    let regionAppKit = CGRect(x: -179, y: 1000, width: 400, height: 300)
    if let local = M.displayLocalRect(fromAppKit: regionAppKit, display: secondary,
                                      mainDisplayHeightInPoints: mainHeight) {
        check(M.isWithinDisplay(local, display: secondary),
              "换算结果必须落在副屏 local bounds 内（真正的验收，不是往返自反）")
        checkEqual(local.width, 400, "宽度不变")
        checkEqual(local.height, 300, "高度不变")
        checkEqual(local.minX, 100, "副屏 display-local 的 x")
        checkEqual(local.minY, 680, "副屏 display-local 的 y")
    } else {
        check(false, "副屏内的区域应当能换算出 display-local")
    }

    if let localMain = M.displayLocalRect(
        fromAppKit: CGRect(x: 100, y: 100, width: 200, height: 200),
        display: main, mainDisplayHeightInPoints: mainHeight
    ) {
        check(M.isWithinDisplay(localMain, display: main), "主屏结果落在屏内")
        checkEqual(localMain.minY, 600, "主屏 display-local 的 y（900-300）")
    } else {
        check(false, "主屏内的区域应当能换算")
    }

    check(M.displayLocalRect(fromAppKit: CGRect(x: 100, y: 100, width: 50, height: 50),
                             display: secondary, mainDisplayHeightInPoints: mainHeight) == nil,
          "完全在别的屏上的区域返回 nil")

    // **部分跨界必须返回 nil，不许静默裁掉**（早先用 intersection 会把越界部分
    // 悄悄剪掉并返回，用户录到的区域比他看到的小一圈）。
    // 主屏 AppKit y 范围 0…900；这个矩形从 y=850 起、高 200，上半截越到副屏去了。
    check(M.displayLocalRect(fromAppKit: CGRect(x: 100, y: 850, width: 200, height: 200),
                             display: main, mainDisplayHeightInPoints: mainHeight) == nil,
          "部分越出上边界的区域必须返回 nil，不能静默裁掉")
    // 左边越界
    check(M.displayLocalRect(fromAppKit: CGRect(x: -50, y: 100, width: 200, height: 200),
                             display: main, mainDisplayHeightInPoints: mainHeight) == nil,
          "部分越出左边界的区域必须返回 nil")
    // 右边越界
    check(M.displayLocalRect(fromAppKit: CGRect(x: 1350, y: 100, width: 200, height: 200),
                             display: main, mainDisplayHeightInPoints: mainHeight) == nil,
          "部分越出右边界的区域必须返回 nil")
    // 零面积
    check(M.displayLocalRect(fromAppKit: CGRect(x: 100, y: 100, width: 0, height: 100),
                             display: main, mainDisplayHeightInPoints: mainHeight) == nil,
          "零宽区域返回 nil")
    // 正好贴边（完整落屏）应当成功 —— 边界不能过严
    check(M.displayLocalRect(fromAppKit: CGRect(x: 0, y: 0, width: 1440, height: 900),
                             display: main, mainDisplayHeightInPoints: mainHeight) != nil,
          "正好铺满整屏的区域应当成功")
    check(!M.isWithinDisplay(CGRect(x: -10, y: 0, width: 100, height: 100), display: main),
          "负坐标的 local 矩形不算落在屏内")
    check(!M.isWithinDisplay(CGRect(x: 1400, y: 0, width: 100, height: 100), display: main),
          "越过右边界的 local 矩形不算落在屏内")

    // ---- clamp ----
    checkEqual(M.clamp(CGRect(x: 1300, y: 800, width: 400, height: 400), to: main),
               CGRect(x: 1300, y: 800, width: 140, height: 100), "越界区域要被夹进屏内")

    // ---- 固定比例与任意方向拖动 ----
    let anchor = CGPoint(x: 500, y: 500)
    checkEqual(M.regionRect(anchor: anchor, current: CGPoint(x: 300, y: 200), ratio: nil),
               CGRect(x: 300, y: 200, width: 200, height: 300), "反向拖动要标准化")
    let wide = M.regionRect(anchor: anchor, current: CGPoint(x: 820, y: 800), ratio: 16.0 / 9)
    checkEqual(wide.width, 320, "16:9 受宽限制")
    check(abs(wide.height - 180) < 0.001, "16:9 的高按比例算")
    let upLeft = M.regionRect(anchor: anchor, current: CGPoint(x: 180, y: 200), ratio: 16.0 / 9)
    checkEqual(upLeft.maxX, 500, "向左上拖时右边界仍在锚点")
    checkEqual(upLeft.maxY, 500, "向左上拖时下边界仍在锚点")

    // ---- 比例偏差与最小尺寸 ----
    check(M.ratioDeviation(CGSize(width: 1920, height: 1080), expected: 16.0 / 9) < 0.001,
          "1920x1080 就是 16:9")
    check(M.ratioDeviation(CGSize(width: 100, height: 100), expected: 16.0 / 9) > 0.4,
          "1:1 与 16:9 偏差明显")
    check(!M.isUsableRegion(CGRect(x: 0, y: 0, width: 32, height: 200)), "过小区域不可用")
    check(M.isUsableRegion(CGRect(x: 0, y: 0, width: 64, height: 64)), "刚好到下限可用")
}

// MARK: - 录屏值类型

private func checkRecordingModels() {
    let out = URL(fileURLWithPath: "/Users/x/Movies/My Recording.mov")
    let sid = UUID()
    let req = ScreenRecordingRequest(
        sessionID: sid,
        source: .display(displayID: 1),
        outputURL: out,
        capturePixelSize: CGSize(width: 2880, height: 1800),
        documentGeneration: 42,
        canvasRatioSnapshot: "auto",
        canvasEditGeneration: 7,
        projectHadVisualMedia: false
    )

    // ---- 身份与冻结值 ----
    checkEqual(req.sessionID, sid, "session 身份要随请求传递")
    checkEqual(req.documentGeneration, 42, "工程身份代号要带在请求里")
    checkEqual(req.capturePixelSize, CGSize(width: 2880, height: 1800),
               "捕获像素尺寸开录前就冻结")

    // ---- 麦克风：类型上不存在「开了但没设备」这种组合 ----
    checkEqual(req.microphone, .disabled, "默认不录麦克风")
    check(!req.microphone.isEnabled, "disabled 就是没开")
    checkEqual(req.microphone.deviceID, nil, "disabled 没有设备 ID")
    let withMic = MicrophoneConfiguration.device(id: "BuiltInMicrophoneDevice")
    check(withMic.isEnabled, "device 就是开了")
    checkEqual(withMic.deviceID, "BuiltInMicrophoneDevice", "device 必带已解析的 ID")

    // ---- 指针配置 ----
    checkEqual(req.cursor.showsCursor, true, "默认显示指针")
    checkEqual(req.cursor.showsClicks, false, "默认不显示点击效果")

    // ---- 文件命名 ----
    checkEqual(req.microphoneURL.lastPathComponent, "My Recording-Mic.m4a", "麦克风 sidecar 命名")
    checkEqual(req.microphoneURL.deletingLastPathComponent(), out.deletingLastPathComponent(),
               "sidecar 与主文件同目录")
    let tmp = req.temporaryURL(for: .main)
    checkEqual(tmp.deletingLastPathComponent(), out.deletingLastPathComponent(),
               "临时文件是同目录 sibling（保证最后是同卷 rename）")
    check(tmp.lastPathComponent.hasPrefix("."), "临时文件以点开头")
    check(tmp.lastPathComponent.contains("partial"), "临时文件名标明 partial")
    checkEqual(tmp.pathExtension, "mov", "临时文件保留扩展名")
    check(req.temporaryURL(for: .microphone).lastPathComponent.contains("-Mic"),
          "麦克风临时文件带 -Mic")
    // request 全字段 let（不可变快照）—— 这里只能整个另造一份，改不了字段。
    let other = ScreenRecordingRequest(
        sessionID: UUID(), source: req.source, outputURL: out,
        capturePixelSize: req.capturePixelSize, documentGeneration: 42,
        canvasRatioSnapshot: "auto", canvasEditGeneration: 7, projectHadVisualMedia: false
    )
    check(other.temporaryURL(for: .main).lastPathComponent != tmp.lastPathComponent,
          "不同 session 的临时名不同")
    // 完整 UUID 进临时名（8 位短码在残留+新会话并存时有撞名概率）
    check(tmp.lastPathComponent.contains(sid.uuidString), "临时名要含完整 session UUID")

    // ---- 来源语义 ----
    check(ScreenRecordingSource.display(displayID: 1).needsControlWindowExclusion,
          "整屏要排除控制窗")
    check(ScreenRecordingSource.region(displayID: 1, rectInPoints: .zero)
            .needsControlWindowExclusion, "区域要排除控制窗")
    check(!ScreenRecordingSource.window(windowID: 9).needsControlWindowExclusion,
          "单窗口保留 picker 原 filter，不重建")
    checkEqual(ScreenRecordingSource.region(displayID: 5, rectInPoints: .zero).displayID, 5,
               "区域能取到所在显示器")
    checkEqual(ScreenRecordingSource.window(windowID: 9).displayID, nil,
               "单窗口没有固定显示器")

    // ---- 比例档 ----
    checkEqual(RegionAspectRatio.allCases.count, 6, "六个比例档（含自由）")
    checkEqual(RegionAspectRatio.free.value, nil, "自由模式无比例")
    check(abs((RegionAspectRatio.wide16x9.value ?? 0) - 16.0 / 9) < 1e-9, "16:9 的值")
    check(abs((RegionAspectRatio.tall9x16.value ?? 0) - 9.0 / 16) < 1e-9, "9:16 的值")
    checkEqual(RegionAspectRatio.square.value, 1, "1:1 的值")

    checkStateMachine()
    checkManifest(sessionID: sid)

    // ---- 错误 ----
    check(ScreenRecordingError.microphoneNotAuthorized.isNonFatal,
          "麦克风未授权不该中断主录制")
    check(!ScreenRecordingError.screenCaptureNotAuthorized.isNonFatal, "屏幕未授权是致命的")
    check(!ScreenRecordingError.diskFullDuringRecording.isNonFatal, "磁盘满是致命的")

    checkDiskBudget()
}

// MARK: - 状态机

private func checkStateMachine() {
    typealias S = ScreenRecordingState
    let now = Date()

    // 配置阶段可来回、可随时取消
    check(S.canTransition(from: .idle, to: .configuring), "idle → configuring")
    check(S.canTransition(from: .configuring, to: .choosingSource), "配置 → 选来源")
    check(S.canTransition(from: .choosingSource, to: .configuring), "选来源可返回配置")
    check(S.canTransition(from: .choosingSource, to: .idle), "选来源可取消（不是错误）")
    check(S.canTransition(from: .choosingDestination, to: .preparing), "选好目标 → 准备")
    check(S.canTransition(from: .choosingDestination, to: .idle), "Save 取消不产生文件")

    // 准备 → 倒计时 → 启动 → 录制
    check(S.canTransition(from: .preparing, to: .countingDown(remaining: 3)), "准备 → 倒计时")
    check(S.canTransition(from: .countingDown(remaining: 3), to: .countingDown(remaining: 2)),
          "倒计时自转")
    check(S.canTransition(from: .countingDown(remaining: 0), to: .starting), "倒计时结束 → 启动")
    check(S.canTransition(from: .countingDown(remaining: 3), to: .idle), "倒计时期间取消是干净的")
    check(S.canTransition(from: .starting, to: .recording(startedAt: now)), "启动 → 录制")
    // 「启动中就按 Stop」必须有地方安放
    check(S.canTransition(from: .starting, to: .stopping), "启动中按 Stop 要能处理")

    // 停止链路
    check(S.canTransition(from: .recording(startedAt: now), to: .stopping), "录制 → 停止")
    check(S.canTransition(from: .stopping, to: .finishing), "停止 → 收尾")
    check(S.canTransition(from: .finishing, to: .importing), "收尾 → 入轨")
    check(S.canTransition(from: .finishing, to: .partialRecovery(sampleResult())),
          "收尾发现残缺 → partial 决策")
    check(S.canTransition(from: .partialRecovery(sampleResult()), to: .importing),
          "用户决定保留 partial → 入轨")
    check(S.canTransition(from: .partialRecovery(sampleResult()), to: .idle),
          "用户决定丢弃 partial → 回空闲")
    check(S.canTransition(from: .importing, to: .finished(sampleResult())), "入轨完成 → 终态")

    // ---- 反例 ----
    // **写盘期没有直达 .failed 的边**（复审 P1）：.failed 解锁工程切换，
    // 直达意味着 stream/writer/manifest/控制窗还没收干净用户就能切工程。
    // 错误也要走 stopping → finishing，由 finishing 决定 partial 还是 failed。
    let err = ScreenRecordingError.streamFailed(message: "x")
    check(!S.canTransition(from: .starting, to: .failed(err)),
          "starting 出错不得直达 failed，要走停止链路")
    check(!S.canTransition(from: .recording(startedAt: now), to: .failed(err)),
          "recording 出错不得直达 failed")
    check(!S.canTransition(from: .stopping, to: .failed(err)),
          "stopping 出错不得直达 failed，finalize 必须先跑")
    check(S.canTransition(from: .finishing, to: .failed(err)),
          "只有 finishing（清理已跑）才能进 failed")
    check(!S.canTransition(from: .idle, to: .recording(startedAt: now)), "不能跳过准备直接录")
    check(!S.canTransition(from: .stopping, to: .stopping), "重复 Stop 必须被挡（幂等）")
    check(!S.canTransition(from: .recording(startedAt: now), to: .idle),
          "录制中不能直接回 idle，必须走停止链路")
    check(!S.canTransition(from: .recording(startedAt: now), to: .finishing),
          "不能跳过 stopping 直接 finishing")
    check(!S.canTransition(from: .finishing, to: .finished(sampleResult())),
          "不能跳过入轨直接终态")

    // ---- 工程锁：importing / partialRecovery 也必须锁 ----
    // 这是本轮修复的核心：早先 .finished/.failed 一到就解锁，而那时入轨事务
    // 和 partial 决策往往还没做完，用户此刻切工程会让素材进错工程。
    check(S.importing.locksProjectSwitching, "入轨期间必须锁工程切换")
    check(S.partialRecovery(sampleResult()).locksProjectSwitching, "partial 决策期间必须锁")
    check(S.starting.locksProjectSwitching, "启动中要锁")
    check(S.stopping.locksProjectSwitching, "停止中要锁")
    check(S.configuring.locksProjectSwitching, "配置中要锁")
    check(!S.idle.locksProjectSwitching, "空闲不锁")
    check(!S.finished(sampleResult()).locksProjectSwitching, "终态解锁")
    check(!S.failed(.pickerCancelled).locksProjectSwitching, "失败态解锁")

    // ---- 是否在写盘：决定退出拦截与低空间监测 ----
    check(S.recording(startedAt: now).isWritingToDisk, "录制中在写盘")
    check(S.finishing.isWritingToDisk, "收尾中在写盘")
    check(!S.importing.isWritingToDisk, "入轨时已不在写盘（文件已提交）")
    check(!S.countingDown(remaining: 3).isWritingToDisk, "倒计时不写盘")
}

private func sampleResult() -> ScreenRecordingResult {
    ScreenRecordingResult(
        mainURL: URL(fileURLWithPath: "/tmp/a.mov"), duration: 1,
        pixelSize: CGSize(width: 1920, height: 1080), frameRate: .fps24
    )
}

// MARK: - manifest 提交阶段

private func checkManifest(sessionID: UUID) {
    typealias R = ScreenRecordingManifest.FileResolution
    typealias O = ScreenRecordingManifest.DirectoryObservation
    var manifest = ScreenRecordingManifest(
        sessionID: sessionID, startedAt: Date(),
        mainTemporaryPath: "/tmp/.a.T.partial.mov", mainFinalPath: "/tmp/a.mov",
        micTemporaryPath: "/tmp/.a-Mic.T.partial.m4a", micFinalPath: "/tmp/a-Mic.m4a"
    )

    // 归属：只处理点名路径，禁止 glob
    checkEqual(manifest.temporaryPaths.count, 2, "两个临时路径")
    check(manifest.owns(path: "/tmp/.a.T.partial.mov"), "点名的路径归本会话")
    check(!manifest.owns(path: "/tmp/.a.X.partial.mov"),
          "同目录相似文件**不**归本会话（防误删）")
    check(!manifest.owns(path: "/tmp/a.mov"), "最终路径不在临时清单里")

    // ---- journal 提交协议的崩溃切点全枚举 ----
    // 协议：persist(committingMain) → rename main → persist(mainCommitted) →
    //       persist(committingMic) → rename mic → persist(allCommitted) → clear
    // rename 是同卷原子操作，每个切点都必须可判定。

    // 切点 1：writing 期崩溃（rename 从未开始）
    checkEqual(manifest.stage, .writing, "默认处于写入阶段")
    checkEqual(manifest.mainResolution(.reachable(tempExists: true, finalExists: false)),
               R.notCommitted(tempExists: true), "writing：主临时在 → 未提交可抢救")
    checkEqual(manifest.mainResolution(.reachable(tempExists: true, finalExists: true)),
               R.notCommitted(tempExists: true),
               "writing：final 有用户旧文件也不改变「未提交」判定")
    checkEqual(manifest.mainResolution(.reachable(tempExists: false, finalExists: true)),
               R.notCommitted(tempExists: false),
               "writing：绝不因 final 存在就认领它（可能是用户旧文件）")

    // 切点 2：persist(committingMain) 之后、rename 之前崩溃
    manifest.stage = .committingMain
    checkEqual(manifest.mainResolution(.reachable(tempExists: true, finalExists: false)),
               R.notCommitted(tempExists: true), "committingMain+临时在 → rename 没发生")
    checkEqual(manifest.mainResolution(.reachable(tempExists: true, finalExists: true)),
               R.notCommitted(tempExists: true),
               "committingMain+临时在+final 是用户旧文件 → 不得动 final")
    // 切点 3：rename 之后、persist(mainCommitted) 之前崩溃 —— 三阶段模型必误判的窗口
    checkEqual(manifest.mainResolution(.reachable(tempExists: false, finalExists: true)),
               R.committed, "committingMain+临时没了+final 在 → rename 已发生（journal 的意义）")
    checkEqual(manifest.mainResolution(.reachable(tempExists: false, finalExists: false)),
               R.lost, "committingMain+两者都不在 → 如实报丢失")
    checkEqual(manifest.microphoneResolution(.reachable(tempExists: true, finalExists: false)),
               R.notCommitted(tempExists: true), "committingMain 期 mic 未提交")
    check(manifest.committedFinalPaths.isEmpty,
          "committingMain 仅凭 stage 不得断定 main 已提交（要查文件系统）")
    checkEqual(manifest.pendingTemporaryPaths.count, 2,
               "committingMain 两个临时路径都要现场核对")

    // 切点 4：persist(mainCommitted) 之后崩溃
    manifest.stage = .mainCommitted
    checkEqual(manifest.mainResolution(.reachable(tempExists: false, finalExists: true)),
               R.committed, "mainCommitted：主文件已是用户的文件")
    // **已提交 ≠ 文件此刻还在**（复审 P1）：提交后被移动/删除要如实报告
    checkEqual(manifest.mainResolution(.reachable(tempExists: false, finalExists: false)),
               R.committedButMissing,
               "mainCommitted+final 不在（卷可达）→ committedButMissing，不许谎报 committed")
    checkEqual(manifest.microphoneResolution(.reachable(tempExists: true, finalExists: false)),
               R.notCommitted(tempExists: true), "mainCommitted：mic 仍未提交")
    checkEqual(manifest.committedFinalPaths, ["/tmp/a.mov"], "mainCommitted：main 不得删除")
    checkEqual(manifest.pendingTemporaryPaths, ["/tmp/.a-Mic.T.partial.m4a"],
               "mainCommitted：只剩 mic 临时文件待处理")
    check(!manifest.pendingTemporaryPaths.contains(manifest.mainTemporaryPath),
          "已提交那份的临时路径不能再动")

    // 切点 5：persist(committingMic) 之后、rename 之前崩溃
    manifest.stage = .committingMicrophone
    checkEqual(manifest.microphoneResolution(.reachable(tempExists: true, finalExists: false)),
               R.notCommitted(tempExists: true), "committingMic+临时在 → rename 没发生")
    // 切点 6：mic rename 之后、persist(allCommitted) 之前崩溃
    checkEqual(manifest.microphoneResolution(.reachable(tempExists: false, finalExists: true)),
               R.committed, "committingMic+临时没了+final 在 → mic 已提交")
    checkEqual(manifest.microphoneResolution(.reachable(tempExists: false, finalExists: false)),
               R.lost, "committingMic+两者不在 → mic 丢失")
    checkEqual(manifest.mainResolution(.reachable(tempExists: false, finalExists: true)),
               R.committed, "committingMic 期 main 已提交（存在时）")
    checkEqual(manifest.mainResolution(.reachable(tempExists: false, finalExists: false)),
               R.committedButMissing, "committingMic 期 main 缺失也要如实报")

    // 切点 7：persist(allCommitted) 之后、clear 之前崩溃
    manifest.stage = .allCommitted
    checkEqual(manifest.pendingTemporaryPaths.count, 0, "全部提交后无待处理临时文件")
    checkEqual(manifest.committedFinalPaths.count, 2, "全部提交后两个最终路径都不得删")
    checkEqual(manifest.mainResolution(.reachable(tempExists: false, finalExists: true)),
               R.committed, "allCommitted：main 在 → committed")
    checkEqual(manifest.mainResolution(.reachable(tempExists: false, finalExists: false)),
               R.committedButMissing, "allCommitted：main 缺失 → 如实报告，不许直接当成功")
    checkEqual(manifest.microphoneResolution(.reachable(tempExists: false, finalExists: false)),
               R.committedButMissing, "allCommitted：mic 缺失同样如实报告")

    // ---- 卷不可达：任何阶段都不做决定、不清 manifest（复审 P1）----
    for stage in [ScreenRecordingManifest.CommitStage.writing, .committingMain,
                  .mainCommitted, .committingMicrophone, .allCommitted] {
        manifest.stage = stage
        checkEqual(manifest.mainResolution(.volumeUnavailable), R.volumeUnavailable,
                   "\(stage)：卷不可达时 main 不做决定")
        checkEqual(manifest.microphoneResolution(.volumeUnavailable), R.volumeUnavailable,
                   "\(stage)：卷不可达时 mic 不做决定")
    }
    // FileResolution 只表达**现场**，不表达能否清账（复审 P1 的核心混淆）
    check(R.volumeUnavailable.observationIsInconclusive, "卷不可达 = 现场没结论")
    check(!R.committed.observationIsInconclusive, "已提交且在场 = 现场有结论")
    check(!R.committedButMissing.observationIsInconclusive, "已提交但缺失 = 现场有结论")
    check(!R.lost.observationIsInconclusive, "丢失 = 现场有结论")
    check(R.notCommitted(tempExists: true).hasSalvageablePartial, "临时在 = 有可抢救 partial")
    check(!R.notCommitted(tempExists: false).hasSalvageablePartial, "临时不在 = 无 partial")
    check(!R.committed.hasSalvageablePartial, "已提交不算 partial")

    // 没录麦克风
    var noMic = ScreenRecordingManifest(
        sessionID: sessionID, startedAt: Date(),
        mainTemporaryPath: "/tmp/.b.partial.mov", mainFinalPath: "/tmp/b.mov"
    )
    checkEqual(noMic.temporaryPaths.count, 1, "没录麦克风时只有一个临时路径")
    check(noMic.microphoneResolution(.reachable(tempExists: false, finalExists: false)) == nil,
          "没录麦克风时 mic 裁决为 nil")
    noMic.stage = .mainCommitted
    checkEqual(noMic.pendingTemporaryPaths.count, 0, "没有 mic 时主文件提交即全部完成")

    checkRecoveryLedger()
    checkManifestStore(manifest: manifest)
}

// MARK: - 恢复清账合同（复审 P1：现场 ≠ 清账许可）

private func checkRecoveryLedger() {
    typealias R = ScreenRecordingManifest.FileResolution
    typealias E = ScreenRecordingRecoveryLedger.Entry

    // ---- 反例 1：writing 崩溃留下 partial，恢复 UI 还没处理就清账 ----
    // 现场「无异常」（notCommitted + 临时在），但用户没决定 —— 再崩就是孤儿文件。
    let pendingPartial = E(resolution: .notCommitted(tempExists: true),
                           disposition: .pendingUserDecision)
    check(!pendingPartial.isClearable, "partial 未经用户决定不得清账")
    check(!ScreenRecordingRecoveryLedger(main: pendingPartial).canClearManifest,
          "恢复 UI 等待期间再次崩溃：manifest 必须还在")
    checkEqual(pendingPartial.retentionReason, "等待用户决定如何处理", "保留原因可读")

    // ---- 反例 2：allCommitted 之后、入轨事务提交之前崩溃 ----
    // 文件已是用户的，但没进轨道；清了账就再也提示不了「有一段录制没入轨」。
    let importPending = E(resolution: .committed, disposition: .importPending)
    check(!importPending.isClearable, "入轨事务未提交不得清账")
    check(!ScreenRecordingRecoveryLedger(main: importPending).canClearManifest,
          "allCommitted 后、import 前崩溃：manifest 必须还在")
    checkEqual(importPending.retentionReason, "入轨事务尚未提交", "保留原因可读")

    // ---- 反例 3：卷不可达 —— 哪怕处置标成 settled 也不许清 ----
    let unreachableButSettled = E(resolution: .volumeUnavailable, disposition: .settled)
    check(!unreachableButSettled.isClearable,
          "卷不可达时即便 disposition=settled 也不得清账（现场根本没结论）")
    checkEqual(unreachableButSettled.retentionReason, "所在卷不可达，无法裁决", "保留原因可读")

    // ---- 正例：现场有结论 + 处置已了结 ----
    let settledImported = E(resolution: .committed, disposition: .settled)
    check(settledImported.isClearable, "已提交且入轨成功 → 可清")
    check(ScreenRecordingRecoveryLedger(main: settledImported).canClearManifest,
          "唯一一路了结即可清账")
    // 错误路径：呈现并确认后也算了结
    check(E(resolution: .committedButMissing, disposition: .settled).isClearable,
          "已提交但缺失，错误呈现并确认后可清")
    check(E(resolution: .lost, disposition: .settled).isClearable,
          "丢失，错误呈现并确认后可清")
    // 用户选「仅保留文件」/「删除」也是 settled
    check(E(resolution: .notCommitted(tempExists: true), disposition: .settled).isClearable,
          "用户明确处置 partial 后可清")

    // ---- 两路：任何一路没了结都不许清 ----
    let ledgerMicPending = ScreenRecordingRecoveryLedger(
        main: settledImported,
        microphone: E(resolution: .notCommitted(tempExists: true),
                      disposition: .pendingUserDecision)
    )
    check(!ledgerMicPending.canClearManifest, "main 了结但 mic 未决 → 不得清账")
    checkEqual(ledgerMicPending.retentionReasons.count, 1, "只报未了结那一路的原因")

    let ledgerMainPending = ScreenRecordingRecoveryLedger(
        main: pendingPartial,
        microphone: E(resolution: .committed, disposition: .settled)
    )
    check(!ledgerMainPending.canClearManifest, "mic 了结但 main 未决 → 不得清账")

    let bothSettled = ScreenRecordingRecoveryLedger(
        main: settledImported,
        microphone: E(resolution: .committed, disposition: .settled)
    )
    check(bothSettled.canClearManifest, "两路都了结 → 可清")
    check(bothSettled.retentionReasons.isEmpty, "可清时没有保留原因")

    // 没录麦克风：mic 为 nil 不阻塞
    check(ScreenRecordingRecoveryLedger(main: settledImported, microphone: nil)
            .canClearManifest, "没录麦克风时 mic 不阻塞清账")
}

// MARK: - manifest 持久化栅栏

private func checkManifestStore(manifest: ScreenRecordingManifest) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("srtflow-manifeststore-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ScreenRecordingManifestStore(directory: dir)

    do {
        checkEqual(try store.load(), nil, "空目录 load 返回 nil")
        try store.persist(manifest)
        // **持久化栅栏的意义**：persist 成功返回后，manifest 已通过原子 rename
        // 进入文件系统命名空间 —— 这里绕开 store、直接从磁盘路径读原始字节验证，
        // 证明它不是停留在某个进程内缓存里（UserDefaults 的问题正在于此：
        // 内存立即生效、磁盘异步落盘）。进程级崩溃（含 kill -9）不能撤销
        // 已完成的 rename，所以栅栏对 App 崩溃威胁模型成立。
        let raw = try Data(contentsOf: store.fileURL)
        let decoded = try JSONDecoder().decode(ScreenRecordingManifest.self, from: raw)
        checkEqual(decoded, manifest, "persist 返回后磁盘上立即是完整 manifest")

        // 推进 stage 再 persist：读回的是最新的
        var advanced = manifest
        advanced.stage = .allCommitted
        try store.persist(advanced)
        checkEqual(try store.load()?.stage, .allCommitted, "覆盖写后读回最新阶段")

        try store.clear()
        checkEqual(try store.load(), nil, "clear 后 load 返回 nil")
        try store.clear()   // 幂等
        check(true, "clear 幂等")

        // 损坏文件要抛错（调用方如实报告，不许退回 glob）
        try Data("not json".utf8).write(to: store.fileURL)
        var threw = false
        do { _ = try store.load() } catch { threw = true }
        check(threw, "损坏的 manifest 文件 load 要抛错，不能静默当没有")

        // **「有没有账」必须用文件存在性判定，不能用「能不能解码」。**
        //
        // 这是「下一次录制会不会覆盖上一份账」的唯一防线：用
        // `try? load() != nil` 的话，一份损坏的 JSON 会被读成「没有账本」，
        // 紧接着的 persist() 就把它盖掉了，上一段录制的唯一索引随之消失
        // （复审三 P1-2）。解码失败同样是 unsettled，**不允许 fail-open**。
        check(store.fileExists, "损坏的 manifest 仍然算「有账」")
        check((try? store.load()) == nil, "同一份文件确实解不出来（否则上一条无意义）")

        try store.clear()
        check(!store.fileExists, "清掉之后才算没有账")
    } catch {
        check(false, "store 自检异常：\(error)")
    }
}

// MARK: - 磁盘预算

private func checkDiskBudget() {
    typealias Budget = ScreenRecordingDiskBudget
    checkEqual(Budget.absoluteFloorBytes, 1024 * 1024 * 1024, "绝对下限是 1 GiB（计划 §9.1）")
    checkEqual(Budget.estimateWindowSeconds, 120, "估算窗口是两分钟")

    let hd = CGSize(width: 1920, height: 1080)
    let uhd = CGSize(width: 3840, height: 2160)
    // 实测数量级（0.1 bit/像素/帧 × 两分钟）：
    //   1080p30 ≈ 93 MB、4K30 ≈ 373 MB、4K60 ≈ 746 MB —— **都低于 1 GiB**；
    //   只有 4096×4096@60 ≈ 1.51 GB（1.41 GiB）才让估算接管。
    // 也就是说常规录屏场景里 1 GiB 下限本来就占主导，这是有意的保守设计。
    checkEqual(Budget.minimumRequiredBytes(pixelSize: hd, frameRate: .fps30),
               Budget.absoluteFloorBytes, "1080p30 的估算低于 1 GiB，取下限")
    checkEqual(Budget.minimumRequiredBytes(pixelSize: uhd, frameRate: .fps60),
               Budget.absoluteFloorBytes, "4K60 仍低于 1 GiB，取下限")
    let huge = CGSize(width: 4096, height: 4096)
    check(Budget.minimumRequiredBytes(pixelSize: huge, frameRate: .fps60)
            > Budget.absoluteFloorBytes, "4096² @60 的估算超过 1 GiB，由估算接管")
    check(Budget.minimumRequiredBytes(pixelSize: huge, frameRate: .fps60)
            > Budget.minimumRequiredBytes(pixelSize: huge, frameRate: .fps30),
          "估算接管后，60fps 的阈值高于 30fps")

    // **不变量**：警戒线严格小于开录阈值 —— 否则刚过预检就会立刻主动 Stop。
    // 反例守卫：曾经写成「开录 200MB / 警戒 500MB」，正好是矛盾的。
    let sizes: [CGSize] = [
        CGSize(width: 640, height: 480), hd, uhd, CGSize(width: 4096, height: 4096),
    ]
    let rates: [ProjectFrameRate] = [.fps24, .fps30, .fps60]
    for size in sizes {
        for rate in rates {
            let label = "\(Int(size.width))x\(Int(size.height))@\(rate.fps)"
            check(Budget.isConsistent(pixelSize: size, frameRate: rate),
                  label + " 的警戒线必须严格小于开录阈值")
            let warn = Budget.runtimeWarningBytes(pixelSize: size, frameRate: rate)
            check(warn >= 256 * 1024 * 1024, label + " 的警戒线不低于 256 MiB")
        }
    }
}

// MARK: - 工程帧率

private func checkProjectFrameRate() {
    checkEqual(ProjectFrameRate.fallback, .fps24, "默认 24")
    checkEqual(ProjectFrameRate.allCases.count, 3, "只有三档")
    for rate in ProjectFrameRate.allCases {
        checkEqual(rate.frameDurationRational.value, 1, "\(rate.fps) 的 frameDuration 分子")
        checkEqual(rate.frameDurationRational.timescale, Int32(rate.fps),
                   "\(rate.fps) 的 frameDuration 分母")
        check(abs(rate.secondsPerFrame - 1.0 / Double(rate.fps)) < 1e-12,
              "\(rate.fps) 的每帧秒数")
        check(abs(rate.halfFrameTolerance - 0.5 / Double(rate.fps)) < 1e-12,
              "\(rate.fps) 的半帧容差")
    }
    // 30fps 的半帧恰好等于迁移前写死的 1/60 —— 30fps 工程行为不变的依据
    check(abs(ProjectFrameRate.fps30.halfFrameTolerance - 1.0 / 60) < 1e-12,
          "30fps 半帧 = 迁移前的 1/60")

    if let decoded = try? JSONDecoder().decode(ProjectFrameRate.self, from: Data("999".utf8)) {
        checkEqual(decoded, .fps24, "未知帧率回退 24")
    } else {
        check(false, "未知帧率应当宽容解码而不是抛错")
    }
    if let ok = try? JSONDecoder().decode(ProjectFrameRate.self, from: Data("60".utf8)) {
        checkEqual(ok, .fps60, "已知帧率正常解码")
    } else {
        check(false, "已知帧率解码失败")
    }
}

// MARK: - 入口

// MARK: - 录制选项与命名（Phase 2–4 新增面）

private func checkOptionsAndNaming() {
    // 麦克风开关与设备的组合：类型上不存在「开了但没设备」
    let disabled = MicrophoneConfiguration.disabled
    let enabled = MicrophoneConfiguration.device(id: "BuiltInMicrophoneDevice")
    check(!disabled.isEnabled && disabled.deviceID == nil, "disabled 两个投影一致")
    check(enabled.isEnabled && enabled.deviceID != nil, "device 两个投影一致")

    // 指针默认：显示指针、不显示点击效果
    checkEqual(CursorConfiguration.default.showsCursor, true, "默认显示指针")
    checkEqual(CursorConfiguration.default.showsClicks, false, "默认不显示点击效果")

    // 三种来源的排除策略（单窗口不重建 filter 是硬约束）
    let sources: [ScreenRecordingSource] = [
        .display(displayID: 1),
        .region(displayID: 1, rectInPoints: CGRect(x: 0, y: 0, width: 100, height: 100)),
        .window(windowID: 7),
    ]
    let needsExclusion = sources.map(\.needsControlWindowExclusion)
    checkEqual(needsExclusion, [true, true, false], "只有单窗口不需要重建排除 filter")

    // 文件命名：主文件与 sidecar 同目录同名，临时文件是同目录 sibling
    let request = ScreenRecordingRequest(
        sessionID: UUID(),
        source: .display(displayID: 1),
        outputURL: URL(fileURLWithPath: "/Volumes/Ext/Clips/Demo Take 2.mov"),
        capturePixelSize: CGSize(width: 2880, height: 1800),
        documentGeneration: 3,
        canvasRatioSnapshot: "auto",
        canvasEditGeneration: 0,
        projectHadVisualMedia: false
    )
    checkEqual(request.microphoneURL.lastPathComponent, "Demo Take 2-Mic.m4a", "带空格的名字也对")
    checkEqual(
        request.temporaryURL(for: .main).deletingLastPathComponent().path,
        "/Volumes/Ext/Clips", "临时文件与目标同目录（保证同卷 rename）"
    )
    checkEqual(
        request.temporaryURL(for: .microphone).deletingLastPathComponent().path,
        "/Volumes/Ext/Clips", "mic 临时文件也同目录"
    )
    // 两个临时文件不能重名
    check(request.temporaryURL(for: .main) != request.temporaryURL(for: .microphone),
          "主文件与 mic 的临时路径不同")
}

// MARK: - 崩溃恢复的动作裁决（复审 P1-3）

/// `ScreenRecordingRecoveryPlan.make` 的 stage × 两路观察矩阵。
///
/// 这一组的存在理由：早先 coordinator 里的恢复分支**只看主文件裁决**，
/// 复审点名了三个会丢文件/丢提示的具体场景。每一个都在这里被反证。
private func checkRecoveryPlan() {
    typealias Plan = ScreenRecordingRecoveryPlan
    typealias Observation = ScreenRecordingManifest.DirectoryObservation

    let mainTemp = "/V/.Rec.ABC.partial.mov"
    let mainFinal = "/V/Rec.mov"
    let micTemp = "/V/.Rec-Mic.ABC.partial.m4a"
    let micFinal = "/V/Rec-Mic.m4a"

    func manifest(_ stage: ScreenRecordingManifest.CommitStage, mic: Bool = true)
        -> ScreenRecordingManifest {
        ScreenRecordingManifest(
            sessionID: UUID(), startedAt: Date(), stage: stage,
            mainTemporaryPath: mainTemp, mainFinalPath: mainFinal,
            micTemporaryPath: mic ? micTemp : nil,
            micFinalPath: mic ? micFinal : nil
        )
    }

    // ── 复审反例 1：主文件已提交，但 mic 临时文件还在。
    // 旧实现只看 main（= .committed）就走「清理 pendingTemporaryPaths + 清账」，
    // 把一份**可以恢复的**麦克风录音删了。正确动作是先问用户。
    let case1 = Plan.make(
        manifest: manifest(.mainCommitted),
        mainObservation: .reachable(tempExists: false, finalExists: true),
        microphoneObservation: .reachable(tempExists: true, finalExists: false)
    )
    checkEqual(
        case1.action, .offerSalvage(mainTemporaryPath: nil, micTemporaryPath: micTemp),
        "主文件已提交但 mic 临时文件还在时必须提示抢救，不能删"
    )

    // ── 复审反例 2：allCommitted 但还没入轨就崩了。
    // 旧实现直接清账，用户再也收不到「有一段录制没进时间线」的提示。
    let case2 = Plan.make(
        manifest: manifest(.allCommitted),
        mainObservation: .reachable(tempExists: false, finalExists: true),
        microphoneObservation: .reachable(tempExists: false, finalExists: true)
    )
    checkEqual(
        case2.action,
        .offerImport(mainFinalPath: mainFinal, micFinalPath: micFinal, microphoneMissing: false),
        "allCommitted 且文件都在时应提示补入轨"
    )

    // ── 复审四 P1-5：主文件已提交、麦克风却不见了 —— **必须告警**。
    // 早先只在 mic == .committed 时填路径，其余一律静默，用户以为旁白也成功了。
    checkEqual(
        Plan.make(
            manifest: manifest(.allCommitted),
            mainObservation: .reachable(tempExists: false, finalExists: true),
            microphoneObservation: .reachable(tempExists: false, finalExists: false)
        ).action,
        .offerImport(mainFinalPath: mainFinal, micFinalPath: nil, microphoneMissing: true),
        "主文件已提交但 mic 丢失时要带出告警"
    )
    // 没录麦克风的会话不该被误报成「麦克风丢了」。
    checkEqual(
        Plan.make(
            manifest: manifest(.allCommitted, mic: false),
            mainObservation: .reachable(tempExists: false, finalExists: true),
            microphoneObservation: nil
        ).action,
        .offerImport(mainFinalPath: mainFinal, micFinalPath: nil, microphoneMissing: false),
        "没录麦克风就不该报麦克风丢失"
    )

    // ── 复审四 P1-1：纯 mic 提交阶段**不得**让主文件被认成已提交。
    //
    // 确定反例：主临时文件损坏、主最终路径上原本就有用户自己的文件、
    // mic 临时文件有效；用户选保留 mic，落盘阶段后崩溃。复用
    // `committingMicrophone` 的话，重启后用户那个无关文件会被当成本次录屏。
    checkEqual(
        manifest(.microphoneOnlyCommitting)
            .mainResolution(.reachable(tempExists: false, finalExists: true)),
        .notCommitted(tempExists: false),
        "纯 mic 阶段：主最终路径上的文件是用户原有的，不得认成已提交"
    )
    checkEqual(
        manifest(.microphoneOnlyCommitted)
            .mainResolution(.reachable(tempExists: false, finalExists: true)),
        .notCommitted(tempExists: false),
        "纯 mic 已提交阶段同样不得认定主文件已提交"
    )
    check(
        !manifest(.microphoneOnlyCommitted).committedFinalPaths.contains(mainFinal),
        "纯 mic 流程不得把主最终路径列为已提交"
    )
    // 对照：正常的 committingMicrophone 阶段主文件**确实**已提交
    // （证明上面三条不是恒真）。
    checkEqual(
        manifest(.committingMicrophone)
            .mainResolution(.reachable(tempExists: false, finalExists: true)),
        .committed,
        "正常 mic 提交阶段主文件已提交"
    )

    // ── 复审反例 3：任一路卷不可达就整体等待，不许半边裁决。
    let case3 = Plan.make(
        manifest: manifest(.mainCommitted),
        mainObservation: .reachable(tempExists: false, finalExists: true),
        microphoneObservation: .volumeUnavailable
    )
    checkEqual(case3.action, .waitForVolume, "mic 所在卷不可达时整体等待")
    check(
        case3.microphoneResolution?.observationIsInconclusive == true,
        "卷不可达要如实反映在 mic 裁决上"
    )

    // ── writing 阶段崩溃：临时文件在 → 抢救；不在 → 精确清理。
    checkEqual(
        Plan.make(
            manifest: manifest(.writing, mic: false),
            mainObservation: .reachable(tempExists: true, finalExists: false),
            microphoneObservation: nil
        ).action,
        .offerSalvage(mainTemporaryPath: mainTemp, micTemporaryPath: nil),
        "writing + 临时文件在 → 抢救"
    )
    checkEqual(
        Plan.make(
            manifest: manifest(.writing, mic: false),
            mainObservation: .reachable(tempExists: false, finalExists: false),
            microphoneObservation: nil
        ).action,
        .discardTemporaries(paths: [mainTemp]),
        "writing + 什么都没有 → 清掉点名的临时路径"
    )

    // writing 阶段最终路径上有文件：那是**用户原有的**（选了覆盖），绝不能当成
    // 本次录制去导入，更不能删。
    let userFileCase = Plan.make(
        manifest: manifest(.writing, mic: false),
        mainObservation: .reachable(tempExists: false, finalExists: true),
        microphoneObservation: nil
    )
    checkEqual(
        userFileCase.action, .discardTemporaries(paths: [mainTemp]),
        "writing 阶段最终路径上的文件是用户原有的，不得当作录制结果"
    )
    check(
        !userFileCase.action.touches(path: mainFinal),
        "任何动作都不许碰用户原有的最终文件"
    )

    // ── committingMain 的原子性：临时还在 = rename 没发生。
    checkEqual(
        Plan.make(
            manifest: manifest(.committingMain, mic: false),
            mainObservation: .reachable(tempExists: true, finalExists: true),
            microphoneObservation: nil
        ).action,
        .offerSalvage(mainTemporaryPath: mainTemp, micTemporaryPath: nil),
        "committingMain + 临时还在 = rename 未发生"
    )
    checkEqual(
        Plan.make(
            manifest: manifest(.committingMain, mic: false),
            mainObservation: .reachable(tempExists: false, finalExists: false),
            microphoneObservation: nil
        ).action,
        .reportMissing(paths: [mainFinal]),
        "committingMain + 两头都没有 = 丢了，如实报告"
    )

    // ── stage 说已提交、实测最终文件不在：如实报告，不拿别的文件顶。
    checkEqual(
        Plan.make(
            manifest: manifest(.mainCommitted, mic: false),
            mainObservation: .reachable(tempExists: false, finalExists: false),
            microphoneObservation: nil
        ).action,
        .reportMissing(paths: [mainFinal]),
        "mainCommitted 但文件不在 → committedButMissing → 报告"
    )

    // ── 清账判据只能是 ledger：处置没走完就不许清。
    let settled = ScreenRecordingRecoveryLedger(
        main: .init(resolution: .committed, disposition: .settled),
        microphone: .init(resolution: .committed, disposition: .settled)
    )
    check(settled.canClearManifest, "两路都了结才可清账")
    let importPending = ScreenRecordingRecoveryLedger(
        main: .init(resolution: .committed, disposition: .importPending),
        microphone: nil
    )
    check(!importPending.canClearManifest, "入轨事务未提交时不许清账")
    let micPending = ScreenRecordingRecoveryLedger(
        main: .init(resolution: .committed, disposition: .settled),
        microphone: .init(resolution: .notCommitted(tempExists: true), disposition: .pendingUserDecision)
    )
    check(!micPending.canClearManifest, "mic 还等用户决定时不许清账")
}

private extension ScreenRecordingRecoveryAction {
    /// 这个动作会不会动到某条路径（用来反证「绝不碰用户文件」）。
    func touches(path: String) -> Bool {
        switch self {
        case .discardTemporaries(let paths): return paths.contains(path)
        case .offerSalvage(let main, let mic): return [main, mic].compactMap { $0 }.contains(path)
        default: return false
        }
    }
}

// MARK: - 文件命名避让（复审 P1-2 / P1-3）

private func checkFileNaming() {
    let output = URL(fileURLWithPath: "/V/Rec.mov")

    // 没人占 → 用默认名。
    checkEqual(
        ScreenRecordingRequest.availableMicrophoneURL(for: output, isTaken: { _ in false }).path,
        "/V/Rec-Mic.m4a", "sidecar 默认名"
    )
    // 默认名被占 → **避让**，绝不覆盖（用户只确认过主文件的覆盖）。
    let taken: Set<String> = ["/V/Rec-Mic.m4a"]
    checkEqual(
        ScreenRecordingRequest.availableMicrophoneURL(
            for: output, isTaken: { taken.contains($0.path) }
        ).path,
        "/V/Rec-Mic 2.m4a", "sidecar 名字被占时避让"
    )
    let taken2: Set<String> = ["/V/Rec-Mic.m4a", "/V/Rec-Mic 2.m4a", "/V/Rec-Mic 3.m4a"]
    checkEqual(
        ScreenRecordingRequest.availableMicrophoneURL(
            for: output, isTaken: { taken2.contains($0.path) }
        ).path,
        "/V/Rec-Mic 4.m4a", "连续被占时继续往后找"
    )
    // 反向验证：断言不是恒真 —— 避让结果必须与被占的名字不同。
    check(
        !taken2.contains(ScreenRecordingRequest.availableMicrophoneURL(
            for: output, isTaken: { taken2.contains($0.path) }
        ).path),
        "避让结果不得落在已占用集合里"
    )

    // 通用避让保留扩展名。
    checkEqual(
        ScreenRecordingFileNaming.availableURL(
            like: URL(fileURLWithPath: "/V/Rec.mov"), isTaken: { $0.path == "/V/Rec.mov" }
        ).path,
        "/V/Rec 2.mov", "通用避让保留扩展名"
    )

    // request 传入 override 后，microphoneURL 必须跟着走。
    let request = ScreenRecordingRequest(
        sessionID: UUID(), source: .display(displayID: 1),
        microphone: .device(id: "mic"),
        outputURL: output, capturePixelSize: CGSize(width: 100, height: 100),
        documentGeneration: 0, canvasRatioSnapshot: "auto",
        canvasEditGeneration: 0, projectHadVisualMedia: false,
        microphoneOutputURL: URL(fileURLWithPath: "/V/Rec-Mic 2.m4a")
    )
    checkEqual(request.microphoneURL.path, "/V/Rec-Mic 2.m4a", "request 采用避让后的 sidecar 路径")
    check(
        request.temporaryURL(for: .microphone).path.contains("Rec-Mic 2"),
        "临时文件名跟随避让后的 sidecar，保证同目录 rename"
    )
}

// MARK: - 区域拖拽的边界夹取（复审二 P2 + 复审三 P2）

/// 三条约束一起验：**比例保持**、**完整落屏**、**锚点不动**。
///
/// 前两条是复审二的要求；第三条是复审三补的 —— 早先的实现「先算矩形再把它
/// 平移回屏内」，比例和包含关系都对，但 mouse-down 的锚点会整体跳走，
/// 手感是选区自己滑了一下。测试只断言比例和包含就抓不到（当时正是如此）。
private func checkRegionDragClamping() {
    typealias M = ScreenRecordingCoordinateMapper
    let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let ratio: CGFloat = 16.0 / 9

    func aspect(_ rect: CGRect) -> CGFloat { rect.width / rect.height }
    /// 矩形是否仍然「贴着」锚点（锚点必须是它的某一个角）。
    func touchesAnchor(_ rect: CGRect, _ anchor: CGPoint) -> Bool {
        let onX = abs(rect.minX - anchor.x) < 0.001 || abs(rect.maxX - anchor.x) < 0.001
        let onY = abs(rect.minY - anchor.y) < 0.001 || abs(rect.maxY - anchor.y) < 0.001
        return onX && onY
    }

    // 完全在屏内：与不带 bounds 的版本一致。
    let anchor = CGPoint(x: 100, y: 100)
    let inside = M.regionRect(
        anchor: anchor, current: CGPoint(x: 740, y: 460), ratio: ratio, bounds: screen
    )
    checkEqual(
        inside, M.regionRect(anchor: anchor, current: CGPoint(x: 740, y: 460), ratio: ratio),
        "屏内拖拽与无边界版本一致"
    )
    check(touchesAnchor(inside, anchor), "屏内：锚点是矩形的角")

    // 往右下拖到屏外：三条约束都要成立。
    let overRight = M.regionRect(
        anchor: anchor, current: CGPoint(x: 5000, y: 5000), ratio: ratio, bounds: screen
    )
    check(abs(aspect(overRight) - ratio) < 0.001, "右下越界后比例保持 16:9")
    check(screen.contains(overRight), "右下越界后完整落屏")
    check(touchesAnchor(overRight, anchor), "右下越界后**锚点仍是矩形的角**")

    // 往左下拖到屏外（负坐标）。
    let anchorRight = CGPoint(x: 1800, y: 900)
    let overLeft = M.regionRect(
        anchor: anchorRight, current: CGPoint(x: -900, y: -900), ratio: ratio, bounds: screen
    )
    check(abs(aspect(overLeft) - ratio) < 0.001, "左下越界后比例保持")
    check(screen.contains(overLeft), "左下越界后完整落屏")
    check(touchesAnchor(overLeft, anchorRight), "左下越界后锚点仍是矩形的角")
    // 方向：往左拖，矩形应当在锚点左侧。
    check(overLeft.maxX <= anchorRight.x + 0.001, "往左拖时矩形在锚点左边")
    check(overLeft.maxY <= anchorRight.y + 0.001, "往下拖时矩形在锚点下方")

    // 反向验证：本组断言不是恒真 —— 「先算矩形再平移回屏内」会让锚点脱开。
    let naive = M.regionRect(
        anchor: anchor, current: CGPoint(x: 5000, y: 5000), ratio: ratio
    )
    let translated = CGRect(
        x: min(naive.minX, screen.maxX - min(naive.width, screen.width)),
        y: min(naive.minY, screen.maxY - min(naive.height, screen.height)),
        width: min(naive.width, screen.width), height: min(naive.height, screen.height)
    )
    check(!touchesAnchor(translated, anchor), "平移式夹取确实会让锚点跳走（否则本组断言无意义）")

    // 自由比例同样不许越界。
    let free = M.regionRect(
        anchor: anchor, current: CGPoint(x: 9999, y: -9999), ratio: nil, bounds: screen
    )
    check(screen.contains(free), "自由比例越界后完整落屏")
    check(touchesAnchor(free, anchor), "自由比例下锚点仍是矩形的角")

    // 竖向比例受高度约束。
    let tall = M.regionRect(
        anchor: CGPoint(x: 0, y: 0), current: CGPoint(x: 5000, y: 5000),
        ratio: 9.0 / 16, bounds: screen
    )
    checkEqual(tall.height, 1080, "9:16 从原点拖满时应占满高度")
    check(abs(aspect(tall) - 9.0 / 16) < 0.001, "竖向比例保持")
}

// MARK: - journal 目标改址（复审二 P1-3）

/// 避让后的最终路径**必须先写进 manifest 再持久化意向**，
/// 所以要有一个「换目标但保持身份」的构造。
private func checkRetargeting() {
    let session = UUID()
    let base = ScreenRecordingManifest(
        sessionID: session, startedAt: Date(), stage: .mainCommitted,
        mainTemporaryPath: "/V/.a.partial.mov", mainFinalPath: "/V/a.mov",
        micTemporaryPath: "/V/.a-Mic.partial.m4a", micFinalPath: "/V/a-Mic.m4a"
    )

    let retargeted = base.retargetingMicrophone(to: "/V/a-Mic 2.m4a")
    checkEqual(retargeted.micFinalPath, "/V/a-Mic 2.m4a", "mic 最终路径已改址")
    checkEqual(retargeted.sessionID, session, "改址不改身份")
    checkEqual(retargeted.stage, base.stage, "改址不动 stage")
    checkEqual(retargeted.mainFinalPath, base.mainFinalPath, "改址不碰主文件路径")
    checkEqual(retargeted.micTemporaryPath, base.micTemporaryPath, "改址不碰临时路径")

    let mainRetargeted = base.retargetingMain(to: "/V/a 2.mov")
    checkEqual(mainRetargeted.mainFinalPath, "/V/a 2.mov", "主文件最终路径已改址")
    checkEqual(mainRetargeted.micFinalPath, base.micFinalPath, "改主文件不碰 sidecar")

    // `mainCommitted` 阶段 mic 本来就还没提交 —— 这里必须是 notCommitted，
    // 否则就是把「主文件提交了」误读成「sidecar 也提交了」。
    checkEqual(
        retargeted.microphoneResolution(.reachable(tempExists: false, finalExists: true)),
        .notCommitted(tempExists: false),
        "mainCommitted 阶段 mic 尚未提交"
    )
    // 走到 allCommitted 之后，裁决才跟着**改址后的**新路径走。
    var committed = base.retargetingMicrophone(to: "/V/a-Mic 2.m4a")
    committed.stage = .allCommitted
    checkEqual(committed.micFinalPath, "/V/a-Mic 2.m4a", "改址在 allCommitted 后仍生效")
    checkEqual(
        committed.microphoneResolution(.reachable(tempExists: false, finalExists: true)),
        .committed, "allCommitted + 新路径有文件 = 已提交"
    )
    checkEqual(
        committed.microphoneResolution(.reachable(tempExists: false, finalExists: false)),
        .committedButMissing, "allCommitted 但新路径没文件 = 如实报告缺失"
    )
}

// MARK: - 恢复期的工程锁（复审二 P1-6）

/// **走一遍 `start()` 真实的状态序列。**
///
/// 这一组的存在理由：早先的状态机自检逐条验单边，却从没把 happy path 端到端
/// 走一遍 —— 于是矩阵里少了 `.choosingSource → .choosingDestination` 这条边
/// 谁都没发现。后果是 `transition` 静默返回 false（它是 `@discardableResult`），
/// 状态卡在 `.choosingSource`，`runCountdown()` 的 guard 直接 return，
/// **录制永远不会开始**（真机首测暴露）。
private func checkStartHappyPath() {
    typealias S = ScreenRecordingState
    // 与 `ScreenRecordingCoordinator.start()` 里的 transition 调用顺序一一对应。
    let path: [(String, S)] = [
        ("configuring", .configuring),
        ("choosingSource", .choosingSource),
        ("choosingDestination", .choosingDestination),
        ("preparing", .preparing),
        ("countingDown", .countingDown(remaining: 3)),
        ("starting", .starting),
        ("recording", .recording(startedAt: Date())),
        ("stopping", .stopping),
        ("finishing", .finishing),
        ("importing", .importing),
    ]
    var current: S = .idle
    for (name, next) in path {
        let ok = S.canTransition(from: current, to: next)
        check(ok, "start() 的状态路径必须畅通：\(current) → \(name)")
        if ok { current = next }
    }
    check(current == .importing, "整条 happy path 应当能一路走到 importing")

    // 区域来源不经过 picker，`chooseSource` 之后可能直接从 configuring 去选目标。
    check(
        S.canTransition(from: .configuring, to: .choosingDestination),
        "区域来源：configuring 可直接进 choosingDestination"
    )
    // 反向：路径上的边不能顺手把非法跳转也放开。
    check(!S.canTransition(from: .choosingSource, to: .countingDown(remaining: 3)),
          "不许从选来源直接跳到倒计时")
    check(!S.canTransition(from: .choosingDestination, to: .recording(startedAt: Date())),
          "不许从选目标直接跳到录制中")
}

/// 音频完整性容差（真机首测抓到的误报）。
///
/// 真机录了 8 秒、全程正常，却被判 partial 并弹出
/// 「Computer audio starts 0:00 after the recording begins」——
/// 因为当时容差是「一个工程帧」（24 fps 下 41.7 ms），而计划 §8.3 白纸黑字写着
/// AAC priming 就有 ≈44 ms，**本来就大于一帧**。
private func checkAudioCoverageTolerance() {
    typealias C = ScreenRecordingAudioCoverage

    // AAC priming（2112 samples @48 kHz ≈ 44 ms）绝不能被判成缺陷。
    let aacPriming = 2112.0 / 48_000
    check(!C.isSignificant(aacPriming), "AAC priming(≈44ms) 不得判成音频缺失")
    // 一个工程帧的尺度（24/30/60 fps）同样都在容差内。
    for fps in [24.0, 30.0, 60.0] {
        check(!C.isSignificant(1.0 / fps), "\(Int(fps))fps 的一帧不得判成音频缺失")
    }
    // 真机观测到的那个间隙（小到格式化成 0:00，即 < 0.5 秒）不得报警。
    check(!C.isSignificant(0.2), "0.2 秒的启动间隙不得报警")
    check(!C.isSignificant(0.49), "刚好在容差内不报警")

    // 但「缺了好几秒」必须抓住 —— 这才是这条判据存在的理由。
    check(C.isSignificant(0.51), "刚过容差就要报警")
    check(C.isSignificant(2), "缺 2 秒必须报警")
    check(C.isSignificant(10), "缺 10 秒必须报警")

    // 容差本身必须显著大于 priming，否则等于没放开。
    check(C.toleranceSeconds > aacPriming * 5, "容差要显著大于 AAC priming")
}

/// 区域选择的默认框（真机首测反馈：上来空白、不知道要干什么）。
private func checkDefaultRegion() {
    typealias M = ScreenRecordingCoordinateMapper
    let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    for ratio in [16.0 / 9, 9.0 / 16, 1.0, 4.0 / 3] as [CGFloat] {
        let rect = M.defaultRegion(in: screen, ratio: ratio)
        check(screen.contains(rect), "默认框完整落屏（ratio=\(ratio)）")
        check(abs(rect.width / rect.height - ratio) < 0.02, "默认框遵守所选比例")
        check(M.isUsableRegion(rect), "默认框不能小到不可用")
        check(abs(rect.midX - screen.midX) <= 1 && abs(rect.midY - screen.midY) <= 1,
              "默认框居中")
    }
    // 自由档也要给一个像样的框，不能是零。
    let free = M.defaultRegion(in: screen, ratio: nil)
    check(M.isUsableRegion(free), "自由档同样给出可用的默认框")
    check(screen.contains(free), "自由档默认框完整落屏")
    // 反向：不能大到铺满整屏（那就等于整屏录制，失去区域的意义）。
    check(free.width < screen.width, "默认框不该铺满整屏")

    // 极窄屏也不能溢出。
    let narrow = CGRect(x: 0, y: 0, width: 800, height: 2000)
    let tall = M.defaultRegion(in: narrow, ratio: 16.0 / 9)
    check(narrow.contains(tall), "竖长屏上默认框仍完整落屏")
}

/// display-local → AppKit 全局的反向换算（录制期遮罩要用它摆窗口）。
///
/// **拿本机实测拓扑当真值对账**，不只验往返 —— 错误的翻转轴同样自反。
private func checkAppKitRectFromDisplayLocal() {
    typealias M = ScreenRecordingCoordinateMapper
    // 本机真实拓扑：主屏 (0,0) 1440x900 点；副屏 CGDisplayBounds=(-279,-1080)。
    let main = M.DisplayGeometry(
        boundsInPoints: CGRect(x: 0, y: 0, width: 1440, height: 900),
        pixelSize: CGSize(width: 2880, height: 1800)
    )
    let secondary = M.DisplayGeometry(
        boundsInPoints: CGRect(x: -279, y: -1080, width: 1920, height: 1080),
        pixelSize: CGSize(width: 3840, height: 2160)
    )
    let mainHeight: CGFloat = 900

    // 主屏左上角 100x50 的框（display-local，y 向下）
    // → CG 全局 (100,50)；AppKit y = 900 - (50+200) = 650。
    let topLeftLocal = CGRect(x: 100, y: 50, width: 300, height: 200)
    checkEqual(
        M.appKitRect(fromDisplayLocal: topLeftLocal, display: main,
                     mainDisplayHeightInPoints: mainHeight),
        CGRect(x: 100, y: 650, width: 300, height: 200),
        "主屏：display-local 左上角框换算到 AppKit"
    )

    // 副屏（负原点）：local(0,0) → CG 全局 (-279,-1080)
    // → AppKit y = 900 - (-1080 + 100) = 1880。
    checkEqual(
        M.appKitRect(fromDisplayLocal: CGRect(x: 0, y: 0, width: 400, height: 100),
                     display: secondary, mainDisplayHeightInPoints: mainHeight),
        CGRect(x: -279, y: 1880, width: 400, height: 100),
        "副屏（负原点）换算到 AppKit"
    )

    // 与正向换算互为逆：AppKit → local → AppKit 必须回到原处。
    for rect in [
        CGRect(x: 10, y: 20, width: 200, height: 120),
        CGRect(x: 700, y: 400, width: 300, height: 180),
    ] {
        guard let local = M.displayLocalRect(
            fromAppKit: rect, display: main, mainDisplayHeightInPoints: mainHeight
        ) else { check(false, "本该落在主屏内"); continue }
        checkEqual(
            M.appKitRect(fromDisplayLocal: local, display: main,
                         mainDisplayHeightInPoints: mainHeight),
            rect, "正反换算互逆"
        )
    }

    // 反向验证：若把翻转轴误当成「屏幕并集顶边」（这里是 1080-1080=... 取 1980），
    // 主屏那个框的结果就会不同 —— 证明上面的断言不是恒真。
    check(
        M.appKitRect(fromDisplayLocal: topLeftLocal, display: main,
                     mainDisplayHeightInPoints: 1980)
            != CGRect(x: 100, y: 650, width: 300, height: 200),
        "翻转轴用错会得到不同结果（断言有区分力）"
    )
}

private func checkRecoveryLock() {
    typealias S = ScreenRecordingState
    // 崩溃恢复的处置期间同样要锁工程切换，所以要有 idle → partialRecovery。
    let result = ScreenRecordingResult(
        mainURL: URL(fileURLWithPath: "/V/a.mov"), duration: 1,
        pixelSize: CGSize(width: 2, height: 2), frameRate: .fallback
    )
    check(S.canTransition(from: .idle, to: .partialRecovery(result)), "idle 可进恢复处置")
    check(S.partialRecovery(result).locksProjectSwitching, "恢复处置期间锁工程切换")
    check(S.importing.locksProjectSwitching, "入轨期间锁工程切换")
    // 反向：不能从 idle 直接跳进写盘期。
    check(!S.canTransition(from: .idle, to: .recording(startedAt: Date())), "idle 不可直达 recording")
    check(!S.canTransition(from: .idle, to: .importing), "idle 不可直达 importing")
}

func runScreenRecordingChecks() {
    checkCoordinateMapper()
    checkRecordingModels()
    checkProjectFrameRate()
    checkOptionsAndNaming()
    checkRecoveryPlan()
    checkFileNaming()
    checkRegionDragClamping()
    checkRetargeting()
    checkRecoveryLock()
    checkStartHappyPath()
    checkAudioCoverageTolerance()
    checkDefaultRegion()
    checkAppKitRectFromDisplayLocal()
}
