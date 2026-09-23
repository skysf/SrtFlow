#!/usr/bin/env bash
# 代码里每一个 `UTType(exportedAs:)` 都必须在 packaging/Info.plist 的
# `UTExportedTypeDeclarations` 里声明。
#
# 没声明的标识符，系统的类型库查不到（`UTType(identifier)` 返回 nil），SwiftUI 的
# 落点就判不出拖进来的东西是不是这种类型 —— 拖放被直接拒绝，界面上没有任何提示，
# 运行时那条「expected to be declared」的警告只进系统统一日志。滤镜卡片和音频库
# 素材就是这么从上线起一直拖不进时间线的，而 Info.plist 里转场那条声明旁边还写着
# 「不声明也能跑，声明只是更规范」（2026-09-23，
# docs/bugfixes/2026-09-23-custom-drag-types-not-declared.md）。
#
# 标识符有三种写法，都认：字面量 `UTType(exportedAs: "com.x")`、同文件的常量
# `static let typeIdentifier = "com.x"`、以及转一手的 `= FilterPayloadType.drag`。
# 认不出来的写法直接红，别静默跳过（跳过 = 这条守卫对它失效）。
set -euo pipefail
cd "$(dirname "$0")/.."

PLIST="packaging/Info.plist"
DECLARED="$(/usr/libexec/PlistBuddy -c 'Print :UTExportedTypeDeclarations' "${PLIST}" \
  | awk -F' = ' '/UTTypeIdentifier/ { print $2 }')"

FAILED=0
COUNT=0

# 把 `UTType(exportedAs:` 后面那个表达式解析成字符串标识符。
resolve() {
  local file="$1" expr="$2" rhs enum member def
  if [[ "${expr}" == \"* ]]; then
    printf '%s\n' "${expr}" | sed -E 's/^"([^"]*)".*/\1/'
    return
  fi
  rhs="$(grep -E "static let ${expr} = " "${file}" | head -1 | sed -E 's/.*static let [A-Za-z_]+ = //' || true)"
  if [[ "${rhs}" == \"* ]]; then
    printf '%s\n' "${rhs}" | sed -E 's/^"([^"]*)".*/\1/'
    return
  fi
  if [[ "${rhs}" =~ ^([A-Za-z_]+)\.([A-Za-z_]+) ]]; then
    enum="${BASH_REMATCH[1]}"
    member="${BASH_REMATCH[2]}"
    def="$(grep -rlE "enum ${enum}([^A-Za-z0-9_]|$)" Sources/SrtFlow --include='*.swift' | head -1 || true)"
    if [ -n "${def}" ]; then
      { grep -E "static let ${member} = \"" "${def}" || true; } | head -1 | sed -E 's/.*= "([^"]*)".*/\1/'
    fi
  fi
}

while IFS= read -r hit; do
  file="${hit%%:*}"
  expr="$(printf '%s\n' "${hit}" | sed -E 's/.*UTType\(exportedAs: *([^,)]+).*/\1/')"
  id="$(resolve "${file}" "${expr}")"
  if [ -z "${id}" ]; then
    echo "✗ 认不出这一行的类型标识符（写法超出了这条守卫的三种解析）：${hit}" >&2
    FAILED=1
    continue
  fi
  COUNT=$((COUNT + 1))
  grep -qxF "${id}" <<<"${DECLARED}" || {
    echo "✗ ${id}（${file}）没在 ${PLIST} 的 UTExportedTypeDeclarations 里声明：系统认不出这个类型，拖放会被静默拒绝" >&2
    FAILED=1
  }
done < <(grep -rnE 'UTType\(exportedAs:' Sources/SrtFlow --include='*.swift' \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)

# 一个都没扫到 = 模式失效（改了写法 / 挪了目录），不是「全都声明了」。
[ "${COUNT}" -gt 0 ] || { echo "✗ 一个 UTType(exportedAs:) 都没扫到：守卫失去目标" >&2; FAILED=1; }

if [ "${FAILED}" -ne 0 ]; then
  exit 1
fi
echo "✓ exported-types-declared：代码里的 ${COUNT} 个 UTType(exportedAs:) 都在 ${PLIST} 里声明了"
