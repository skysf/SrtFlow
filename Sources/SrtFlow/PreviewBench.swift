import AppKit
import AVFoundation
import Darwin

// 预览性能测试（docs/architecture/preview-perf-ratchet.md）。
//
// 只在 CI 上跑：scripts/check-preview-perf.sh 起一个真 App，挂上这几个环境变量 ——
//   SRTFLOW_BENCH_OUT=<json>        结果写到这里。设了它才会跑，也才会记账（PerfCounters）
//   SRTFLOW_BENCH_MEDIA=<目录>       现生成的素材（文件名见 PreviewBenchScenario.Media）
//   SRTFLOW_BENCH_SCENARIO=<名字>    basic / busy
// 跑完写结果、直接 exit：不走正常退出 —— 未命名工程退出时会弹「要不要保存」。
//
// 各阶段量的都是「做了多少件活」（PerfCounters），不是 CPU 时间：GitHub 的 runner
// 读不到指令计数器，CPU 时间在 runner 之间差到两倍。CPU 时间照样记下来，只报不卡。

@MainActor
enum PreviewBench {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// 时钟连跳的次数和步长：每跳一下播放时间前进 0.05 秒（和播放时一样），跳 60 下。
    /// 跳之间不按固定间隔，而是等界面停下来（见 `run`）。
    static let tickCount = 60
    static let tickInterval = 0.05

    /// 窗口尺寸钉死：画不画、画多少跟窗口多大有关（Canvas 只画看得见的部分），
    /// 本机的屏幕和 CI 的 1024×768 不一样大。
    static let windowSize = CGSize(width: 1000, height: 720)

    private static var started = false

