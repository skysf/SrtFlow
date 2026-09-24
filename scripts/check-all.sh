#!/usr/bin/env bash
# 全部自检的聚合入口：一条命令跑完 SrtFlowCoreChecks + 所有 check 脚本 + 扫描守卫。
# 任何一项红 → 整体退出码非 0；单项失败不中断，一次跑完看全貌。
#
# 改完代码、发 PR 前跑它；CI 在每个 PR 上也跑同一个脚本
# （.github/workflows/checks.yml），只是按下面的 `shard` 分成几组，分到几台 runner 上
# 并行跑（仓库是公开的，macOS runner 免费；分组的理由和实测见
# docs/build/build-and-packaging.md「CI」一节）。GUI 冒烟（真窗口）自动化够不着，
# 不在此列 —— 见 docs/testing/gui-smoke-testing.md。
#
# 用法：
#   scripts/check-all.sh                     # 全部（本地就这么跑）
#   scripts/check-all.sh --shard 2 --of 5    # 只跑第 2 组（CI 用；--of 必须等于下面声明的组数）
#   SRTFLOW_FFMPEG=/path/to/ffmpeg scripts/check-all.sh   # 用别处的 ffmpeg
set -euo pipefail
# 下面要回头读本文件里声明的分组；先记下绝对路径（cd 之后相对的 $0 可能就不对了）。
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/.."

SHARD=""
SHARD_TOTAL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --shard) SHARD="${2:-}"; shift 2 ;;
    --of) SHARD_TOTAL="${2:-}"; shift 2 ;;
    *) echo "✗ 不认识的参数：$1（用法见文件开头）" >&2; exit 2 ;;
  esac
done

# 分组数必须和 CI 的 matrix 一致：这里多声明了一组、CI 没跟上，那一组的检查在 CI 上就
# 一次都不跑 —— 而且是绿的。所以 CI 传进来的组数（--of）和本文件声明的组对不上就直接红。
if [ -n "${SHARD}${SHARD_TOTAL}" ]; then
  # grep 一行都没匹配到时退出码是 1，pipefail 会让这条赋值直接把脚本静默杀掉，所以兜 || true。
  DECLARED="$({ grep -E '^shard [0-9]+$' "${SELF}" || true; } | awk '{ print $2 }' | LC_ALL=C sort -n | tr '\n' ' ')"
  EXPECTED="$(seq 1 "${SHARD_TOTAL:-0}" | tr '\n' ' ')"
  if [ -z "${SHARD}" ] || [ -z "${SHARD_TOTAL}" ] || [ "${DECLARED}" != "${EXPECTED}" ] \
    || [ "${SHARD}" -lt 1 ] || [ "${SHARD}" -gt "${SHARD_TOTAL}" ]; then
    echo "✗ 分组对不上：要跑第 ${SHARD:-?} 组（共 ${SHARD_TOTAL:-?} 组），本文件声明的组是 ${DECLARED:-（没有）}。" >&2
    echo "  改了分组就同步改 .github/workflows/checks.yml 的 matrix（反之亦然）。" >&2
    exit 1
  fi
fi

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
CURRENT_SHARD=1

# 下面的检查归第几组（只在 CI 用 --shard 时起作用；本地全跑）。
shard() {
  CURRENT_SHARD="$1"
}

