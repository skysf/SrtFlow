#!/usr/bin/env bash
# 发布版用固定的签名身份签，系统权限（录屏、麦克风、下载文件夹、钥匙串）跨版本有效；改签之前留下的
# 旧录屏记录，App 自己删掉、让系统重新问。
#
# 为什么：ad-hoc 签名的 designated requirement 就是 cdhash，每个新版本在系统里都是「另一个 App」；录屏那条
# 记录钉着旧签名时，在系统设置里把开关关掉再打开也救不回来 —— 用户每次升级都录不了自定义区域
# （docs/bugfixes/2026-10-03-screen-recording-permission-stale-after-update.md，长期约束见
# docs/architecture/code-signing-and-permissions.md）。
#
# 钉着：
#   1. build-app.sh / build-beta-app.sh 自己不调 codesign，都经 scripts/signing/sign-app.sh；
#   2. sign-app.sh 有签名身份就用它签、核对仓库钉着的证书、签完核对 requirement 钉在证书上；没有才退回 ad-hoc；
#   3. packaging/signing-identity.sha1 钉着正好一把证书；
#   4. 录自定义区域要授权时，先经 ScreenCapturePermissionRepair 删旧记录再请求；调 tccutil 的只有它；
#   5. 给用户的话里不再叫人「关掉再打开」。
set -euo pipefail
cd "$(dirname "$0")/.."

FAILED=0
fail() {
  echo "✗ $*" >&2
  FAILED=1
}
count() { { grep -cE "$1" "$2" || true; }; }
first_line() { { grep -nE "$1" "$2" || true; } | awk -F: 'NR == 1 { print $1 }'; }

echo "==> 1. 打包脚本只经 sign-app.sh 签名"
for script in scripts/build-app.sh scripts/build-beta-app.sh; do
  if [ "$(count '^[[:space:]]*codesign[[:space:]]' "${script}")" -ne 0 ]; then
    fail "${script} 自己调了 codesign：签名只许经 scripts/signing/sign-app.sh（有签名身份就用它，系统权限才跨版本有效）"
  fi
  if [ "$(count '^scripts/signing/sign-app\.sh "' "${script}")" -ne 1 ]; then
    fail "${script} 没有正好一处调 scripts/signing/sign-app.sh"
  fi
done

echo "==> 2. sign-app.sh：有签名身份就用它，签完核对"
SIGN="scripts/signing/sign-app.sh"
IDENTITY_BRANCH="$(first_line '^if signing_identity_present; then$' "${SIGN}")"
ADHOC_BRANCH="$(first_line '^else$' "${SIGN}")"
SIGN_WITH_IDENTITY="$(first_line '^  sign_bundle --sign "\$\{SHA1\}" --keychain "\$\{SIGNING_KEYCHAIN\}"$' "${SIGN}")"
SIGN_ADHOC="$(first_line '^  sign_bundle --sign -$' "${SIGN}")"
if [ -z "${IDENTITY_BRANCH}" ] || [ -z "${ADHOC_BRANCH}" ] || [ -z "${SIGN_WITH_IDENTITY}" ] || [ -z "${SIGN_ADHOC}" ]; then
  fail "${SIGN} 里找不到「有签名身份就用它签、没有才 ad-hoc」这两支"
elif [ "${SIGN_WITH_IDENTITY}" -gt "${ADHOC_BRANCH}" ] || [ "${SIGN_ADHOC}" -lt "${ADHOC_BRANCH}" ]; then
  fail "${SIGN} 的 ad-hoc 签名不在「没有签名身份」那一支里"
fi
if [ "$(count 'signing_pinned_sha1' "${SIGN}")" -lt 1 ]; then
  fail "${SIGN} 不核对仓库钉着的证书（packaging/signing-identity.sha1）：换了证书会悄悄签出来"
fi
if [ "$(count 'certificate leaf = H' "${SIGN}")" -lt 1 ]; then
  fail "${SIGN} 签完不核对 designated requirement 钉在证书上"
fi
if [ "$(count '^[[:space:]]*codesign --force "\$@" --timestamp=none' "${SIGN}")" -ne 3 ]; then
  fail "${SIGN} 的 sign_bundle 不是 ffmpeg、srtflow-mcp、外层三处签名"
fi

echo "==> 3. 仓库钉着正好一把证书"
PIN="packaging/signing-identity.sha1"
PINNED="$({ grep -v '^#' "${PIN}" || true; } | { grep -v '^[[:space:]]*$' || true; })"
if [ "$(grep -cE '^[0-9a-f]{40}$' <<<"${PINNED}" || true)" -ne 1 ] || [ "$(wc -l <<<"${PINNED}" | tr -d ' ')" -ne 1 ]; then
  fail "${PIN} 应该只有一行 40 位小写十六进制的 SHA-1（注释行除外），现在是：${PINNED:-（空）}"
fi

echo "==> 4. 录自定义区域：先删旧记录再请求，tccutil 只在一处"
PERMS="Sources/SrtFlow/ScreenRecordingPermissions.swift"
REPAIR_CALL="$(first_line '^        await ScreenCapturePermissionRepair\.resetRecordOncePerBuild\(\)$' "${PERMS}")"
REQUEST_CALL="$(first_line '^        _ = CGRequestScreenCaptureAccess\(\)$' "${PERMS}")"
if [ -z "${REPAIR_CALL}" ] || [ -z "${REQUEST_CALL}" ] || [ "${REPAIR_CALL}" -gt "${REQUEST_CALL}" ]; then
  fail "${PERMS} 请求录屏授权之前没先调 ScreenCapturePermissionRepair.resetRecordOncePerBuild()：钉着旧签名的记录不删，系统不会再问"
fi
SETUP="Sources/SrtFlow/ScreenRecordingCoordinator+Setup.swift"
if [ "$(count '_ = await ScreenRecordingPermissions\.requestScreenAccess\(\)' "${SETUP}")" -ne 1 ]; then
  fail "${SETUP} 录自定义区域没走 ScreenRecordingPermissions.requestScreenAccess()"
fi
TCCUTIL_FILES="$(grep -rlF '"/usr/bin/tccutil"' Sources --include='*.swift' || true)"
if [ "${TCCUTIL_FILES}" != "Sources/SrtFlow/ScreenCapturePermissionRepair.swift" ]; then
  fail "调 tccutil 的应该只有 Sources/SrtFlow/ScreenCapturePermissionRepair.swift，现在是：${TCCUTIL_FILES:-（没有）}"
fi

echo "==> 5. 不再叫人「关掉再打开」"
STALE_ADVICE='If the switch is already on, turn it off and on again'
STALE_HITS="$(grep -rlF "${STALE_ADVICE}" Sources || true)"
if [ -n "${STALE_HITS}" ]; then
  fail "还在叫人把录屏开关关掉再打开（钉着旧签名的记录拨开关救不回来）：${STALE_HITS}"
fi

if [ "${FAILED}" -ne 0 ]; then
  exit 1
fi
echo "✓ release-signing：发布版用固定签名身份签，录屏旧记录 App 自己删"
