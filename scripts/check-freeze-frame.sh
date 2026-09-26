#!/usr/bin/env bash
# 定格（Freeze Frame）时间线变换的自检：分割 + 同轨让位 + 音轨不联动 +
# 叠化区判定 + 关键帧烘焙。
#
# 用法：
#   scripts/check-freeze-frame.sh
#
# 与 check-project-file.sh 同一套编法：被测代码在 SrtFlow app target 里，
# SwiftPM 不允许两个 target 共用源文件，所以单独编成自检二进制来跑。
# 能这么编的前提是定格的状态变换都是纯值函数、单独放在
# Sources/SrtFlow/VideoEditTimelineEdits.swift —— 别把它们挪回
# VideoEditProject.swift，那个文件拖着 AppKit/SwiftUI/AVFoundation 整个 App。
set -euo pipefail
cd "$(dirname "$0")/.."

# Rosetta 终端下必须显式指定 arm64，否则会去编 x86_64（见 docs/build/）。
ARCH_FLAG="--arch arm64"
TRIPLE="arm64-apple-macosx15.0"

# ── 准入条件的扫描守卫（2026-09-20）─────────────────────────────────────
# 定格的主轨准入条件是**一条**：播放头不在叠化区里。两件事要钉住：
#   1. 叠化区那条必须留着 —— 那一帧是两段合成的，从单个源素材抽帧必然对不上；
#   2. 「牵扯转场的段一律禁用」已经放开（用户拍板，对齐剪映：只禁转场那一段，
#      不禁整个片段），别无意中加回来。
# 只看真代码行：注释里提到函数名不算接上了。
ELIGIBLE_BODY="$(awk '/func isFreezeEligible/{inside=1} inside{print} inside&&/^    \}$/{exit}' \
  Sources/SrtFlow/VideoEditFreezeFrame.swift | grep -vE '^[[:space:]]*//')"
if [ -z "${ELIGIBLE_BODY}" ]; then
    echo "✗ 找不到 isFreezeEligible，准入条件的守卫失去目标 —— 改名了就同步改这里" >&2
    exit 1
fi
grep -q 'isInsideMainTransition' <<<"${ELIGIBLE_BODY}" || {
    echo "✗ isFreezeEligible 不再检查 isInsideMainTransition：叠化区里那一帧是两段合成的，必须禁定格" >&2
    exit 1
}
grep -q 'participatesInMainTransition' <<<"${ELIGIBLE_BODY}" && {
    echo "✗ isFreezeEligible 又开始用 participatesInMainTransition 了：整段禁用已于 2026-09-20 放开（只禁转场那一段），见 docs/architecture/freeze-frame.md §4a" >&2
    exit 1
}
echo "✓ 定格准入条件：只禁叠化区，不禁整段"

echo "==> swift build ${ARCH_FLAG} --target SrtFlowCore（拿 SrtFlowCore 的模块和目标文件）"
# SwiftPM 的编译诊断走 stdout：静默成功可以，失败必须倾倒完整输出
#（>/dev/null 会把编译错误吞成无字天书，见 docs/bugfixes/ 2026-08-08 CI 首跑案例）。
BUILD_OUT="$(swift build ${ARCH_FLAG} --target SrtFlowCore 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_DIR="$(swift build ${ARCH_FLAG} --show-bin-path)"

OUT="$(mktemp -d)/freezecheck"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

echo "==> 编译自检二进制"
xcrun swiftc \
  -target "$TRIPLE" \
  -wmo \
  -I "$BUILD_DIR/Modules" \
  -o "$OUT" \
  Sources/SrtFlow/VideoEditModels.swift \
  Sources/SrtFlow/VideoEditShapeModels.swift \
  Sources/SrtFlow/VideoEditSoundScene.swift \
  Sources/SrtFlow/PerfCounters.swift \
  Sources/SrtFlow/VideoEditVolumeCurve.swift \
  Sources/SrtFlow/VideoEditFilterModels.swift \
  Sources/SrtFlow/VideoEditClipVisibility.swift \
  Sources/SrtFlow/VideoEditTransitionHandles.swift \
  Sources/SrtFlow/VideoEditFadeWindow.swift \
  Sources/SrtFlow/VideoEditAudioFade.swift \
  Sources/SrtFlow/VideoEditVideoFade.swift \
  Sources/SrtFlow/VideoEditClipAnimation.swift \
  Sources/SrtFlow/VideoEditClipAnimator.swift \
  Sources/SrtFlow/VideoEditTrackPalette.swift \
  Sources/SrtFlow/VideoEditTextStyle.swift \
  Sources/SrtFlow/VideoEditTextEasing.swift \
  Sources/SrtFlow/VideoEditTextAnimation.swift \
  Sources/SrtFlow/VideoEditTextAnimator.swift \
  Sources/SrtFlow/VideoEditTextNumber.swift \
  Sources/SrtFlow/VideoEditTextOdometer.swift \
  Sources/SrtFlow/VideoEditTextNumberRenderer.swift \
  Sources/SrtFlow/VideoEditTextModels.swift \
  Sources/SrtFlow/VideoEditTextRows.swift \
  Sources/SrtFlow/VideoEditTextLayout.swift \
  Sources/SrtFlow/VideoEditTextRenderer.swift \
  Sources/SrtFlow/VideoEditTextDrawing.swift \
  Sources/SrtFlow/VideoEditTextExport.swift \
  Sources/SrtFlow/VideoEditClipMarker.swift \
  Sources/SrtFlow/VideoEditAnimation.swift \
  Sources/SrtFlow/VideoEditTimelineEdits.swift \
  Sources/SrtFlow/VideoEditTimelineSnap.swift \
  Sources/SrtFlow/VideoEditFormatVersion.swift \
  Sources/SrtFlow/MediaProbe.swift \
  Sources/SrtFlow/AppLanguage.swift \
  checks/FreezeFrame/main.swift \
  "$BUILD_DIR"/SrtFlowCore.build/*.o

echo "==> 运行"
"$OUT"
