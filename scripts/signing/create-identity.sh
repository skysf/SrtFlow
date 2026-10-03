#!/usr/bin/env bash
# 建发布用的签名身份（一次性）：一把自签名的代码签名证书，放进仓库外的专用钥匙串
# ~/.config/srtflow/signing/srtflow-signing.keychain-db（密码在同目录的 keychain-password，权限 600）。
#
# 只在没有的时候建，已经有了就拒绝：换一把证书，签出来的 SrtFlow 在每个用户的系统里都算「另一个 App」，
# 录屏、麦克风、下载文件夹、钥匙串里给过的权限全部作废一次（docs/architecture/code-signing-and-permissions.md）。
# 换机器时把整个 ~/.config/srtflow/signing/ 拷过去，别在新机器上重新建。
#
# 建好之后自己签一个小程序验一遍：designated requirement 必须是「certificate leaf = 这把证书」，不是 cdhash。
# 仓库还没钉证书（packaging/signing-identity.sha1 为空）时顺手写进去；钉着的是别的证书就只提醒、不改。
#
# 用法：scripts/signing/create-identity.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/signing/common.sh

if [ -e "${SIGNING_KEYCHAIN}" ]; then
  echo "✗ 已经有签名身份了：${SIGNING_KEYCHAIN}（SHA-1 $(signing_identity_sha1)）" >&2
  echo "  别重新建：换证书 = 每个用户给过的系统权限再作废一次。换机器就把整个 ${SIGNING_DIR} 拷过去。" >&2
  exit 1
fi

# 系统自带的 LibreSSL：Homebrew 的 OpenSSL 3 默认导出的 p12 用 AES + PBKDF2，`security import` 认不出来。
OPENSSL=/usr/bin/openssl
WORK="$(mktemp -d)"
DONE=0
# 半路失败就把建了一半的钥匙串删掉：还没拿它签过任何东西，留着只会让下一次以为「已经有了」。
cleanup() {
  signing_keychain_detach
  rm -rf "${WORK}"
  if [ "${DONE}" != 1 ]; then
    security delete-keychain "${SIGNING_KEYCHAIN}" 2>/dev/null || rm -f "${SIGNING_KEYCHAIN}"
    rm -f "${SIGNING_PASSWORD_FILE}"
  fi
}
trap cleanup EXIT

echo "==> 生成证书（自签名、只能签代码、20 年）"
cat > "${WORK}/cert.cnf" <<CNF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = ${SIGNING_IDENTITY_NAME}
[ ext ]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
"${OPENSSL}" req -x509 -newkey rsa:2048 -nodes -days 7300 -config "${WORK}/cert.cnf" \
  -keyout "${WORK}/key.pem" -out "${WORK}/cert.pem" 2>/dev/null
PASSWORD="$("${OPENSSL}" rand -hex 24)"
"${OPENSSL}" pkcs12 -export -inkey "${WORK}/key.pem" -in "${WORK}/cert.pem" \
  -name "${SIGNING_IDENTITY_NAME}" -out "${WORK}/identity.p12" -passout "pass:${PASSWORD}"

echo "==> 专用钥匙串：${SIGNING_KEYCHAIN}"
mkdir -p "${SIGNING_DIR}"
chmod 700 "${SIGNING_DIR}"
( umask 077 && printf '%s\n' "${PASSWORD}" > "${SIGNING_PASSWORD_FILE}" )
security create-keychain -p "${PASSWORD}" "${SIGNING_KEYCHAIN}"
chmod 600 "${SIGNING_KEYCHAIN}"
security unlock-keychain -p "${PASSWORD}" "${SIGNING_KEYCHAIN}"
# -T 和分区列表都给 codesign：签名时不弹「codesign 想使用钥匙串里的密钥」的框。
security import "${WORK}/identity.p12" -k "${SIGNING_KEYCHAIN}" -P "${PASSWORD}" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "${PASSWORD}" "${SIGNING_KEYCHAIN}" >/dev/null
security lock-keychain "${SIGNING_KEYCHAIN}"
SHA1="$(signing_identity_sha1)"
if [ -z "${SHA1}" ]; then
  echo "✗ 导入之后在钥匙串里找不到「${SIGNING_IDENTITY_NAME}」的证书" >&2
  exit 1
fi

echo "==> 签一个小程序验一遍"
cp /usr/bin/true "${WORK}/probe"
signing_keychain_attach
codesign --force --sign "${SHA1}" --keychain "${SIGNING_KEYCHAIN}" --timestamp=none \
  --identifier com.srtflow.signing-probe "${WORK}/probe"
signing_keychain_detach
REQUIREMENT="$(codesign -d -r- "${WORK}/probe" 2>&1 || true)"
if ! grep -F "certificate leaf = H\"${SHA1}\"" <<<"${REQUIREMENT}" >/dev/null; then
  echo "✗ 签出来的 designated requirement 不是钉在这把证书上：" >&2
  echo "${REQUIREMENT}" >&2
  exit 1
fi
echo "   ✓ $(sed -n 's/^designated => //p' <<<"${REQUIREMENT}")"
DONE=1

PINNED="$(signing_pinned_sha1)"
if [ -z "${PINNED}" ]; then
  printf '%s\n' "${SHA1}" >> "${SIGNING_PIN_FILE}"
  echo "==> 钉进 ${SIGNING_PIN_FILE}：${SHA1}（提交它）"
elif [ "${PINNED}" != "${SHA1}" ]; then
  echo "⚠️  ${SIGNING_PIN_FILE} 钉着的是另一把证书（${PINNED}），这把是 ${SHA1}。"
  echo "    旧的那把还在别的机器上的话，别用这把：把那台机器上的 ${SIGNING_DIR} 拷过来。"
  echo "    确定要换，就改 ${SIGNING_PIN_FILE}，并在发版说明里告诉用户要把录屏等权限重新给一次。"
fi

echo
echo "完成：签名身份「${SIGNING_IDENTITY_NAME}」（SHA-1 ${SHA1}）"
echo "备份整个 ${SIGNING_DIR}（钥匙串 + 密码文件）；丢了只能重建，用户就得把权限再给一次。"
