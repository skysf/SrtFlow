#!/usr/bin/env bash
# 扫描守卫：检查器里的 Picker 不许 `.fixedSize()`（规矩见 docs/architecture/inspector-layout.md）。
#
# 检查器是一条固定的窄栏（去掉边距约 220pt）。菜单型 Picker 的理想宽度按**最长的那个选项**算；
# 给它 `.fixedSize()` 就是不许它收缩 —— 那一行的最小宽度一旦超过窄栏，整列被撑宽，右边一截被裁掉：
# 菜单上显示的选中项、「Mute」、滑杆后面的百分比都看不见了。2026-09-24 声音场景那一块就是这样
# （docs/bugfixes/2026-09-24-sound-scene-row-widens-inspector.md），自动检查全绿、实机一眼就看见。
#
# 只管 Picker（它的宽度跟着选项变）；标签固定又很短的小菜单（比如裁切比例那个 None / Custom）
# 锁住宽度没关系，不在管辖范围内。
#
# 用法：checks/inspector-fits-width.sh
set -euo pipefail
cd "$(dirname "$0")/.."

read -r -d '' SCAN <<'PY' || true
import glob, io, re, sys

def matching(src, index):
    depth, i = 1, index + 1
    while i < len(src) and depth:
        if src[i] == "(":
            depth += 1
        elif src[i] == ")":
            depth -= 1
        i += 1
    return i

def closing_brace(src, index):
    depth, i = 1, index + 1
    while i < len(src) and depth:
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
        i += 1
    return i

files = sorted(glob.glob("Sources/SrtFlow/VideoEditInspector*.swift"))
if not files:
    print("✗ 一个检查器文件都没扫到：路径变了，守卫会扫空 —— 同步改这里", file=sys.stderr)
    sys.exit(1)
failures = []
pickers = 0
for path in files:
    src = io.open(path, encoding="utf-8").read()
    for m in re.finditer(r"\bPicker\(", src):
        pickers += 1
        end = matching(src, m.end() - 1)
        # Picker(...) { 选项 } 的尾随闭包
        rest = src[end:]
        stripped = rest.lstrip()
        if stripped.startswith("{"):
            brace = end + (len(rest) - len(stripped))
            end = closing_brace(src, brace)
        # 紧跟着的修饰器链：一行一行以 `.` 开头的，连同注释行，直到别的东西
        chain = []
        for line in src[end:].split("\n")[1:]:
            text = line.strip()
            if text.startswith("//") or text == "":
                continue
            if not text.startswith("."):
                break
            chain.append(text)
        if any(re.match(r"\.fixedSize\(\s*\)", t) or re.match(r"\.fixedSize\(\s*horizontal:\s*true", t) for t in chain):
            line_no = src.count("\n", 0, m.start()) + 1
            failures.append(f"{path}:{line_no}")
if failures:
    for f in failures:
        print(f"✗ {f}：检查器里的 Picker 挂了 .fixedSize()（按最长的选项锁死宽度，会把整列撑宽、右边被裁）"
              " —— 让它收缩，或者标题单独一行、菜单铺满下一行", file=sys.stderr)
    sys.exit(1)
print(f"✓ inspector-fits-width：检查器里 {pickers} 个 Picker 都没有锁死宽度")
PY
python3 -c "${SCAN}"
