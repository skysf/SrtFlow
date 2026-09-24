#!/usr/bin/env bash
# 预览性能 ratchet（docs/architecture/preview-perf-ratchet.md）：起真 App，按固定场景数
# 「做了多少件活」（PerfCounters），和 checks/PreviewPerf/baseline.json 比 —— 只许降不许涨。
#
# **只在 CI 上跑**：.github/workflows/checks.yml 第 1 组里单独一步，**不在 check-all.sh 里**。
# 它要图形会话和真窗口，基线也是按 GitHub runner 的环境记的。本地想看数字可以手动跑，
# 结果只供参考（本地拿不到 PR 的合并提交，「基线只许降」那条查不了）。
#
# 用法：
#   scripts/check-preview-perf.sh               # 全套（CI）
#   scripts/check-preview-perf.sh --self-test   # 只跑比对规则的自检（check-all 里）
#   PREVIEW_PERF_OUT=<目录> scripts/check-preview-perf.sh   # 结果、日志留在这里（CI 上传成附件）
set -euo pipefail
cd "$(dirname "$0")/.."

# Rosetta 终端下必须显式指定 arm64，否则会去编 x86_64（见 docs/build/）。
ARCH_FLAG="--arch arm64"
TRIPLE="arm64-apple-macosx15.0"
BASELINE="checks/PreviewPerf/baseline.json"
SCENARIOS="basic busy"
RUNS_PER_SCENARIO=2
RUN_TIMEOUT=300

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
OUT_DIR="${PREVIEW_PERF_OUT:-${WORK}/out}"
mkdir -p "${OUT_DIR}"

echo "==> 编译比对器"
xcrun swiftc -target "${TRIPLE}" checks/PreviewPerf/compare.swift -o "${WORK}/compare"

if [ "${1:-}" = "--self-test" ]; then
  "${WORK}/compare" --self-test
  exit 0
fi

# 要真跑 ffmpeg 生成素材，**不允许静默跳过**（跳过 = 假绿）。
FFMPEG="${SRTFLOW_FFMPEG:-$(pwd)/vendor/ffmpeg}"
if [ ! -x "${FFMPEG}" ]; then
  echo "✗ 找不到可执行的 ffmpeg：${FFMPEG}（先运行 scripts/vendor-ffmpeg.sh）" >&2
  exit 1
fi
if [ ! -f "${BASELINE}" ]; then
  echo "✗ 没有基线文件 ${BASELINE}" >&2
  exit 1
fi

echo "==> swift build ${ARCH_FLAG}（debug 就行：数的是做了几件活，和编译优化无关）"
# SwiftPM 的编译诊断走 stdout：静默成功可以，失败必须倾倒完整输出。
BUILD_OUT="$(swift build ${ARCH_FLAG} 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
APP="$(swift build ${ARCH_FLAG} --show-bin-path)/SrtFlow"
if [ ! -x "${APP}" ]; then
  echo "✗ 没找到 App 可执行文件：${APP}" >&2
  exit 1
fi

echo "==> 生成素材（固定参数的软件编码；音频统一 48kHz 立体声 AAC —— 一条合成音轨"
echo "    换源格式会让电平表的 tap 死掉，见 docs/architecture/audio-mixer.md）"
MEDIA="${WORK}/media"
mkdir -p "${MEDIA}"
ff() { "${FFMPEG}" -hide_banner -loglevel error -y "$@"; }
for i in 1 2 3; do
  ff -f lavfi -i "testsrc2=size=1920x1080:rate=30" -f lavfi -i "sine=frequency=$((300 + i * 100)):sample_rate=48000" \
    -t 6 -c:v libx264 -preset veryfast -b:v 6M -pix_fmt yuv420p -c:a aac -ac 2 -b:a 128k -shortest \
    "${MEDIA}/main${i}.mp4"
done
ff -f lavfi -i "testsrc2=size=1280x720:rate=30" -t 8 -c:v libx264 -preset veryfast -b:v 3M -pix_fmt yuv420p -an \
  "${MEDIA}/overlay.mp4"
ff -f lavfi -i "sine=frequency=220:sample_rate=48000" -t 20 -c:a aac -ac 2 -b:a 128k "${MEDIA}/music.m4a"
cat > "${MEDIA}/subs.srt" <<'SRT'
1
00:00:00,500 --> 00:00:03,000
The first line of the bench subtitles

2
00:00:03,200 --> 00:00:06,000
A second line that is a little longer than the first one

3
00:00:06,200 --> 00:00:09,000
Third line

4
00:00:09,200 --> 00:00:12,000
Fourth line, near the pushed seam

5
00:00:12,200 --> 00:00:15,000
Fifth line

6
00:00:15,200 --> 00:00:17,500
The last line
SRT

