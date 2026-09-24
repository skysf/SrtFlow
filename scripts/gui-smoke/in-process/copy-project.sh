#!/usr/bin/env bash
# 把一份工程**连素材**拷到别处，给进程内冒烟用（docs/testing/gui-smoke-testing.md「四之六」）。
#
#   scripts/gui-smoke/in-process/copy-project.sh <工程.srtflowproj> <目标目录>
#
# 为什么要拷、还要连素材一起拷、还要改路径：
# 1. 自动保存会改写工程文件，不能拿用户的原件跑。
# 2. 调试用的 SrtFlowDev.app 每次重编都是新签名，素材留在 ~/Downloads、~/Desktop、~/Documents
#    这些 TCC 保护的文件夹里，系统每次都重新弹「想访问下载文件夹」；人不点，App 就卡在第一次
#    访问那个文件的 getxattr 里，脚本停在 settle 上，看起来像工程没打开（2026-09-24 案例）。
#    所以素材要一起搬到 /private/tmp 这种没有 TCC 的地方，工程里指向它们的路径也得改。
# 3. 路径不止在 media 表里：每段还带 file:// 形式的 sourceURL；书签会解析回原处，去掉，让载入
#    走路径。工程目录之外的素材拷成 stray-<文件名>。
#
# 产物：<目标目录>/Edit.template.json（改好路径的工程，只读模板）和
#      <目标目录>/Edit.srtflowproj（每次跑之前从模板复原：cp 模板 → 它）。
set -euo pipefail
if [ $# -ne 2 ] || [ ! -f "$1" ]; then
  echo "✗ 用法：$0 <工程.srtflowproj> <目标目录>" >&2
  exit 2
fi
SRC_FILE="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
SRC_DIR="$(dirname "$SRC_FILE")"
DST="$2"
case "$DST" in
  "$HOME/Downloads"*|"$HOME/Desktop"*|"$HOME/Documents"*)
    echo "✗ 目标目录还在 TCC 保护的文件夹里：${DST}（放到 /private/tmp 下的 scratchpad 去）" >&2
    exit 2 ;;
esac
rm -rf "$DST"
mkdir -p "$(dirname "$DST")"
cp -R "$SRC_DIR" "$DST"
rm -f "$DST/$(basename "$SRC_FILE")"
SRC_DIR="$SRC_DIR" DST="$DST" SRC_FILE="$SRC_FILE" python3 - <<'PY'
import json, os, shutil, urllib.parse
src, dst, src_file = os.environ["SRC_DIR"], os.path.abspath(os.environ["DST"]), os.environ["SRC_FILE"]
d = json.load(open(src_file))
counts = {"path": 0, "sourceURL": 0, "bookmark": 0, "stray": 0}
def relocate(p):
    if p.startswith(src + "/"):
        return dst + p[len(src):]
    home = os.path.expanduser("~")
    if any(p.startswith(home + f"/{f}/") for f in ("Downloads", "Desktop", "Documents")):
        target = dst + "/stray-" + os.path.basename(p)
        if os.path.exists(p) and not os.path.exists(target):
            shutil.copy(p, target); counts["stray"] += 1
        return target
    return None
def walk(o):
    if isinstance(o, dict):
        for k, v in list(o.items()):
            if k == "bookmark":
                o.pop(k); counts["bookmark"] += 1
            elif k == "sourceAssetFingerprint":
                continue
            elif isinstance(v, str) and v.startswith("file://"):
                q = relocate(urllib.parse.unquote(v[len("file://"):]))
                if q: o[k] = "file://" + urllib.parse.quote(q); counts["sourceURL"] += 1
            elif isinstance(v, str):
                q = relocate(v)
                if q: o[k] = q; counts["path"] += 1
            else:
                walk(v)
    elif isinstance(o, list):
        for x in o: walk(x)
walk(d)
template = dst + "/Edit.template.json"
json.dump(d, open(template, "w"), ensure_ascii=False, indent=2)
shutil.copy(template, dst + "/Edit.srtflowproj")
print(f"✓ 拷到 {dst}：改了 {counts['path']} 处路径、{counts['sourceURL']} 处 sourceURL，去掉 {counts['bookmark']} 份书签，"
      f"工程目录外的素材 {counts['stray']} 个")
PY
