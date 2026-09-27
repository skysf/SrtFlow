import AVFoundation
import Foundation
import SrtFlowCore

// 把可听的片段变成词流：定语言（手选 / 自动检测）→ 备模型（租约）→ 账本查缺、按窗抽音频、转写、合并落 sidecar。
//
// 管什么：生成字幕和 AI 的 transcribe 共用的那一段。2026-09-27 从 `TranscriptionTask` 原样挪出来（那个文件到了 600 行，
// AI 又要一个「只转写、不生成字幕」的入口），代码没改，只把「改阶段 / 进度 / 灰字 / 跳过名单 / 模型下载进度」换成
// `Hooks` 交回去。纪律照旧：每个 await 前后查取消令牌；模型租约成功即持有、所有出口 await 归还后才离开；读不了的
// 素材跳过并记名，转写栈的故障如实上抛。
// 不管什么：任务状态机、串行槽、分段合成、写回工程、翻译（TranscriptionTask）。

@available(macOS 26.0, *)
@MainActor
struct TranscriptHarvester {
    typealias SoundClip = SubtitleAudibleClips.SoundClip

    /// 转写阶段的收成：词流账本 + 跳过的素材。分段永远基于**写回时**的时间线。
    struct Harvest {
        var locale: Locale
        var entries: [String: TranscriptCacheEntry]
        var skippedFingerprints: Set<String>
    }

    /// 进行到哪儿，交回给跑任务的那一方（`TranscriptionTask` 发成面板上的阶段和进度）。
    struct Hooks: Sendable {
        var stage: @MainActor @Sendable (TranscriptionTask.Stage) -> Void
        var progress: @MainActor @Sendable (Double) -> Void
        var volatileText: @MainActor @Sendable (String?) -> Void
        var skipped: @MainActor @Sendable ([String]) -> Void
        /// 模型在下载：交回它的 Progress（取消要能穿透它，进度折进 0.02–0.1 段）；nil = 下载阶段过去了。
        var installing: @MainActor @Sendable (Progress?) -> Void
    }

    struct HarvestError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// 自动检测的探针窗口时长（秒）。产品参数：够长到词数可判，
    /// 够短到多候选探针仍在秒级。
    static let detectionProbeSeconds = 20.0

    /// 断点续跑的窗口粒度：每 ≤2 分钟音频转写完就落一次 sidecar。
    static let windowSeconds = 120.0

    let service: SpeechTranscriptionService
    let token: ExportCancellationToken
    let hooks: Hooks

    /// 这几段（本次任务冻结的可听快照）转成词流。`sourceLocaleID` 是 `TranscriptionTask.autoDetectLocaleID` 时先检测。
    func harvest(clips: [SoundClip], sourceLocaleID: String) async throws -> Harvest {
        let locale: Locale
        if sourceLocaleID == TranscriptionTask.autoDetectLocaleID {
            // 只把**本次任务冻结的可听快照**交给检测：它拿不到 TimelineState，
            // 也就不可能再分叉出第二套「声音来源」（PR#22 复审 P1）。
            locale = try await detectSourceLocale(clips: clips)
        } else if let matched = await SpeechTranscriptionService.matchedLocale(for: sourceLocaleID) {
            locale = matched
        } else {
            throw HarvestError(message: String(
                format: L10n("Speech transcription doesn't support “%@” on this Mac."),
                sourceLocaleID
            ))
        }

        // ① 模型。下载进度折进总进度 0.02–0.1 段，不再完成前一直停 0；
        // 下载期间取消（切工程/Stop）经 Progress.cancel + 任务取消传播生效，
        // 下载抛出的取消类错误统一归一成 CancellationError。
        hooks.stage(.preparingModels)
        if token.isCancelled { throw CancellationError() }
        // 进度回调交给 `hooks.installing`，那边按 token 验明正身再写状态（评审 P2）：回调是异步
        // hop 过来的，可能在旧任务取消/清理甚至新任务启动后才到 —— 旧 Progress/KVO 不许复活到新任务头上。
        do {
            try await service.ensureModel(locale: locale) { [hooks] progress in
                Task { @MainActor in hooks.installing(progress) }
            }
        } catch {
            if token.isCancelled || Task.isCancelled { throw CancellationError() }
            throw error
        }
        // 从这里起持有一份租约计数（ensureModel 成功 = 持有；失败已自清）。
        // 所有出口都 **await 归还后才离开** —— 终态前清理完毕，下一个任务
        // 启动时不会与迟到的释放竞速；计数账本（SpeechModelLeases）再兜一层
        // 跨任务共享（评审 P1）。
        do {
            let harvest = try await collectWindows(clips: clips, locale: locale)
            await service.releaseModel(locale: locale)
            return harvest
        } catch {
            await service.releaseModel(locale: locale)
            throw error
        }
    }

