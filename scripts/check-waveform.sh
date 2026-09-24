#!/usr/bin/env bash
# 波形数据（多级峰值）的真实回归：ffmpeg 现造每个采样都算得出来的素材，走生产的
# WaveformStore → WaveformDecoder → ChunkBuilder 读一遍，逐项对账。
#
# 用法：
#   scripts/check-waveform.sh
#
# 需要 ffmpeg（造素材）。与 check-project-file.sh 同一套编法：被测代码在 SrtFlow
# app target 里，SwiftPM 不允许两个 target 共用源文件，所以单独编成自检二进制来跑。
set -euo pipefail
cd "$(dirname "$0")/.."

# Rosetta 终端下必须显式指定 arm64，否则会去编 x86_64（见 docs/build/）。
ARCH_FLAG="--arch arm64"
TRIPLE="arm64-apple-macosx15.0"

FFMPEG_BIN="${SRTFLOW_FFMPEG:-$(pwd)/vendor/ffmpeg}"
if [ ! -x "${FFMPEG_BIN}" ]; then
  echo "✗ 找不到可执行的 ffmpeg：${FFMPEG_BIN}" >&2
  echo "  先运行 scripts/vendor-ffmpeg.sh，或用 SRTFLOW_FFMPEG= 指定一份。" >&2
  exit 1
fi

echo "==> swift build ${ARCH_FLAG}（拿 SrtFlowCore 的模块）"
# SwiftPM 的编译诊断走 stdout：静默成功可以，失败必须倾倒完整输出
#（>/dev/null 会把编译错误吞成无字天书，见 docs/bugfixes/ 2026-08-08 CI 首跑案例）。
BUILD_OUT="$(swift build ${ARCH_FLAG} 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }

OUT="$(mktemp -d)/waveformcheck"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

echo "==> 编译自检二进制"
xcrun swiftc \
  -target "$TRIPLE" \
  -o "$OUT" \
  Sources/SrtFlow/MediaReadQueue.swift \
  Sources/SrtFlow/VideoEditWaveformData.swift \
  Sources/SrtFlow/VideoEditWaveformDetail.swift \
  checks/Waveform/main.swift

echo "==> 运行"
SRTFLOW_FFMPEG="${FFMPEG_BIN}" "$OUT"
