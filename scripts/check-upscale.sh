#!/usr/bin/env bash
# **视频 upscale 任务的自检**（docs/architecture/video-upscale.md）：
#   1. 范围：三选一（这一段 / 工程里最长的那处 / 整个文件）、两头各留 1 秒余料、对齐到整帧、夹在文件里、谁被盖住、「另一处更长」的提示；
#   2. 起名落盘：`<原名>_<宽x高>_<档位>.mp4`、撞名加编号（ExportFileName.unoccupied）、原片的文件夹写不进去退到工程的家 / 下载；
#   3. 封回原声的 ffmpeg 参数：精确裁原片的声音、画面流复制、HEVC 点名 hvc1；
#   4. 真裁一段（AVAssetReader → AVAssetWriter，MediaReadQueue.export）：帧数 / 时长 / 尺寸对、首帧是原片那一刻的画面、没有声音、能取消；
#   5. 整条流水线对着假 fal（FalStub）走一遍：裁 → 上传（initiate + PUT）→ 提交 → 排队 / 处理 → 下载 → 封回原声（真跑 ffmpeg）→ 探测 → 落盘，
#      整个 mp4 直接上传、超过模型上限还是裁、取消替 fal 也取消且不留文件、fal 拒绝就没有文件。
#
# 素材：AVAssetWriter 现写的渐变灰视频（画面）；带声音的原片用 ffmpeg 现造（SRTFLOW_FFMPEG，默认 vendor/ffmpeg）。
# 不碰真的网络、不花钱。
#
# 用法：
#   scripts/check-upscale.sh
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH_FLAG="--arch arm64"
TRIPLE="arm64-apple-macosx15.0"

echo "==> swift build ${ARCH_FLAG} --target SrtFlowCore --target SrtFlowMCPKit"
BUILD_OUT="$(swift build ${ARCH_FLAG} --target SrtFlowCore --target SrtFlowMCPKit 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_DIR="$(swift build ${ARCH_FLAG} --show-bin-path)"

OUT="$(mktemp -d)/upscalecheck"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

echo "==> 编译自检二进制"
# 清单是手抄的（scripts/check-project-file.sh 开头讲了为什么），由 checks/check-script-source-lists.sh 守着。
xcrun swiftc \
  -target "$TRIPLE" \
  -wmo \
  -I "$BUILD_DIR/Modules" \
  -o "$OUT" \
  Sources/SrtFlow/AppLanguage.swift \
  Sources/SrtFlow/PerfCounters.swift \
  Sources/SrtFlow/MediaProbe.swift \
  Sources/SrtFlow/MediaReadQueue.swift \
  Sources/SrtFlow/FFmpegProcess.swift \
  Sources/SrtFlow/Quarantine.swift \
  Sources/SrtFlow/OptimizedMedia/MediaKeyframeProbe.swift \
  Sources/SrtFlow/Fal/FalClient.swift \
  Sources/SrtFlow/Fal/FalModels.swift \
  Sources/SrtFlow/Fal/FalInputs.swift \
  Sources/SrtFlow/Fal/FalOutputs.swift \
  Sources/SrtFlow/Fal/FalUpscaleModels.swift \
  Sources/SrtFlow/Fal/FalBilling.swift \
  Sources/SrtFlow/VideoEditClipUpscaleRecord.swift \
  Sources/SrtFlow/Upscale/UpscaleRange.swift \
  Sources/SrtFlow/Upscale/UpscaleOutputName.swift \
  Sources/SrtFlow/Upscale/UpscaleAudioMux.swift \
  Sources/SrtFlow/Upscale/UpscaleSourceTrimmer.swift \
  Sources/SrtFlow/Upscale/UpscalePipeline.swift \
  checks/Upscale/main.swift \
  checks/OptimizedMedia/RampVideo.swift \
  checks/Fal/FalStub.swift \
  "$BUILD_DIR"/SrtFlowCore.build/*.o \
  "$BUILD_DIR"/SrtFlowMCPKit.build/*.o

echo "==> 运行"
SRTFLOW_FFMPEG="${SRTFLOW_FFMPEG:-$(pwd)/vendor/ffmpeg}" "$OUT"