    // MARK: 源语言自动检测（两段式：候选模型分别转写探针，按置信度裁决）

    /// macOS 26 的 SpeechTranscriber 必须显式给语言、系统没有音频语言识别，
    /// 所以自动检测 = 探针转写 + 打分。候选按优先级：素材元数据指名的语言
    /// （允许触发模型下载）→ 系统首选 → 其余已装语言（这两类必须已装，
    /// 探针不为它们下载模型），去重后上限 3。
    ///
    /// **每个候选都要过探针，一个也不例外**（PR#22 复审 P1）。曾经写过
    /// 「单候选直接采用」的捷径 —— 那是零证据的硬猜：候选表是「装了哪些模型」
    /// 决定的，跟素材说什么语言毫无关系，只装了一个模型的 Mac 会把任何语言的
    /// 视频都按那个语言整轨生成。裁决走 `SubtitleLanguageDetection.pick`
    /// （fail-closed，评分合同在 SrtFlowCore，SrtFlowCoreChecks 有用例），
    /// 拿不到判决就如实报「检测不出来，请手选」。
    ///
    /// - Parameter clips: 本次任务冻结的可听快照（`soundClips(in:)` 的产物）。
    ///   **刻意不收 `TimelineState`**：metadata 查询、探针抽取都只能从这一份
    ///   快照里取素材，这样「元数据指名的语言」和「探针听到的声音」在类型上
    ///   就不可能来自两批不同的素材。
    private func detectSourceLocale(clips: [SoundClip]) async throws -> Locale {
        hooks.stage(.detectingLanguage)
        if token.isCancelled { throw CancellationError() }
        hooks.progress(0.01)

        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SrtFlow-ASR-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        // 探针素材先定下来，而且是**真的抽一次音频**才算定下 ——「文件在」不等于
        // 「音轨读得出来」。读不了的往下顺延，metadata 的查询顺序再以最终选中的
        // 那一段为首（PR#22 复审第二轮 P2）。还要**有人声**：长的先，每段先用一个已装语言短转写
        // 听一听，音效、纯音乐拿去检测必然失败（2026-09-26 案例）。
        let screening = await SpeechTranscriptionService.screeningLocale()
        let service = self.service
        let probe = try await SubtitleAudibleClips.selectProbe(
            in: clips, probeSeconds: Self.detectionProbeSeconds,
            isCancelled: { token.isCancelled },
            extract: { clip, range in
                try await AudioWindowReader.extract(
                    assetURL: clip.url, range: range, into: tempDirectory, isCancelled: { token.isCancelled }
                )
            },
            hasSpeech: { _, file, range in
                guard let screening else { return true }
                return try await service.hasSpeech(fileURL: file, locale: screening, sourceOffset: range.start)
            }
        )
        // nil 只可能是「确实全都读不出音频」（selectProbe 返回 nil 前自己查过
        // 取消）。这里再查一遍是同一条纪律的第二道：**每个 await 前后**都要问，
        // 别让取消被翻译成失败文案。
        if token.isCancelled { throw CancellationError() }
        guard let probe else {
            throw HarvestError(message: L10n(
                "None of the audio sources could be read. Relink the missing media and try again."
            ))
        }
        if !probe.skipped.isEmpty {
            hooks.skipped(probe.skipped.map(\.name))
        }
        if token.isCancelled { throw CancellationError() }

        let metadataTag = await Self.metadataLanguageTag(
            in: SubtitleAudibleClips.metadataOrder(in: clips, probe: probe.clip)
        )
        // 候选来源按优先级排：元数据（唯一允许下载）→ 系统首选 → 其余已装。
        // **已装那一档要排序**：`installedLocales()` 的顺序本机实测连续两次读
        // 都可能不同，不排序的话「哪三个语言进探针」会随机漂移。
        var sources: [SubtitleLanguageDetection.CandidateSource] = []
        if let metadataTag,
           let matched = await SpeechTranscriptionService.matchedLocale(for: metadataTag) {
            sources.append(.init(localeIdentifier: matched.identifier, allowsDownload: true))
        }
        let installed = await SpeechTranscriptionService.installedLocales()
        let installedIDs = Set(installed.map(\.identifier))
        for id in Locale.preferredLanguages + installed.map(\.identifier).sorted() {
            // 元数据之外的候选必须已装 —— 自动检测不许静默拉起 N 份模型下载。
            guard let matched = await SpeechTranscriptionService.matchedLocale(for: id),
                  installedIDs.contains(matched.identifier) else { continue }
            sources.append(.init(localeIdentifier: matched.identifier, allowsDownload: false))
        }
        // 去重按**语言**不按 locale 标识符：en_US/en_SG/en_IN 是同一种语言的三个
        // 变体，按标识符去重会让它们吃光三个名额（实测取到过
        // ["en_US", "zh_CN", "en_IN"]），装了日语模型也永远探不到日语。
        let candidates = SubtitleLanguageDetection.selectCandidates(sources)
            .map { Locale(identifier: $0.localeIdentifier) }
        guard !candidates.isEmpty else {
            throw HarvestError(message: L10n(
                "Couldn't detect the spoken language — no speech model is installed. Pick the language manually so its model can be downloaded."
            ))
        }

        // **不因为「只有一个候选」跳过探针** —— 见方法头的说明。
        let probeFile = probe.file
        let probeRange = probe.range
        var results: [SubtitleLanguageDetection.Candidate] = []
        for candidate in candidates {
            if token.isCancelled { throw CancellationError() }
            do {
                try await service.ensureModel(locale: candidate) { _ in }
            } catch {
                if token.isCancelled || Task.isCancelled { throw CancellationError() }
                // 单个候选的模型装不上不致命：剩下的候选照样能裁决。
                continue
            }
            do {
                let words = try await service.transcribe(
                    fileURL: probeFile, locale: candidate, sourceOffset: probeRange.start
                )
                results.append(SubtitleLanguageDetection.Candidate(
                    localeIdentifier: candidate.identifier, words: words
                ))
                await service.releaseModel(locale: candidate)
            } catch {
                await service.releaseModel(locale: candidate)
                if token.isCancelled || Task.isCancelled { throw CancellationError() }
                // 转写栈的故障如实上抛，不许伪装成「检测不出语言」。
                throw error
            }
        }
        if token.isCancelled { throw CancellationError() }
        guard let verdict = SubtitleLanguageDetection.pick(results),
              let winner = candidates.first(where: { $0.identifier == verdict.localeIdentifier })
        else {
            throw HarvestError(message: L10n(
                "Couldn't confidently detect the spoken language. Pick it in the panel and generate again."
            ))
        }
        return winner
    }

