import Foundation
import SrtFlowCore

// 转写完之后：按**当前**时间线把词流切成字幕、合成一条轨。2026-09-26 从 TranscriptionTask 搬出来
// （那个文件只许降），那边只留一行转交。
//
// 管什么：哪几段素材进（可听快照，去掉读不了的）、每段的词流够不够（转写期间时间线被改、新裁进了
// 没转写过的段落 → 如实报「时间线变了」，重跑只补缺口）、分段与合成（`SubtitleSegmenter`）。
// 不管什么：转写本身、任务状态、写回工程（`TranscriptionTask`）；断句和显示时间的规则（SrtFlowCore）。

@available(macOS 26.0, *)
enum SubtitleGenerationAssembly {

    enum Failure: LocalizedError {
        case noAudibleClips
        case timelineChanged
        case noSpeech

        var errorDescription: String? {
            switch self {
            case .noAudibleClips:
                return L10n("No audible clips to transcribe.")
            case .timelineChanged:
                return L10n(
                    "The timeline changed while generating. Generate again — cached transcription makes rerunning fast."
                )
            case .noSpeech:
                return L10n("No speech was recognized. Try another source language.")
            }
        }
    }

    /// 永远基于**写回时**的时间线（转写期间的裁切 / 移动 / 变速都被尊重）。
    /// - Parameters:
    ///   - entries: 这次转写的词流账本（按素材指纹）；没有的从磁盘缓存补。
    ///   - skippedFingerprints: 转写时读不了、跳过的素材。
    static func build(
        state: TimelineState,
        entries: [String: TranscriptCacheEntry],
        skippedFingerprints: Set<String>,
        localeIdentifier: String,
        config: SubtitleSegmentationConfig
    ) throws -> (document: SubtitleDocumentModel, meta: [UUID: CueMeta]) {
        let clips = SubtitleAudibleClips.soundClips(in: state)
            .filter { !skippedFingerprints.contains($0.fingerprint) }
        guard !clips.isEmpty else { throw Failure.noAudibleClips }
        var parts: [SegmentedSubtitles] = []
        var windows: [SubtitleClipWindow] = []
        for clip in clips {
            let entry = entries[clip.fingerprint] ?? TranscriptSidecarStore.load(
                fingerprint: clip.fingerprint,
                localeIdentifier: localeIdentifier,
                transcriber: SpeechTranscriptionService.transcriberKind,
                configVersion: 1
            )
            guard let entry else { throw Failure.timelineChanged }
            let desired = SourceRange(
                start: clip.sourceStart, end: clip.sourceStart + clip.sourceDuration
            )
            guard TranscriptLedger.gaps(desired: [desired], covered: entry.covered).isEmpty else {
                throw Failure.timelineChanged
            }
            let window = SubtitleClipWindow(
                clipID: clip.clipID,
                assetFingerprint: clip.fingerprint,
                sourceStart: clip.sourceStart,
                sourceEnd: clip.sourceStart + clip.sourceDuration,
                timelineStart: clip.timelineStart,
                speed: clip.speed,
                laneRank: clip.laneRank
            )
            windows.append(window)
            parts.append(SubtitleSegmenter.segment(words: entry.words, window: window, config: config))
        }
        let assembled = SubtitleSegmenter.assemble(parts, windows: windows, config: config)
        guard !assembled.document.cues.isEmpty else { throw Failure.noSpeech }
        return assembled
    }
}
