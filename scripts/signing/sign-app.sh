#!/usr/bin/env bash
# 给组装好的 SrtFlow.app / SrtFlow Beta.app 签名（build-app.sh、build-beta-app.sh 都只经这一处签）。
#
# 先签 Contents/Helpers 里的两个可执行文件、再签外层：顺序反了外层签名立即失效（scripts/check-mcp.sh 钉着）。
#
# 用哪把签：
# - 有发布用的签名身份（scripts/signing/create-identity.sh 建在 ~/.config/srtflow/signing/）就用它。签名的
#   designated requirement 是「bundle id + 这把证书」，换一个版本也不变：系统里给过的录屏、麦克风、下载文件夹、
#   钥匙串权限跟着走（docs/architecture/code-signing-and-permissions.md）。签完核对 requirement 真的钉在证书上，
#   证书和仓库钉着的（packaging/signing-identity.sha1）不是同一把就不签。
# - 没有就退回 ad-hoc 并警告：那样签出来的每个新版本，用户都要把这些权限再给一遍，录屏那条在系统设置里
#   拨开关都救不回来。自己编着用没关系，别拿去发版。
#
# 用法：scripts/signing/sign-app.sh <App 路径>
set -euo pipefail
if [ "$#" -ne 1 ] || [ ! -d "$1" ]; then
  echo "用法：scripts/signing/sign-app.sh <App 路径>" >&2
  exit 1
fi
APP="$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")"
cd "$(dirname "$0")/../.."
source scripts/signing/common.sh

for helper in ffmpeg srtflow-mcp; do
  if [ ! -f "${APP}/Contents/Helpers/${helper}" ]; then
    echo "✗ ${APP}/Contents/Helpers/${helper} 不在：先组装完再签" >&2
    exit 1
  fi
done

# 嵌套的先签、外层最后签。参数是 codesign 的签名身份那几个选项。
sign_bundle() {
  codesign --force "$@" --timestamp=none "${APP}/Contents/Helpers/ffmpeg"
  codesign --force "$@" --timestamp=none "${APP}/Contents/Helpers/srtflow-mcp"
  codesign --force "$@" --timestamp=none "${APP}"
}

if signing_identity_present; then
  SHA1="$(signing_identity_sha1)"
  PINNED="$(signing_pinned_sha1)"
  if [ -z "${SHA1}" ]; then
    echo "✗ ${SIGNING_KEYCHAIN} 里找不到「${SIGNING_IDENTITY_NAME}」的证书" >&2
    exit 1
  fi
  if [ -n "${PINNED}" ] && [ "${PINNED}" != "${SHA1}" ]; then
    echo "✗ 这台机器上的签名证书（${SHA1}）不是仓库钉着的那把（${PINNED}，${SIGNING_PIN_FILE}）。" >&2
    echo "  用它签出来的版本，用户给过的录屏等权限全部作废一次。把原来那台机器上的 ${SIGNING_DIR} 拷过来；" >&2
    echo "  真要换证书，先改 ${SIGNING_PIN_FILE}，并在发版说明里写明要重新授权一次。" >&2
    exit 1
  fi
  echo "   签名身份：${SIGNING_IDENTITY_NAME}（SHA-1 ${SHA1}）"
  trap signing_keychain_detach EXIT
  signing_keychain_attach
  sign_bundle --sign "${SHA1}" --keychain "${SIGNING_KEYCHAIN}"
  signing_keychain_detach
  trap - EXIT
  REQUIREMENT="$(codesign -d -r- "${APP}" 2>&1 || true)"
  if ! grep -F "certificate leaf = H\"${SHA1}\"" <<<"${REQUIREMENT}" >/dev/null; then
    echo "✗ 签完的 designated requirement 没钉在证书上（系统权限会跟着版本作废）：" >&2
    echo "${REQUIREMENT}" >&2
    exit 1
  fi
else
  echo "⚠️  没有发布用的签名身份（${SIGNING_KEYCHAIN}），退回 ad-hoc 签名。"
  echo "    ad-hoc 的每个新版本在系统里都算「另一个 App」：录屏、麦克风、下载文件夹、钥匙串的权限要重新给，"
  echo "    录屏那条拨开关都救不回来。别拿这样的包发版；要建签名身份跑 scripts/signing/create-identity.sh。"
  sign_bundle --sign -
fi

codesign --verify --deep --strict "${APP}" && echo "   签名校验通过"