    /// 编辑器出现时调（VideoEditView.onAppear）。没设 `SRTFLOW_BENCH_OUT` 就什么都不做。
    static func startIfRequested(project: VideoEditProject) {
        guard PerfCounters.isEnabled, !started else { return }
        started = true
        let env = ProcessInfo.processInfo.environment
        let output = URL(fileURLWithPath: env[PerfCounters.outputKey] ?? "")
        // 看门狗：哪一步卡死都别让 CI 干等到 job 超时。它在别的线程上，主线程死锁也叫得醒。
        DispatchQueue.global().asyncAfter(deadline: .now() + 240) {
            writeFailure("超时：240 秒还没跑完", to: output)
            exit(3)
        }
        guard let mediaPath = env["SRTFLOW_BENCH_MEDIA"],
              let scenario = PreviewBenchScenario(rawValue: env["SRTFLOW_BENCH_SCENARIO"] ?? "") else {
            writeFailure("缺 SRTFLOW_BENCH_MEDIA，或 SRTFLOW_BENCH_SCENARIO 不是 basic / busy", to: output)
            exit(2)
        }
        Task {
            do {
                let result = try await run(scenario, project: project, media: URL(fileURLWithPath: mediaPath))
                let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: output)
                exit(0)
            } catch {
                writeFailure(String(describing: error), to: output)
                exit(1)
            }
        }
    }

    // MARK: - 流程

    private static func run(
        _ scenario: PreviewBenchScenario, project: VideoEditProject, media: URL
    ) async throws -> [String: Any] {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else {
            throw Failure("没有可见的窗口 —— 这台机器没有图形会话？")
        }
        window.setFrame(NSRect(origin: window.frame.origin, size: windowSize), display: true)

        try await scenario.build(on: project, media: media)
        // 搭场景时有导入、缩略图、波形在后台陆续落地，等它们全停下来（放宽到 1.5 秒）。
        try await settle(project, quietFor: 1.5, timeout: 90)

        let name = scenario.rawValue
        var gated: [String: Int] = [:]
        var report: [String: Double] = [:]
        var breakdown: [String: [String: Int]] = [:]

        // 空闲：什么都不做。有东西在空转（定时器、没停的动画）就会记上账。
        let idle = try await measure {
            try await Task.sleep(for: .seconds(3))
        }
        record(idle, as: "\(name).idle", into: &gated, &report, &breakdown)

        // 时钟连跳：走真播放同一个入口（observePlaybackTime），播放器本身停着 ——
        // 量的是「时钟跳一下，界面要重算多少东西」。
        //
        // **每跳一下都等界面完全停下来再跳下一下**，不能按固定间隔跳：有些重绘跟着屏幕
        // 刷新走，一跳的更新要是拖过了下一跳（CI 上 busy 场景一跳就要吃约 58ms CPU），
        // 两跳会并成一次刷新，数就随机器快慢变了 —— 2026-09-24 首跑两遍标尺重算
        // 55 / 59 次，就是按 50ms 固定间隔跳的。
        let ticks = try await measure {
            for step in 1...tickCount {
                project.clock.observePlaybackTime(scenario.tickStart + Double(step) * tickInterval)
                try await settle(project, quietFor: 0.12, timeout: 30)
            }
        }
        guard ticks.counts["event:\(PerfCounters.Event.clockTick.rawValue)"] == tickCount else {
            throw Failure("时钟连跳记到的次数不对：\(ticks.counts) —— 计数没接上，数字不可信")
        }
        record(ticks, as: "\(name).ticks", into: &gated, &report, &breakdown)

        // 改几刀：重建合成、开素材、换播放条目、建 tap 各几次 —— 这些卡住。
        // 这一段的 body / Canvas 次数**只报不卡**：一刀下去是防抖、建合成、换条目、seek
        // 一串异步的事，中间刷几次屏看时机（首跑两遍差 1–9 次），固定不下来。
        let edits = try await measure {
            try await scenario.edits(on: project) {
                try await settle(project, quietFor: 0.6, timeout: 30)
            }
        }
        var editWork: [String: Int] = [:]
        record(edits, as: "\(name).edits", into: &editWork, &report, &breakdown)
        for (key, value) in editWork { report[key] = Double(value) }
        for event in [PerfCounters.Event.compositionBuild, .compositionAssetOpen, .playerItemAttach,
                      .meterTapCreate, .audioMixRefresh] {
            gated["\(name).edits.\(event.rawValue)"] = edits.counts["event:\(event.rawValue)"] ?? 0
        }

        // 合成负载（GPU / 解码的代理数字）：每帧合成几层、多少像素、挂几层滤镜。
        let load = try await PreviewBenchComposition.measure(
            item: project.clock.player.currentItem, project: project
        )
        gated["\(name).video.compositionTracks"] = load.compositionTracks
        gated["\(name).video.layerFrames"] = load.layerFrames
        gated["\(name).video.megapixelFrames"] = load.megapixelFrames
        gated["\(name).filters.frames"] = load.filterFrames

        // 真播放 3 秒：跳几下由播放器按真实时间定，机器慢就少跳 —— 只报不卡。
        let playback = try await measure {
            project.clock.player.play()
            try await Task.sleep(for: .seconds(3))
            project.clock.player.pause()
            try await settle(project, quietFor: 0.3, timeout: 30)
        }
        var ungated: [String: Int] = [:]
        record(playback, as: "\(name).playback", into: &ungated, &report, &breakdown)
        for (key, value) in ungated { report[key] = Double(value) }
        report["\(name).playback.ticks"] = Double(playback.counts["event:\(PerfCounters.Event.clockTick.rawValue)"] ?? 0)

        return [
            "scenario": name,
            "gated": gated,
            "memory": ["\(name).memory.peakMB": peakFootprintMB()],
            "report": report,
            "breakdown": breakdown,
        ]
    }

    // MARK: - 量一段

    private struct Phase {
        var counts: [String: Int]
        var cpuMs: Double
        var wallMs: Double
    }

    private static func measure(_ body: () async throws -> Void) async throws -> Phase {
        PerfCounters.reset()
        let cpu = cpuTimeMs()
        let wall = Date()
        try await body()
        return Phase(
            counts: PerfCounters.snapshot(),
            cpuMs: cpuTimeMs() - cpu,
            wallMs: Date().timeIntervalSince(wall) * 1000
        )
    }

    /// 一段的计数按种类加总进 `gated`，明细进 `breakdown`，CPU 时间进 `report`。
    private static func record(
        _ phase: Phase, as prefix: String,
        into gated: inout [String: Int], _ report: inout [String: Double],
        _ breakdown: inout [String: [String: Int]]
    ) {
        for kind in ["body", "update", "canvas"] {
            gated["\(prefix).\(kind)"] = phase.counts
                .filter { $0.key.hasPrefix("\(kind):") }
                .reduce(0) { $0 + $1.value }
        }
        report["\(prefix).cpuMs"] = phase.cpuMs.rounded()
        report["\(prefix).wallMs"] = phase.wallMs.rounded()
        breakdown[prefix] = phase.counts
    }

    /// 等预览落定：不在重建、不在导入、播放条目就绪、后台没有在读的缩略图 / 波形，
    /// 而且计数连续 `quietFor` 秒没动过。
    ///
    /// 光看「计数一段时间没动」不够：后台解码缩略图时界面一下都不动，解完才更新一次
    /// （2026-09-24：空闲阶段冒出一次缩略图重画，那一遍空闲时 CPU 276ms、另一遍 28ms）。
    private static func settle(_ project: VideoEditProject, quietFor: Double, timeout: Double) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var last = PerfCounters.snapshot()
        var quietSince = Date()
        while true {
            try await Task.sleep(for: .milliseconds(50))
            let now = PerfCounters.snapshot()
            let busy = project.isRebuildingPreview || project.importingCount > 0
                || project.clock.player.currentItem?.status != .readyToPlay
                || PerfCounters.backgroundReadsInFlight > 0
            if busy || now != last {
                last = now
                quietSince = Date()
            } else if Date().timeIntervalSince(quietSince) >= quietFor {
                return
            }
            if Date() > deadline {
                throw Failure("\(Int(timeout)) 秒内等不到预览落定（重建中=\(project.isRebuildingPreview)，"
                    + "导入中=\(project.importingCount)，后台在读=\(PerfCounters.backgroundReadsInFlight)，"
                    + "条目=\(String(describing: project.clock.player.currentItem?.status.rawValue))）")
            }
        }
    }

    // MARK: - 进程级读数

    private static func cpuTimeMs() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let seconds = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        return seconds * 1000
    }

    /// 整个进程到此刻为止的内存峰值（活动监视器「内存」那一列的口径）。
    private static func peakFootprintMB() -> Double {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard rc == 0 else { return -1 }
        return (Double(info.ri_lifetime_max_phys_footprint) / 1_048_576 * 10).rounded() / 10
    }

    nonisolated private static func writeFailure(_ message: String, to output: URL) {
        let body = ["error": message]
        if let data = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted]) {
            try? data.write(to: output)
        }
    }
}
