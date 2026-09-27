#!/usr/bin/env bash
# AI 接口（MCP）的自检：
#   1. 小程序 srtflow-mcp 说的 MCP 对不对 —— 真的起它，老一代（先 initialize）和新一代（2026-07-28，
#      每个请求自带 _meta 版本）两种客户端都喂一遍，旁边一个假 App 在临时 socket 上接工具调用；
#   2. App 里 AI 改时间线的纯值规则（放素材、推 V1、ripple 删、切、转场、改一段、短 id、get_timeline）；
#   3. 客户端配置文件的增删（Claude 的 JSON、Codex 的 TOML）、文字 / 颜色参数、字幕批量改；
#   4. 小程序那份选项词表和 App 里的类型逐项对账（小程序不链接 App 的代码，词表是抄的）；
#   5. 打包脚本把小程序装进了 Contents/Helpers，并且先签它、再签外层；
#   6. AI 的每个改动各是一步撤销：改工程的工具都包在 AIUndoGrouping.step 里（扫描），显式分组确实把两步分开、
#      而且之后按事件的普通登记不会抛异常（用真的 UndoManager）。
#
# 用法：
#   scripts/check-mcp.sh
#
# 与 check-timeline-clipboard.sh 同一套编法：被测代码在 SrtFlow app target 里，SwiftPM 不允许两个
# target 共用源文件，所以挑纯值文件单独编成自检二进制。长期约束见 docs/architecture/ai-control-mcp.md。
set -euo pipefail
cd "$(dirname "$0")/.."

# Rosetta 终端下必须显式指定 arm64，否则会去编 x86_64（见 docs/build/）。
ARCH_FLAG="--arch arm64"
TRIPLE="arm64-apple-macosx15.0"

echo "==> 打包脚本：小程序进 Helpers、先签它再签外层"
BUILD_SCRIPT="scripts/build-app.sh"
COPY_LINE="$(grep -n 'cp "$BUILD_DIR/srtflow-mcp" "$APP/Contents/Helpers/srtflow-mcp"' "${BUILD_SCRIPT}" | cut -d: -f1 || true)"
SIGN_HELPER="$(grep -n 'codesign --force --sign - --timestamp=none "$APP/Contents/Helpers/srtflow-mcp"' "${BUILD_SCRIPT}" | cut -d: -f1 || true)"
SIGN_APP="$(grep -n 'codesign --force --sign - "$APP"$' "${BUILD_SCRIPT}" | cut -d: -f1 || true)"
if [ -z "${COPY_LINE}" ] || [ -z "${SIGN_HELPER}" ] || [ -z "${SIGN_APP}" ]; then
  echo "✗ ${BUILD_SCRIPT} 没把 srtflow-mcp 拷进 Contents/Helpers 或没签它：AI 客户端配置里写的那个路径会不存在" >&2
  exit 1
fi
if [ "${SIGN_HELPER}" -gt "${SIGN_APP}" ]; then
  echo "✗ ${BUILD_SCRIPT} 先签了外层再签 srtflow-mcp：嵌套的可执行文件必须先签，否则外层签名立即失效" >&2
  exit 1
fi
echo "   ✓ 第 ${COPY_LINE} 行拷进去、第 ${SIGN_HELPER} 行签、第 ${SIGN_APP} 行才签外层"

echo "==> 路由：改工程的工具各是一步撤销"
# 不显式分组的话 AI 的每一步都堆进同一组，⌘Z 一按全部退光；手动关自动开的那一组又会让下一次登记
# 抛异常、App 闪退（docs/bugfixes/2026-09-27-ai-edits-share-one-undo-group.md）。
ROUTER="Sources/SrtFlow/AIToolRouter.swift"
for tool in editClip splitClip deleteItems setTransition setText setFilter setCanvas editSubtitles; do
  if [ "$(grep -cE "case \\.${tool}: return try AIUndoGrouping\\.step\\(undo\\)" "${ROUTER}" || true)" -ne 1 ]; then
    echo "✗ ${ROUTER} 里 ${tool} 没包在 AIUndoGrouping.step 里：它的改动会和别的步并成一步撤销" >&2
    exit 1
  fi
done
if [ "$(grep -cE 'AIUndoGrouping\.step\(project\.effectiveUndoManager\)' Sources/SrtFlow/AITimelineTools.swift || true)" -ne 1 ]; then
  echo "✗ add_clips 那一次 perform 没包在 AIUndoGrouping.step 里" >&2
  exit 1
fi
MANUAL="$(grep -lE 'endUndoGrouping\(\)' Sources/SrtFlow/AI*.swift | grep -v 'AIUndoGrouping.swift' || true)"
if [ -n "${MANUAL}" ]; then
  echo "✗ 这些文件自己在关撤销组：${MANUAL}（手动关掉按事件自动开的那一组，下一次登记就抛异常、App 闪退）" >&2
  exit 1
fi
echo "   ✓ 8 个同步的改动工具 + add_clips 都各是一步，没人手动关撤销组"

echo "==> swift build ${ARCH_FLAG}（小程序 + SrtFlowCore）"
# SwiftPM 的编译诊断走 stdout：静默成功可以，失败必须倾倒完整输出。
BUILD_OUT="$(swift build ${ARCH_FLAG} --product srtflow-mcp 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_OUT="$(swift build ${ARCH_FLAG} --target SrtFlowCore 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_DIR="$(swift build ${ARCH_FLAG} --show-bin-path)"

OUT="$(mktemp -d)/mcpcheck"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

echo "==> 编译自检二进制"
xcrun swiftc \
  -target "$TRIPLE" \
  -wmo \
  -I "$BUILD_DIR/Modules" \
  -o "$OUT" \
  Sources/SrtFlow/VideoEditModels.swift \
  Sources/SrtFlow/VideoEditClipCrop.swift \
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
  Sources/SrtFlow/VideoEditSubtitleDocuments.swift \
  Sources/SrtFlow/VideoEditTimelineSnap.swift \
  Sources/SrtFlow/VideoEditTimelineTrim.swift \
  Sources/SrtFlow/VideoEditMediaImport.swift \
  Sources/SrtFlow/VideoEditFormatVersion.swift \
  Sources/SrtFlow/MediaProbe.swift \
  Sources/SrtFlow/AppLanguage.swift \
  Sources/SrtFlow/AIToolIO.swift \
  Sources/SrtFlow/AIShortIDs.swift \
  Sources/SrtFlow/AITimelineSummary.swift \
  Sources/SrtFlow/AITextEdits.swift \
  Sources/SrtFlow/AITimelineEdits.swift \
  Sources/SrtFlow/AIClipEdit.swift \
  Sources/SrtFlow/AISubtitleEdits.swift \
  Sources/SrtFlow/AIClientConfigFiles.swift \
  Sources/SrtFlow/AIUndoGrouping.swift \
  checks/MCP/main.swift \
  checks/MCP/Harness.swift \
  checks/MCP/ProtocolChecks.swift \
  checks/MCP/TimelineChecks.swift \
  checks/MCP/ConfigChecks.swift \
  checks/MCP/UndoChecks.swift \
  "$BUILD_DIR"/SrtFlowCore.build/*.o \
  "$BUILD_DIR"/SrtFlowMCPKit.build/*.o

echo "==> 运行"
SRTFLOW_MCP_HELPER="$BUILD_DIR/srtflow-mcp" "$OUT"