RESULT_FILES=()
# 起一遍真 App 跑一个场景，结果记进 RESULT_FILES。$1 场景名，$2 第几遍
run_once() {
  local scenario="$1" n="$2"
  local result="${OUT_DIR}/${scenario}-${n}.json"
  local log="${OUT_DIR}/${scenario}-${n}.log"
  rm -f "${result}"
  echo "    ${scenario} 第 ${n} 遍"
  # -mainWindowSection：启动直接进 Edit Video（参数域覆盖 UserDefaults，不会写回去）。
  SRTFLOW_BENCH_OUT="${result}" SRTFLOW_BENCH_MEDIA="${MEDIA}" SRTFLOW_BENCH_SCENARIO="${scenario}" \
    SRTFLOW_SMOKE_MUTE=1 SRTFLOW_FFMPEG="${FFMPEG}" \
    "${APP}" -mainWindowSection videoEdit -ApplePersistenceIgnoreState YES >"${log}" 2>&1 &
  local pid=$!
  local waited=0
  while kill -0 "${pid}" 2>/dev/null; do
    if [ "${waited}" -ge "${RUN_TIMEOUT}" ]; then
      kill -9 "${pid}" 2>/dev/null || true
      echo "✗ ${scenario} 第 ${n} 遍 ${RUN_TIMEOUT} 秒还没结束。App 日志最后 60 行：" >&2
      tail -n 60 "${log}" >&2
      exit 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  local status=0
  wait "${pid}" || status=$?
  if [ "${status}" -ne 0 ] || [ ! -s "${result}" ]; then
    echo "✗ ${scenario} 第 ${n} 遍失败（退出码 ${status}）" >&2
    if [ -s "${result}" ]; then cat "${result}" >&2; fi
    echo "App 日志最后 60 行：" >&2
    tail -n 60 "${log}" >&2
    exit 1
  fi
  echo "      ${waited} 秒"
  RESULT_FILES+=("${result}")
}

echo "==> 跑场景（每个场景两遍；两遍不一样再跑第三遍，要有两遍一模一样）"
for scenario in ${SCENARIOS}; do
  for n in $(seq 1 "${RUNS_PER_SCENARIO}"); do
    run_once "${scenario}" "${n}"
  done
  # CI 虚拟机上偶尔有系统层面的事件让某个视图多更新一两次（只会多、不会少）。
  # 两遍不一样就再跑一遍，比对器从三遍里挑一模一样的那两遍（compare.swift 规则 1）。
  if ! "${WORK}/compare" --same "${OUT_DIR}/${scenario}-1.json" "${OUT_DIR}/${scenario}-2.json"; then
    echo "    ${scenario} 两遍计数不一样，跑第三遍"
    run_once "${scenario}" 3
  fi
done

# 这台 runner 的环境：基线是按它记的，换了镜像（系统 / Xcode）数字可能跟着变。
# 取第一行用 sed 不用 head：pipefail 下 head 提前关管道，上游吃 SIGPIPE 会让整条判失败。
XCODE="$({ xcodebuild -version 2>/dev/null || echo "Xcode ?"; } | sed -n 1p)"
FINGERPRINT="macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)) · ${XCODE} · $(sysctl -n hw.model) · $(sysctl -n hw.ncpu) CPU"

# 「基线只许降」：拿这个 PR 之前的基线（合并提交的第一个父提交）来比，
# 并看这个 PR 动没动产品代码（Sources/ 下除 PreviewBench*.swift 以外的文件）。
COMPARE_ARGS=(--baseline "${BASELINE}" --fingerprint "${FINGERPRINT}"
  --proposed "${OUT_DIR}/proposed-baseline.json" --measured "${OUT_DIR}/measured-baseline.json")
TOUCHES=0
if git rev-parse --verify --quiet "HEAD^1" >/dev/null; then
  if git cat-file -e "HEAD^1:${BASELINE}" 2>/dev/null; then
    git show "HEAD^1:${BASELINE}" > "${WORK}/previous-baseline.json"
    COMPARE_ARGS+=(--previous "${WORK}/previous-baseline.json")
  else
    echo "    上一个提交里还没有基线文件：第一次引入，不查「只许降」"
  fi
  CHANGED="$(git diff --name-only "HEAD^1" HEAD -- Sources/ | { grep -vE '^Sources/SrtFlow/PreviewBench[A-Za-z]*\.swift$' || true; })"
  if [ -n "${CHANGED}" ]; then TOUCHES=1; fi
elif [ "${CI:-}" = "true" ]; then
  echo "✗ CI 上拿不到上一个提交（checkout 要 fetch-depth: 2），「基线只许降」查不了" >&2
  exit 1
else
  echo "    本地运行、没有上一个提交：不查「基线只许降」"
fi
COMPARE_ARGS+=(--touches-product-code "${TOUCHES}")
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then COMPARE_ARGS+=(--summary "${GITHUB_STEP_SUMMARY}"); fi

echo "==> 和基线比"
status=0
"${WORK}/compare" "${COMPARE_ARGS[@]}" "${RESULT_FILES[@]}" || status=$?
if [ "${status}" -ne 0 ]; then
  echo "" >&2
  echo "✗ 预览性能 ratchet 没过。" >&2
  echo "  改了产品代码的 PR：退步的要改掉；进步了就把上面那份「改好的基线」写进 ${BASELINE}。" >&2
  echo "  只重定基线的 PR（runner 环境变了 / 场景改了，不碰产品代码）：用下面这份全部实测值：" >&2
  cat "${OUT_DIR}/measured-baseline.json" >&2
  exit 1
fi
echo "✓ 预览性能没有退步"
