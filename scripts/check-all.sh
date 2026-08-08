#!/usr/bin/env bash
# 全部自检的聚合入口：一条命令跑完 SrtFlowCoreChecks + 所有 check 脚本 + 扫描守卫。
# 任何一项红 → 整体退出码非 0；单项失败不中断，一次跑完看全貌。
#
# 改完代码、发 PR 前跑它；CI 在每个 PR 上也跑同一条命令
# （.github/workflows/checks.yml）。GUI 冒烟（真窗口）自动化够不着，
# 不在此列 —— 见 docs/testing/gui-smoke-testing.md。
#
# 用法：
#   scripts/check-all.sh
#   SRTFLOW_FFMPEG=/path/to/ffmpeg scripts/check-all.sh   # 用别处的 ffmpeg
set -euo pipefail
cd "$(dirname "$0")/.."

# 需要真跑 ffmpeg 的自检**不允许静默跳过**（跳过 = 假绿），没有就明确失败。
FFMPEG_BIN="${SRTFLOW_FFMPEG:-$(pwd)/vendor/ffmpeg}"
if [ ! -x "${FFMPEG_BIN}" ]; then
  echo "✗ 找不到可执行的 ffmpeg：${FFMPEG_BIN}" >&2
  echo "  先运行 scripts/vendor-ffmpeg.sh，或用 SRTFLOW_FFMPEG= 指定一份。" >&2
  exit 1
fi
export SRTFLOW_FFMPEG="${FFMPEG_BIN}"

PASS=0
FAIL=0
FAILED_NAMES=""

run_check() {
  local name="$1"
  shift
  echo ""
  echo "━━━ ${name} ━━━"
  local started ended
  started="$(date +%s)"
  if "$@"; then
    ended="$(date +%s)"
    echo "✓ ${name}（$((ended - started))s）"
    PASS=$((PASS + 1))
  else
    ended="$(date +%s)"
    echo "✗ ${name} 失败（$((ended - started))s）" >&2
    FAIL=$((FAIL + 1))
    FAILED_NAMES="${FAILED_NAMES} ${name}"
  fi
}

# 快的在前：纯值检查和扫描守卫先给反馈，真跑 ffmpeg 的殿后。
# Rosetta 终端下必须显式 --arch arm64（见 docs/build/），各子脚本已各自处理。
run_check "SrtFlowCoreChecks（核心库）" swift run --arch arm64 SrtFlowCoreChecks
run_check "no-hardcoded-fps（扫描守卫）" checks/no-hardcoded-fps.sh
run_check "freeze-frame（定格时间线变换）" scripts/check-freeze-frame.sh
run_check "player-clock（悬停 peek 状态机）" scripts/check-player-clock.sh
run_check "project-file（工程存盘/重链接）" scripts/check-project-file.sh
run_check "preview-composition（预览合成真取帧）" scripts/check-preview-composition.sh
run_check "export-frame-rate（生产导出滤镜帧率）" scripts/check-export-frame-rate.sh
run_check "export-alpha-compositing（画中画 fill+matte）" scripts/check-export-alpha-compositing.sh
run_check "still-clip-encode（静帧真实产物）" scripts/check-still-clip-encode.sh

echo ""
echo "════════════════════════════════════════"
echo "通过 ${PASS} 项，失败 ${FAIL} 项"
if [ "${FAIL}" -gt 0 ]; then
  echo "失败的：${FAILED_NAMES}" >&2
  exit 1
fi
echo "All checks passed"
