import AVFoundation
import Foundation
import Speech
import SrtFlowCore

// SpeechAnalyzer 转写服务（macOS 26+，docs/plans/…… 第 3.2/3.3 节）。
//
// 模块选择收敛在这里（AGENTS 抽象克制）：V1 只有 SpeechTranscriber，
// isAvailable == false 或语言不支持时明确报错，不做后备（计划 1.2）。
// 词级结果从 finalized AttributedString 的 run 上取
// audioTimeRange + transcriptionConfidence（Phase 0 实测：真词级、自带标点）。

/// App 级 locale reservation 的引用计数管理。
///
/// `AssetInventory.reserve/release` 是 **app 全局**的：reserve 返回 false =
/// app 已持有该 locale；release 会移除唯一的 app 级 reservation。任务各自
/// fire-and-forget 释放会互相拆台（A 退场时把 B 正依赖的租约拆掉），
/// 所以进出一律走这里：计数归零才真正 release，acquire 与 release 严格配对。
@available(macOS 26.0, *)
actor SpeechModelLeases {
    static let shared = SpeechModelLeases()
    private var counts: [String: Int] = [:]

    /// 取得（或共享）一份租约。成功返回后调用方必须恰好 release 一次。
    func acquire(_ locale: Locale) async throws {
        let key = locale.identifier
        if let count = counts[key], count > 0 {
            counts[key] = count + 1
            return
        }
        // 返回 false = app 已持有该 locale 的 reservation（例如上次崩溃残留，
        // 不在我们账上）—— 两种结果都视为「从现在起由账本接管」。
        _ = try await AssetInventory.reserve(locale: locale)
        counts[key] = 1
    }

    func release(_ locale: Locale) async {
        let key = locale.identifier
        guard let count = counts[key] else { return }
        if count <= 1 {
            counts[key] = nil
            await AssetInventory.release(reservedLocale: locale)
        } else {
            counts[key] = count - 1
        }
    }
}

@available(macOS 26.0, *)
final class SpeechTranscriptionService: @unchecked Sendable {

    struct ServiceError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// 进 TranscriptCacheEntry.transcriber 的标识：换模块要让缓存失效。
    static let transcriberKind = "SpeechTranscriber"

    private let lock = NSLock()
    private var activeAnalyzer: SpeechAnalyzer?

    // MARK: 可用性

    static var isAvailable: Bool { SpeechTranscriber.isAvailable }

    static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    /// 已装模型的 locale。自动检测只探针这些（外加素材元数据指名的那一个）：
    /// 探针不该为每个候选语言触发一次模型下载。
    static func installedLocales() async -> [Locale] {
        await SpeechTranscriber.installedLocales
    }

    static func matchedLocale(for identifier: String) async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier))
    }

    // MARK: 模型安装（status(forModules:) 为准，Phase 0 实测细节见计划 3.3）

    /// 确保 locale 的语音模型可用；需要下载时汇报 Progress。
    ///
    /// 租约语义：**成功返回 = 调用方持有 reservation**，必须负责
    /// `releaseModel`（建议 defer + flag 在任何取消检查之前注册）；
    /// **抛错 = 本函数已自行释放**，调用方不欠任何清理。
    func ensureModel(
        locale: Locale, onProgress: @escaping @Sendable (Progress) -> Void
    ) async throws {
        let probe = Self.makeTranscriber(locale: locale)
        let status = await AssetInventory.status(forModules: [probe])
        guard status != .unsupported else {
            throw ServiceError(message: String(
                format: L10n("Speech transcription doesn't support “%@” on this Mac."),
                locale.identifier
            ))
        }
        // 已安装也走租约：语义必须统一（成功 = 持有一份计数），否则调用方
        // 的 release 会对上一个从没拿过的 reservation。
        try await SpeechModelLeases.shared.acquire(locale)
        if status == .installed { return }
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                onProgress(request.progress)
                try await request.downloadAndInstall()
            }
        } catch {
            // 装失败就把这份计数还回去 —— 槽位上限有限（本机 5），
            // 反复失败不能把并发语言额度漏光。
            await SpeechModelLeases.shared.release(locale)
            throw error
        }
    }

    func releaseModel(locale: Locale) async {
        await SpeechModelLeases.shared.release(locale)
    }

    // MARK: 转写

    /// 转写一个音频文件（AudioWindowReader 产出的窗口 CAF）。
    /// 返回**素材源时间**的词流：文件内时间 + sourceOffset。
    /// volatileText 只做 UI 灰字预览，绝不落任何持久层（计划 10.2）。
    func transcribe(
        fileURL: URL,
        locale: Locale,
        sourceOffset: Double,
        volatileText: (@Sendable (String) -> Void)? = nil
    ) async throws -> [TimedWord] {
        let transcriber = Self.makeTranscriber(locale: locale)
        let audioFile = try AVAudioFile(forReading: fileURL)

        let collector = Task<[TimedWord], Error> {
            var words: [TimedWord] = []
            for try await result in transcriber.results {
                guard result.isFinal else {
                    if let volatileText {
                        volatileText(String(result.text.characters))
                    }
                    continue
                }
                for run in result.text.runs {
                    let text = String(result.text[run.range].characters)
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        continue
                    }
                    guard let range = run.audioTimeRange else { continue }
                    words.append(TimedWord(
                        text: text,
                        start: CMTimeGetSeconds(range.start) + sourceOffset,
                        end: CMTimeGetSeconds(range.end) + sourceOffset,
                        confidence: run.transcriptionConfidence
                    ))
                }
            }
            return words
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        lock.lock()
        activeAnalyzer = analyzer
        lock.unlock()
        defer {
            lock.lock()
            activeAnalyzer = nil
            lock.unlock()
        }

        do {
            _ = try await analyzer.analyzeSequence(from: audioFile)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collector.cancel()
            throw error
        }
        return try await collector.value
    }

    /// 取消当前分析（cancelAndFinishNow，[SDK :224]）。幂等。
    func cancelCurrent() {
        lock.lock()
        let analyzer = activeAnalyzer
        lock.unlock()
        guard let analyzer else { return }
        Task { await analyzer.cancelAndFinishNow() }
    }

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
    }
}
