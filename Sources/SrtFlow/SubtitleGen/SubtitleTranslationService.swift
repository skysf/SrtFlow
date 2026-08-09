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
        // 配对预检（2026-08-09 案例）：目标与源同语种、或配对明确不支持时，
        // 在提交前就用能行动的文案拦下，不把系统的泛化「Unable to Translate」
        // 丢给用户。源语言未知时放行，交给系统自己识别。
        let targetLang = Locale.Language(identifier: targetLanguage)
        if let source = sourceLanguage {
            let sourceLang = Locale.Language(identifier: source)
            if TranslationPreflight.isSameTranslationLanguage(sourceLang, targetLang) {
                let message = String(
                    format: L10n("The subtitles are already in %@ — nothing to translate."),
                    TranslationPreflight.displayName(of: targetLang)
                )
                lastError = message
                return .failed(message)
            }
            if await LanguageAvailability().status(from: sourceLang, to: targetLang) == .unsupported {
                let message = String(
                    format: L10n("Translation from %1$@ to %2$@ isn't supported on this Mac."),
                    TranslationPreflight.displayName(of: sourceLang),
                    TranslationPreflight.displayName(of: targetLang)
                )
                lastError = message
                return .failed(message)
            }
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
        /// 源语言还没确定时根本查不出可用性，`status` 只是个占位的 `.supported`。
        /// 那种情况下不能对用户断言「需要下载」—— 本机已装的语言也会被这么标。
        var statusIsKnown: Bool = true
        var id: String { language.maximalIdentifier }

        var displayName: String {
            let identifier = language.minimalIdentifier
            return Locale.current.localizedString(forIdentifier: identifier) ?? identifier
        }

        var needsDownload: Bool { statusIsKnown && status == .supported }
    }

    /// 系统首选语言的名次表（语言码 → 名次，越小越靠前）。
    ///
    /// 光按「已装在前、其余字母序」排是不够的：源语言还没确定时（挂一份现成
    /// 字幕直接翻译就属于这种），下面会把全表标成 `.supported`，排序退化成纯
    /// 字母序，第一个是「阿拉伯语（阿联酋）(需要下载)」—— 它就这么成了默认的
    /// 目标语言，用户点一下 Translate All 就在下载阿拉伯语模型。而这个面板最
    /// 常见的用法恰恰是把外语字幕翻成自己的语言，所以再兜一层系统首选语言。
    private static var preferredLanguageRanks: [String: Int] {
        var ranks: [String: Int] = [:]
        for (index, identifier) in Locale.preferredLanguages.enumerated() {
            guard let code = Locale(identifier: identifier).language.languageCode?.identifier
            else { continue }
            if ranks[code] == nil { ranks[code] = index }
        }
        return ranks
    }

    /// 目标语言候选：按「已装 → 系统首选 → 字母序」排；unsupported 不出现。
    func targetLanguages(from source: String?) async -> [TargetLanguage] {
        let availability = LanguageAvailability()
        let sourceLanguage = source.map(Locale.Language.init(identifier:))
        var result: [TargetLanguage] = []
        for language in await availability.supportedLanguages {
            let status = await availability.status(from: sourceLanguage ?? language, to: language)
            if sourceLanguage == nil {
                // 没有源语言时只列全量支持语言（状态占位，选定源语言后再精确）。
                result.append(
                    TargetLanguage(language: language, status: .supported, statusIsKnown: false)
                )
            } else if status != .unsupported {
                result.append(TargetLanguage(language: language, status: status))
            }
        }
        let ranks = Self.preferredLanguageRanks
        func preferredRank(_ target: TargetLanguage) -> Int {
            target.language.languageCode.flatMap { ranks[$0.identifier] } ?? Int.max
        }
        return result.sorted {
            if ($0.status == .installed) != ($1.status == .installed) {
                return $0.status == .installed
            }
            if preferredRank($0) != preferredRank($1) {
                return preferredRank($0) < preferredRank($1)
            }
            return $0.displayName < $1.displayName
        }
    }
}
