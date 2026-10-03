#!/usr/bin/env bash
# 从 dist/SrtFlow.app 做一份「SrtFlow Beta」测试版，给用户在自己的机器上实测没合并的功能。
#
# 和装着的正式版互不干扰：
#   - 名字和 bundle id 都换掉（com.srtflow.SrtFlow.beta）：设置各存各的，AI 的通道（socket 按
#     bundle id 分，docs/architecture/ai-control-mcp.md 第三节）也各用各的；
#   - 每一种文档类型都只做「备选」：双击工程文件、字幕文件仍由正式版打开。
#
# 用法：
#   VERSION=x.y.z scripts/build-app.sh && scripts/build-beta-app.sh
#
# 产物：dist/SrtFlow Beta.app（不打 DMG：只在本机用）。
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="dist/SrtFlow.app"
BETA="dist/SrtFlow Beta.app"
if [ ! -d "${SRC}" ]; then
  echo "✗ 没找到 ${SRC}：先跑 scripts/build-app.sh" >&2
  exit 1
fi

echo "==> 复制成 ${BETA}"
rm -rf "${BETA}"
ditto "${SRC}" "${BETA}"

PLIST="${BETA}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.srtflow.SrtFlow.beta" "${PLIST}"
/usr/libexec/PlistBuddy -c "Set :CFBundleName SrtFlow Beta" "${PLIST}"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName SrtFlow Beta" "${PLIST}"

# 双击工程 / 字幕文件仍交给正式版：测试版在每一种文档类型上都只做「备选」。
COUNT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDocumentTypes' "${PLIST}" | grep -c '^    Dict {' || true)"
if [ -z "${COUNT}" ] || [ "${COUNT}" -eq 0 ]; then
  echo "✗ Info.plist 里没读到文档类型：PlistBuddy 的输出格式变了？测试版会抢走双击工程文件" >&2
  exit 1
fi
for ((i = 0; i < COUNT; i++)); do
  /usr/libexec/PlistBuddy -c "Set :CFBundleDocumentTypes:${i}:LSHandlerRank Alternate" "${PLIST}"
done
echo "   ${COUNT} 种文档类型改成备选"

# 改了 Info.plist，外层签名就失效了：重签，和 build-app.sh 同一处（同一把签名身份，测试版的系统权限也跨版本有效）。
echo "==> codesign"
scripts/signing/sign-app.sh "${BETA}"

echo
echo "完成：${BETA}"
