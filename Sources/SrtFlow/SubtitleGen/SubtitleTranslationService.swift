import Foundation
import Translation
import SrtFlowCore

// 字幕翻译服务（macOS 15+）：把原文轨的 cue 文本按句喂给 Translation Host，
// 译文回写 companion（同 ID、同时间，硬约束）。三档重译（计划 8.7）：
// 全部 / 只翻过期或缺译 / 指定选区。

@available(macOS 15.0, *)
@MainActor
final class SubtitleTranslationService: ObservableObject {
    static let shared = SubtitleTranslationService()

    enum Scope: Equatable {
        /// 全部 cue 重译。
        case all
        /// 只翻 stale 或还没有译文的。
        case staleOrMissing
        /// 显式选中的。
        case cues(Set<UUID>)
    }

    /// 一次翻译的明确结局 —— 取消/失败不得伪装成成功（调用方据此定 UI）。
    enum Outcome: Equatable {
        case translated(Int)
        case nothingToDo
        case cancelled
        /// 翻译期间工程被切走或原文全变了，结果整体作废。
        case discarded
        case failed(String)
    }

    @Published var lastError: String?

    var coordinator: TranslationJobCoordinator { .shared }
    var isBusy: Bool { coordinator.isBusy }

    /// 翻译当前字幕轨。成功后一次 perform 回写（一步撤销）。
    ///
    /// 异步守卫（评审 P1）：请求前快照 documentGeneration 与每条原文文本；
    /// 返回后工程已切走 → 整体丢弃；单条原文已被改 → 该条丢弃（保持 stale，
    /// 由「Translate Missing & Stale」再补）。旧结果永不污染新状态。
    @discardableResult
    func translateCurrentSubtitle(
        project: VideoEditProject,
        scope: Scope,
        sourceLanguage: String?,
        targetLanguage: String
    ) async -> Outcome {
        lastError = nil
        guard let original = project.state.subtitle, !original.cues.isEmpty else {
            return .nothingToDo
        }
        let companion = project.state.subtitleCompanion
        let translatedIDs = Set((companion?.translation?.cues ?? []).map(\.id))
        let generation = project.documentGeneration

        let targets = original.cues.filter { cue in
            guard !SubtitleSerializer.plainText(cue.text).isEmpty else { return false }
            switch scope {
            case .all:
                return true
            case .staleOrMissing:
                let stale = companion?.cueMeta[cue.id]?.translationStale ?? false
                return stale || !translatedIDs.contains(cue.id)
            case .cues(let ids):
                return ids.contains(cue.id)
            }
        }
        guard !targets.isEmpty else { return .nothingToDo }
        let snapshot: [UUID: String] = Dictionary(
            uniqueKeysWithValues: targets.map { ($0.id, $0.text) }
        )

        let requests = targets.map {
            TranslationJobCoordinator.CueRequest(
                cueID: $0.id,
                text: SubtitleSerializer.plainText($0.text)
            )
        }
        do {
            let results = try await coordinator.translate(
                requests,
                source: sourceLanguage.map(Locale.Language.init(identifier:)),
                target: Locale.Language(identifier: targetLanguage)
            )
            guard project.isCurrentGeneration(generation) else { return .discarded }
            let currentTexts: [UUID: String] = Dictionary(
                uniqueKeysWithValues: (project.state.subtitle?.cues ?? []).map { ($0.id, $0.text) }
            )
            let valid = results.filter { id, _ in currentTexts[id] == snapshot[id] }
            guard !valid.isEmpty else {
                return results.isEmpty ? .nothingToDo : .discarded
            }
            project.applyTranslations(
                valid,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            )
            return .translated(valid.count)
        } catch is CancellationError {
            return .cancelled
        } catch {
            let message = TranslationErrorText.describe(error)
            lastError = message
            return .failed(message)
        }
    }

    // MARK: 语言查询（UI 列表全部来自运行时，计划 3.2）

    struct TargetLanguage: Identifiable, Hashable {
        var language: Locale.Language
        var status: LanguageAvailability.Status
        var id: String { language.maximalIdentifier }

        var displayName: String {
            let identifier = language.minimalIdentifier
            return Locale.current.localizedString(forIdentifier: identifier) ?? identifier
        }

        var needsDownload: Bool { status == .supported }
    }

    /// 目标语言候选：按「已装在前、可下载在后」排；unsupported 不出现。
    func targetLanguages(from source: String?) async -> [TargetLanguage] {
        let availability = LanguageAvailability()
        let sourceLanguage = source.map(Locale.Language.init(identifier:))
        var result: [TargetLanguage] = []
        for language in await availability.supportedLanguages {
            let status = await availability.status(from: sourceLanguage ?? language, to: language)
            if sourceLanguage == nil {
                // 没有源语言时只列全量支持语言（状态标成 supported，选定源语言后再精确）。
                result.append(TargetLanguage(language: language, status: .supported))
            } else if status != .unsupported {
                result.append(TargetLanguage(language: language, status: status))
            }
        }
        return result.sorted {
            if ($0.status == .installed) != ($1.status == .installed) {
                return $0.status == .installed
            }
            return $0.displayName < $1.displayName
        }
    }
}