run_check() {
  local name="$1"
  shift
  if [ -n "${SHARD}" ] && [ "${CURRENT_SHARD}" != "${SHARD}" ]; then return 0; fi
  # shell 写的检查一律交给 macOS 自带的 /bin/bash（3.2）跑：CI 上 `env bash` 找到的就是它，
  # 本机 PATH 上常常是 Homebrew 的 5.x。两个版本的解析宽严不一样，只在本机跑 5.x 就会
  # 「本机全绿、CI 当场红」（2026-09-23 blocking-media-reads 首跑，见
  # docs/bugfixes/2026-08-06-build-version-and-shell-traps.md 陷阱 5）。
  if [[ "$1" == *.sh ]]; then set -- /bin/bash "$@"; fi
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

# 分组按 CI 上实测的每项耗时配平（实测数字和重排的做法见 docs/build/build-and-packaging.md
# 「CI」一节）。加了新检查就放进当前最空的那组，改完看一眼 CI 上各组的时长。每组内部仍是
# 快的在前。Rosetta 终端下必须显式 --arch arm64（见 docs/build/），各子脚本已各自处理。

# ---- 第 1 组：完整 App 编得过 + 纯值检查 + 扫描守卫 ----
# CI 上这一组的 runner 先单独冷编一遍完整 App（编译错误在自己的步骤里看得清），其余几组
# 只编核心库（子脚本只要 SrtFlowCore 的模块和目标文件）。所以「App 编得过」要在这里
# 明写一项：子脚本不再顺手编整个 App 了。
shard 1
run_check "build（完整 App 编得过）" swift build --arch arm64
run_check "SrtFlowCoreChecks（核心库）" swift run --arch arm64 SrtFlowCoreChecks
run_check "no-hardcoded-fps（扫描守卫）" checks/no-hardcoded-fps.sh
run_check "no-swallowed-build-output（扫描守卫）" checks/no-swallowed-build-output.sh
run_check "shell-var-boundary（扫描守卫）" checks/shell-var-boundary.sh
run_check "shell-pipe-grep-q（扫描守卫）" checks/shell-pipe-grep-q.sh
run_check "exported-types-declared（扫描守卫）" checks/exported-types-declared.sh
run_check "hover-pointer-style（扫描守卫）" checks/hover-pointer-style.sh
run_check "blocking-media-reads（扫描守卫）" checks/blocking-media-reads.sh
run_check "check-script-source-lists（扫描守卫）" checks/check-script-source-lists.sh
run_check "docs-index-drift（扫描守卫）" checks/docs-index-drift.sh
run_check "timeline-drag-wiring（扫描守卫）" checks/timeline-drag-wiring.sh
run_check "instant-tooltip-wiring（扫描守卫）" checks/instant-tooltip-wiring.sh
run_check "transition-handles-wiring（扫描守卫）" checks/transition-handles-wiring.sh
run_check "subtitle-editing-wiring（扫描守卫）" checks/subtitle-editing-wiring.sh
run_check "inspector-live-binding（扫描守卫）" checks/inspector-live-binding-wiring.sh
run_check "presented-views-app-language（扫描守卫：sheet / popover 套应用内语言）" checks/presented-views-app-language.sh
run_check "localization-coverage（界面文案两表配齐）" scripts/check-localization-coverage.sh
# 提示面板落点（scripts/check-instant-tooltip-panel.sh）**故意不在这里**：它要建
# 真实的 NSWindow/NSPanel，没有图形会话就会假红。按本文件开头的约定，真实窗口
# 一律走 GUI 冒烟流程（docs/testing/gui-smoke-testing.md）。
run_check "export-alpha-compositing（上层轨动画段 fill+matte）" scripts/check-export-alpha-compositing.sh

# ---- 第 2 组 ----
shard 2
run_check "translation-preflight（翻译配对预检）" scripts/check-translation-preflight.sh
run_check "timeline-snap（拖动吸附与对齐线）" scripts/check-timeline-snap.sh
run_check "media-import（拖文件进轨道的落点）" scripts/check-media-import.sh
# 真跑好几遍 ffmpeg 导出，全场最慢的一项（CI 上约 45 秒），配的伙伴最少。
run_check "export-frame-rate（生产导出滤镜：帧率 + 拼接链 + 分辨率）" scripts/check-export-frame-rate.sh

# ---- 第 3 组 ----
shard 3
run_check "player-clock（悬停 peek 状态机）" scripts/check-player-clock.sh
run_check "freeze-frame（定格时间线变换）" scripts/check-freeze-frame.sh
run_check "preview-composition（预览合成真取帧）" scripts/check-preview-composition.sh
run_check "text-render（画面文字：渲染图与成片逐点重合）" scripts/check-text-render.sh
run_check "audio-fade（渐入渐出 / 音量曲线 / 推子的真实包络 + 音量钉点不变量）" scripts/check-audio-fade.sh

# ---- 第 4 组 ----
shard 4
run_check "waveform（波形多级峰值：声道 / 尖峰 / 跨块 / 5.1 / 很多文件同时读）" scripts/check-waveform.sh
run_check "project-file（工程存盘/重链接）" scripts/check-project-file.sh
run_check "filters（调色：LUT 数学 + 预览与成片逐像素）" scripts/check-filters.sh
# 这一条要按真实时间喂 5 秒采样（fragment 必须真的冲出去），所以慢。
run_check "screen-recording-writer（录屏产物盖到 T1）" scripts/check-screen-recording-writer.sh

# ---- 第 5 组 ----
shard 5
run_check "audio-library（清单解析的宽容边界 + 双语搜索）" scripts/check-audio-library.sh
run_check "video-fade（上层视频轨铺满 + 画面渐变真产物）" scripts/check-video-fade.sh
# 预览取帧 + 真导出抽帧两边逐点对账（五种效果 + fill/matte），所以慢。
run_check "clip-animation（入场/出场动画：预览与成片对账）" scripts/check-clip-animation.sh
run_check "still-clip-encode（静帧真实产物）" scripts/check-still-clip-encode.sh

echo ""
echo "════════════════════════════════════════"
if [ -n "${SHARD}" ]; then
  echo "第 ${SHARD} 组（共 ${SHARD_TOTAL} 组）：通过 ${PASS} 项，失败 ${FAIL} 项"
  # 一项都没跑到就是分组写坏了，不能算绿。
  if [ $((PASS + FAIL)) -eq 0 ]; then
    echo "✗ 第 ${SHARD} 组一项检查都没跑 —— 分组写坏了" >&2
    exit 1
  fi
else
  echo "通过 ${PASS} 项，失败 ${FAIL} 项"
fi
if [ "${FAIL}" -gt 0 ]; then
  echo "失败的：${FAILED_NAMES}" >&2
  exit 1
fi
echo "All checks passed"