    /// 音轨语言 metadata（自动检测候选的最高优先级；之前在面板里做 Picker
    /// 预填，现随「自动检测」迁到任务侧）。
    ///
    /// **只消费传进来的可听快照**，绝不回头去枚举 `TimelineState` —— 那样会
    /// 分叉出一套无视眼睛/静音、还漏掉带声音 overlay 的「声音来源」。
    private static func metadataLanguageTag(in clips: [SoundClip]) async -> String? {
        for clip in clips {
            let asset = AVURLAsset(url: clip.url)
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first else {
                continue
            }
            if let tag = try? await track.load(.extendedLanguageTag), tag != "und" {
                return tag
            }
            if let code = try? await track.load(.languageCode), code != "und" {
                return code
            }
        }
        return nil
    }

    /// 持有租约期间的主体：账本查缺 → 逐窗抽音频/转写/落盘。
    private func collectWindows(clips: [SoundClip], locale: Locale) async throws -> Harvest {
        hooks.installing(nil)
        if token.isCancelled { throw CancellationError() }
        hooks.progress(0.1)

        // ② 逐素材：账本查缺 → 抽音频 → 转写 → 合并落 sidecar。
        AudioWindowReader.sweepTempResidue()
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SrtFlow-ASR-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let grouped = Dictionary(grouping: clips, by: \.fingerprint)
        var entries: [String: TranscriptCacheEntry] = [:]

        // 进度分母：所有缺口的音频时长（命中缓存的部分零成本，进度如实反映）。
        // 缺口再切成 ≤windowSeconds 的固定窗口：每个窗口转写完立即入账落盘，
        // 长素材中途取消/崩溃最多丢一个窗口，且进度按窗口平滑推进。
        var plans: [(fingerprint: String, url: URL, name: String, windows: [SourceRange])] = []
        var totalWindowDuration = 0.0
        for (fingerprint, group) in grouped.sorted(by: { $0.key < $1.key }) {
            guard let sample = group.first else { continue }
            let entry = TranscriptSidecarStore.load(
                fingerprint: fingerprint,
                localeIdentifier: locale.identifier,
                transcriber: SpeechTranscriptionService.transcriberKind,
                configVersion: TranscriptSidecarStore.configVersion
            ) ?? TranscriptCacheEntry(
                fingerprint: fingerprint,
                localeIdentifier: locale.identifier,
                transcriber: SpeechTranscriptionService.transcriberKind,
                configVersion: TranscriptSidecarStore.configVersion
            )
            entries[fingerprint] = entry
            let desired = group.map {
                SourceRange(start: $0.sourceStart, end: $0.sourceStart + $0.sourceDuration)
            }
            // 素材边界取整组已知时长的最大值；info 全缺时退到用到的最远区间
            // （不能拿 group.first 的短切片当边界，会截掉远处切片的 padding）。
            let assetEnd = group.compactMap(\.knownAssetDuration).max()
                ?? desired.map(\.end).max() ?? 0
            let gaps = TranscriptLedger.padded(
                TranscriptLedger.gaps(desired: desired, covered: entry.covered),
                padding: 0.5,
                within: SourceRange(start: 0, end: assetEnd)
            )
            let windows = TranscriptLedger.windows(gaps, maxDuration: Self.windowSeconds)
            totalWindowDuration += windows.reduce(0) { $0 + $1.duration }
            plans.append((fingerprint, sample.url, sample.name, windows))
        }

        var doneDuration = 0.0
        var skippedFingerprints: Set<String> = []
        var skippedNames: [String] = []
        planLoop: for plan in plans {
            if token.isCancelled { throw CancellationError() }
            // 只有「这个素材读不了」才跳过（缺文件、缺音轨、解码失败）；
            // 转写/模型/临时目录这类系统性错误保留原始原因直接失败 ——
            // 不许把 Speech 故障伪装成「素材不可读」（评审 P2）。
            guard FileManager.default.fileExists(atPath: plan.url.path) else {
                skippedFingerprints.insert(plan.fingerprint)
                skippedNames.append(plan.name)
                continue
            }
            for window in plan.windows {
                if token.isCancelled { throw CancellationError() }
                hooks.stage(.readingAudio(plan.name))
                // 抽取窗口两侧各多带 0.5s 上下文（超出素材末尾由 reader
                // 自然截断）；入账时只认词中点落在本窗口内的结果 ——
                // 与 5.3 边界合同同一中点规则，相邻窗口不重复不遗漏。
                let extended = SourceRange(
                    start: max(0, window.start - 0.5), end: window.end + 0.5
                )
                let audioFile: URL
                do {
                    audioFile = try await AudioWindowReader.extract(
                        assetURL: plan.url, range: extended, into: tempDirectory,
                        isCancelled: { token.isCancelled }
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as AudioWindowReader.InfrastructureError {
                    throw error
                } catch {
                    skippedFingerprints.insert(plan.fingerprint)
                    skippedNames.append(plan.name)
                    continue planLoop
                }
                defer { try? FileManager.default.removeItem(at: audioFile) }

                if token.isCancelled { throw CancellationError() }
                hooks.stage(.transcribing(plan.name))
                let words = try await service.transcribe(
                    fileURL: audioFile, locale: locale, sourceOffset: extended.start
                ) { [hooks] text in
                    Task { @MainActor in hooks.volatileText(text) }
                }
                if token.isCancelled { throw CancellationError() }

                let owned = words.filter { word in
                    let mid = (word.start + word.end) / 2
                    return mid >= window.start && mid < window.end
                }
                // 空结果也记账（分析过、无语音），避免反复重扫；随窗落盘。
                entries[plan.fingerprint]?.merge(words: owned, analyzed: window)
                if let entry = entries[plan.fingerprint] {
                    TranscriptSidecarStore.save(entry)
                }
                doneDuration += window.duration
                if totalWindowDuration > 0 {
                    hooks.progress(0.1 + 0.75 * (doneDuration / totalWindowDuration))
                }
            }
        }
        hooks.volatileText(nil)
        hooks.skipped(skippedNames)
        // 全部音源都读不了才算失败（方案 10.1）。
        let usable = plans.contains { !skippedFingerprints.contains($0.fingerprint) }
        guard usable || plans.isEmpty else {
            throw HarvestError(message: L10n(
                "None of the audio sources could be read. Relink the missing media and try again."
            ))
        }
        return Harvest(
            locale: locale, entries: entries, skippedFingerprints: skippedFingerprints
        )

    }
}
