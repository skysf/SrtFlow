#!/usr/bin/env bash
# 扫描守卫：Video Edit 的生产管线里不许再出现写死的帧率。
#
# 由来：工程帧率（24/30/60）落地前，`VideoEditExporter` 有 **9 处** `fps=30` / `r=30`、
# `VideoEditCompositionBuilder` 有 1 处 `frameDuration = CMTime(1, 30)`、
# `KeyframeTrack.timeTolerance` 写死 `1/60`（其实是「30fps 的半帧」），各写各的。
# 改帧率必须全部一起动，漏一处就是「预览 24、导出 30」—— 只在成片里才看得出来。
# 计划 §17.3 要求加这条守卫。
#
# 扫描范围**只含 Video Edit 管线**：视频压缩那条线（`FFmpegArgumentBuilder`）
# 的帧率是用户在编码设置里选的上限，与工程帧率无关，不归这条守卫管。
set -euo pipefail
cd "$(dirname "$0")/.."

# **不要用 `git ls-files`**：新写的文件往往还没 add，会被静默跳过 ——
# 实测 `ProjectFrameRate.swift` 未跟踪期间，守卫根本没扫过它却报「通过」。
# 用文件系统枚举，未跟踪的文件也在保护范围内。
list_files() {
    for pattern in "$@"; do
        # shellcheck disable=SC2086
        ls -1 $pattern 2>/dev/null || true
    done
}

# Swift 生产代码：滤镜指令与合成参数都要扫。
# 录屏相关文件（ScreenRecording*.swift）同样纳入 —— 它们会配置捕获帧率。
SWIFT_FILES=$(list_files \
    'Sources/SrtFlow/VideoEdit*.swift' \
    'Sources/SrtFlow/ScreenRecording*.swift' \
    'Sources/SrtFlowCore/ProjectFrameRate.swift' \
    'Sources/SrtFlowCore/ScreenRecording*.swift')

# alpha fixture 脚本：它的三档循环**无法**因帧率写错而失败（只取第一帧，
# alpha 是逐帧数学），所以「滤镜里不许写死帧率」只能靠这里守。
# 但**只扫 `fps=`**：脚本里的 `-i color=...:r=10` 是 lavfi **输入素材**的帧率，
# 是 fixture 自己的构造参数，与被测滤镜链无关，扫它是误报。
ALPHA_FILES=$(list_files 'scripts/check-export-alpha-compositing.sh')

fail=0

# 去掉注释行再扫：文档里写「以前是 fps=30」是必要的说明，不是违规。
scan() {
    local pattern="$1" label="$2" files="$3" hits=""
    for f in $files; do
        local found
        found=$(grep -n "$pattern" "$f" 2>/dev/null \
            | grep -v ':[[:space:]]*//' \
            | grep -v ':[[:space:]]*\*' \
            | grep -v ':[[:space:]]*#' || true)
        [ -n "$found" ] && hits="$hits\n$(echo "$found" | sed "s|^|    $f:|")"
    done
    if [ -n "$hits" ]; then
        echo "✗ $label"
        printf "%b\n" "$hits"
        fail=1
    fi
}

echo "==> 扫描 Video Edit 管线里写死的帧率"
scan 'fps=[0-9]'                                    "ffmpeg 滤镜里写死了 fps=" "$SWIFT_FILES"
scan ':r=[0-9]'                                     "ffmpeg 滤镜里写死了 r="   "$SWIFT_FILES"
scan 'frameDuration = CMTime(value: 1, timescale: [0-9]' "写死了 frameDuration" "$SWIFT_FILES"
scan 'timeTolerance *= *[0-9]'                      "写死了关键帧容差"          "$SWIFT_FILES"
# 录屏实现会用到的两类帧率入口（进入 Phase 3 前补上，复审点名的盲区）：
# SCStreamConfiguration.minimumFrameInterval 的字面量 timescale、
# AVAssetWriter 视频设置里的 AVVideoExpectedSourceFrameRateKey 字面量。
scan 'minimumFrameInterval *= *CMTime(value: 1, timescale: [0-9]' "写死了 minimumFrameInterval" "$SWIFT_FILES"
scan 'AVVideoExpectedSourceFrameRateKey[^,]*: *[0-9]'   "写死了 AVVideoExpectedSourceFrameRateKey" "$SWIFT_FILES"

echo "==> 扫描 alpha fixture 的滤镜串（只看 fps=，不看 lavfi 输入的 :r=）"
scan 'fps=[0-9]'                                    "alpha fixture 滤镜里写死了 fps=" "$ALPHA_FILES"

if [ "$fail" -eq 0 ]; then
    echo "✓ 没有写死的帧率"
    echo "All checks passed"
else
    echo
    echo "帧率必须来自 TimelineState.frameRate（ProjectFrameRate）。"
    exit 1
fi
