import Foundation
import SrtFlowMCPKit

// fal 任务的阶段与进度账（FalJobPhase / FalJobProgress / FalPhaseBox，docs/architecture/fal-generation.md 第十三节）：
// 阶段的名字 / 比例 / 排队位置 / 先后；同一阶段换比例不重记开始时刻、换阶段才重记；get_job 的几个字段；「1:12」「约 2 分钟」；
// 每个档位的典型时长折成的分钟数和面板上一直写的一样；同一阶段同一比例只报一次。

func runPhaseChecks() {
    // ---- 阶段
    checkEqual(FalJobPhase.uploading(fraction: 0.5).name, "uploading", "the phase name")
    checkEqual(FalJobPhase.queued(position: 3).name, "queued", "the queued phase name")
    checkEqual(FalJobPhase.uploading(fraction: 0.5).fraction, 0.5, "an upload carries its byte fraction")
    checkEqual(FalJobPhase.downloading(fraction: 0.25).fraction, 0.25, "a download carries its byte fraction")
    check(FalJobPhase.processing.fraction == nil && FalJobPhase.queued(position: 1).fraction == nil, "other phases have no fraction")
    checkEqual(FalJobPhase.queued(position: 3).queuePosition, 3, "the queue position")
    check(FalJobPhase.processing.queuePosition == nil, "only queued has a position")
    check(FalJobPhase.uploading(fraction: nil).sameStep(as: .uploading(fraction: 1)), "a different fraction is the same step")
    check(FalJobPhase.queued(position: 1).sameStep(as: .queued(position: 5)), "a different queue position is the same step")
    check(!FalJobPhase.uploading(fraction: 1).sameStep(as: .queued(position: nil)), "upload and queue are different steps")
    let inOrder: [FalJobPhase] = [.preparing, .uploading(fraction: nil), .queued(position: nil), .processing, .downloading(fraction: nil), .finishing]
    check(zip(inOrder, inOrder.dropFirst()).allSatisfy { $0.order < $1.order }, "the phases are ordered prepare < upload < queue < process < download < finish")
    checkEqual(FalJobPhase.quantized(0.456), 0.45, "fractions are quantized to 1% steps, rounding down")
    checkEqual(FalJobPhase.quantized(1.2), 1, "a fraction over 1 is clamped")
    checkEqual(FalJobPhase.quantized(-0.1), 0, "a negative fraction is clamped")

    // ---- 进度账
    let t0 = Date(timeIntervalSince1970: 1_000)
    var progress = FalJobProgress(phase: .uploading(fraction: nil), phaseStarted: t0, typicalSeconds: 140)
    progress = progress.advanced(to: .uploading(fraction: 0.5), now: t0.addingTimeInterval(10))
    checkEqual(progress.phaseStarted, t0, "a new fraction keeps the phase's start time")
    checkEqual(progress.phase, .uploading(fraction: 0.5), "but carries the new fraction")
    progress = progress.advanced(to: .queued(position: 2), now: t0.addingTimeInterval(30))
    checkEqual(progress.phaseStarted, t0.addingTimeInterval(30), "a new step restarts the phase clock")
    checkEqual(progress.phaseSeconds(now: t0.addingTimeInterval(42)), 12, "phase seconds count from the step's start")
    let queued = progress.json(now: t0.addingTimeInterval(42))
    checkEqual(queued["phase"], "queued", "get_job: phase")
    checkEqual(queued["phase_seconds"], 12, "get_job: phase_seconds")
    checkEqual(queued["queue_position"], 2, "get_job: queue_position")
    checkEqual(queued["typical_seconds"], 140, "get_job: typical_seconds")
    check(queued["transfer_percent"] == nil, "get_job: no transfer_percent while queued")
    let uploading = FalJobProgress(phase: .uploading(fraction: 0.456), phaseStarted: t0).json(now: t0)
    checkEqual(uploading["transfer_percent"], 46, "get_job: transfer_percent is a rounded percentage")
    check(uploading["queue_position"] == nil && uploading["typical_seconds"] == nil, "get_job: nothing that is not known")
    let processing = FalJobProgress(phase: .processing, phaseStarted: t0, typicalSeconds: 70).json(now: t0.addingTimeInterval(48.6))
    checkEqual(processing["phase_seconds"], 49, "get_job: phase_seconds is rounded")
    check(processing["queue_position"] == nil && processing["transfer_percent"] == nil, "get_job: processing has neither position nor percent")
    checkEqual(FalJobProgress.clock(72), "1:12", "1:12")
    checkEqual(FalJobProgress.clock(0), "0:00", "0:00")
    checkEqual(FalJobProgress.clock(3599.9), "59:59", "whole seconds, rounding down")
    checkEqual(FalJobProgress.minutes(20), 1, "under a minute still says about 1 min")
    checkEqual(FalJobProgress.minutes(150), 3, "2.5 minutes rounds up")
    checkEqual(FalJobProgress.minutes(140), 2, "2.33 minutes rounds down")

    // ---- 每个档位的典型时长（2026-10-02 实测）折成的分钟数 = 面板上一直写的「about N min」
    for (id, minutes) in [("topaz-precision", 1), ("topaz-generative", 3), ("flux-precise", 2), ("flux-creative", 3), ("bytedance-standard", 2), ("bytedance-pro", 5)] {
        guard let tier = FalUpscaleTiers.tier(id) else { check(false, "tier \(id)"); continue }
        checkEqual(FalJobProgress.minutes(tier.typicalSeconds), minutes, "\(id): the typical duration reads as about \(minutes) min")
        check(tier.typicalSeconds > 0 && tier.typicalSeconds < tier.maxSeconds, "\(id): typical is positive and under the timeout")
    }
    // generate_media 的说明说「an image takes about 10 s, a sound effect 5 s, music 30 s, a video 1–3 minutes」。
    checkEqual(FalModel.Kind.image.typicalSeconds, 10, "an image: about 10 s")
    checkEqual(FalModel.Kind.soundEffect.typicalSeconds, 5, "a sound effect: about 5 s")
    checkEqual(FalModel.Kind.music.typicalSeconds, 30, "music: about 30 s")
    check((60...180).contains(FalModel.Kind.textToVideo.typicalSeconds) && (60...180).contains(FalModel.Kind.imageToVideo.typicalSeconds), "a video: 1–3 minutes")

    // ---- 同一阶段同一比例只报一次
    let box = FalPhaseBox()
    check(box.swap(.processing), "the first report goes through")
    check(!box.swap(.processing), "the same phase again is dropped")
    check(box.swap(.downloading(fraction: nil)), "a new phase goes through")
    check(!box.swap(.downloading(fraction: nil)), "the same phase and fraction is dropped")
    check(box.swap(.downloading(fraction: 0.5)), "a new fraction goes through")
}
