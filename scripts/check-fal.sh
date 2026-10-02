#!/usr/bin/env bash
# fal.ai 生成（方案第 6 块）的自检：
#   1. 模型表和估价：每种事一个默认、每个登记的端点有写法和接口定义快照、视频只用 minimax/h3-max/ 系列、估价的算术；
#   2. 花钱的把关：额度内不问、超了先问、没登记单价每次问、按本地自然日记账；
#   3. 给 fal 的请求体：每个登记端点造出来的请求体**逐条对着 fal 公开的接口定义快照验**（必填、取值、范围、多余字段）；
#   4. fal 回来的东西：每个端点的样例输出读出下载地址和后缀、旁白的词时间三种写法；
#   5. FalClient：假 URLSession 协议按脚本回话 —— 提交的路径 / 头 / 体、照 fal 给的地址走、每种失败换成什么话、
#      取消（Task 被取消 / 超时）时替 fal 也取消、下载的收尾、没有 Key 时一个请求也不发；
#   6. 粘进来的 Key 怎么整理；
#   7. 视频 upscale：六个档位的端点都有快照、每个档位 × 每档目标的请求体对着快照验、倍数按模型夹、估价钉在 2026-10-02 的账单上，
#      以及 FalClient 的上传（initiate + PUT，PUT 不带 Key）和账单明细的查询。
#
# 不碰真的网络、不碰真的钥匙串（钥匙串在 scripts/check-fal-keychain.sh，本机手动）。
# 「生成」这条工具在 App 里的接线（AIToolRouter、任务、横幅上的提问）由 scripts/check-mcp.sh 和它的扫描守卫钉着。
#
# 用法：
#   scripts/check-fal.sh
#
# 编法同 check-audio-library.sh：被测代码在 SrtFlow app target 里，SwiftPM 不允许两个 target 共用源文件，
# 所以挑纯值文件单独编成自检二进制。接口定义的快照在 checks/Fal/schemas/，用 scripts/fal-models/refresh.sh 更新。
set -euo pipefail
cd "$(dirname "$0")/.."

# Rosetta 终端下必须显式指定 arm64（见 docs/build/）。
ARCH_FLAG="--arch arm64"
TRIPLE="arm64-apple-macosx15.0"

echo "==> swift build ${ARCH_FLAG} --target SrtFlowMCPKit"
# SwiftPM 的编译诊断走 stdout：静默成功可以，失败必须倾倒完整输出
#（>/dev/null 会把编译错误吞成无字天书，见 docs/bugfixes/ 2026-08-08 CI 首跑案例）。
BUILD_OUT="$(swift build ${ARCH_FLAG} --target SrtFlowMCPKit 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_DIR="$(swift build ${ARCH_FLAG} --show-bin-path)"

OUT="$(mktemp -d)/falcheck"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

echo "==> 编译自检二进制"
# 清单是手抄的（scripts/check-project-file.sh 开头讲了为什么），由 checks/check-script-source-lists.sh 守着。
xcrun swiftc \
  -target "$TRIPLE" \
  -wmo \
  -I "$BUILD_DIR/Modules" \
  -o "$OUT" \
  Sources/SrtFlow/Fal/FalModels.swift \
  Sources/SrtFlow/Fal/FalSpend.swift \
  Sources/SrtFlow/Fal/FalInputs.swift \
  Sources/SrtFlow/Fal/FalOutputs.swift \
  Sources/SrtFlow/Fal/FalClient.swift \
  Sources/SrtFlow/Fal/FalKeyStore.swift \
  Sources/SrtFlow/Fal/FalUpscaleModels.swift \
  Sources/SrtFlow/Fal/FalBilling.swift \
  checks/Fal/main.swift \
  checks/Fal/Harness.swift \
  checks/Fal/RegistryChecks.swift \
  checks/Fal/SpendChecks.swift \
  checks/Fal/InputChecks.swift \
  checks/Fal/OutputChecks.swift \
  checks/Fal/ClientChecks.swift \
  checks/Fal/KeyChecks.swift \
  checks/Fal/UpscaleChecks.swift \
  "$BUILD_DIR"/SrtFlowMCPKit.build/*.o

echo "==> 跑自检"
"$OUT"
