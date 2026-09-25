#!/usr/bin/env bash
# **检查器的连续写入接线守卫。**
#
# 由来（2026-09-17，文字动画）：入场效果选了 Fade 之后，点一下秒数的步进
# 箭头，Fade 当场退回 None。同一个错误还让「勾了粗体再拖字号」把粗体掉了。
#
# 机制：`VideoEditProject.liveApply` 的语义是「**每次都从手势开始时的那份
# 快照**重新应用一次完整修改」。滑块有松手信号（`onEditingChanged` /
# `labelledSlider` 会调 `endLiveEdit` 把快照收掉），**离散控件没有** ——
# 下拉、开关、步进箭头写完之后快照一直挂着，下一次写入就从那份陈旧状态
# 出发，把上一次的改动一起抹掉。编译器看不见，代码审查也极难发现。
#
# 四条规则，只作用于**返回 Binding 的工厂**（`liveOverlay`、`liveSetCrop`
# 这类不是绑定的东西不在管辖范围内）：
#   A. 体内做 live 写入的绑定工厂，名字必须以 live 开头 —— 让危险写在脸上。
#   B. 离散控件（Picker selection: / Toggle isOn: / Stepper value: /
#      InspectorScrubbableNumberField value:）不许收 live 绑定。
#   C. 每一处对 live 工厂的**调用**只准落在两种位置：滑块的 `value:`，
#      或一个同样以 live 开头的实参标签 / 局部常量。光有 B 不够 —— 绑定常常先转发成
#      一个普通名字的参数，到了 Picker 那里就看不出是 live 的了
#      （这正是漏掉那次的原因）。
#   D. 裸 Slider 用 live 绑定时，同一个调用里必须有 endLiveEdit
#      （labelledSlider 自带，豁免）。
#   E. 滑杆行右边的数值框（InspectorSliderRow，2026-09-24 起所有滑杆行都能打字）收的是
#      同一条 live 绑定换算出来的 fieldBinding：它的 set 里写完必须**立刻** endLiveEdit ——
#      打字提交和箭头没有松手信号，不收快照就是 B 条那个病。
#
# 用法：checks/inspector-live-binding-wiring.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# ---- 规则 E：滑杆行数值框的绑定写完立刻收快照 ----
ROW="Sources/SrtFlow/InspectorSliderRow.swift"
[ -f "$ROW" ] || { echo "FAIL 找不到 ${ROW}（滑杆行挪走了就同步改这里）"; exit 1; }
SETTER="$(awk '/private var fieldBinding/ { inside = 1 } inside { print } inside && /^    \}$/ { exit }' "$ROW")"
if ! grep -c 'endLiveEdit' <<<"$SETTER" >/dev/null; then
  echo "FAIL $ROW: fieldBinding 的 set 里没有 endLiveEdit —— 打字提交后快照会一直挂着，下一次改动从陈旧状态出发"
  exit 1
fi
if ! grep -c 'value: fieldBinding' "$ROW" >/dev/null; then
  echo "FAIL $ROW: 数值框没有接 fieldBinding（直接接 live 绑定 = 规则 B 那个病）"
  exit 1
fi

python3 - << 'PYEOF'
import glob, io, re, sys

LIVE_CALLS = ("beginLiveEdit", "liveApply", "liveUpdate")
DISCRETE = [("Picker", "selection"), ("Toggle", "isOn"),
            ("Stepper", "value"), ("InspectorScrubbableNumberField", "value")]
SLIDERS = {"Slider", "labelledSlider"}

failures = []


def matching(src, index, opening, closing):
    """从 index 处的开括号数到配对的闭括号，返回结束位置（闭括号之后）。"""
    depth, i = 1, index + 1
    while i < len(src) and depth:
        if src[i] == opening:
            depth += 1
        elif src[i] == closing:
            depth -= 1
        i += 1
    return i


def encloser(src, index):
    """这个位置外面那一层调用叫什么名字。"""
    depth, i = 0, index
    while i > 0:
        i -= 1
        if src[i] == ")":
            depth += 1
        elif src[i] == "(":
            if depth == 0:
                name = re.search(r"(\w+)$", src[:i])
                return name.group(1) if name else ""
            depth -= 1
    return ""


for path in sorted(glob.glob("Sources/SrtFlow/VideoEditInspector*.swift")):
    src = io.open(path, encoding="utf-8").read()

    # ---- 先认出所有"返回 Binding 的工厂"，以及它们是不是 live 的 ----
    #
    # 签名里不许出现花括号 —— 否则正则会一路扫过整个文件去找下一个
    # `-> Binding<`，把毫不相干的声明认成绑定工厂。
    live_factories = set()
    for m in re.finditer(r"(?:func|var)\s+(\w+)[^{}]*?->\s*Binding<", src):
        name = m.group(1)
        brace = src.find("{", m.end())
        if brace < 0:
            continue
        body = src[brace:matching(src, brace, "{", "}")]
        if not any(call in body for call in LIVE_CALLS):
            continue
        live_factories.add(name)
        if not name.startswith("live"):
            failures.append(
                f"{path}: 绑定工厂 `{name}` 体内有 live 写入，名字必须以 live 开头"
                f"（调用点才看得出它需要结束信号）"
            )

    # ---- 规则 B：离散控件不许收 live 绑定 ----
    for control, label in DISCRETE:
        for m in re.finditer(r"\b%s\(" % control, src):
            args = src[m.end():matching(src, m.end() - 1, "(", ")") - 1]
            found = re.search(r"\b%s:\s*([^\n,]+)" % label, args)
            if not found:
                continue
            expr = found.group(1)
            head = re.match(r"\s*(\w+)", expr)
            bad = re.search(r"\blive[A-Z]\w*", expr) or (head and head.group(1) in live_factories)
            if bad:
                line = src[:m.start()].count("\n") + 1
                failures.append(
                    f"{path}:{line}: 离散控件 {control} 的 `{label}:` 收了 live 绑定"
                    f" `{expr.strip()}` —— 它没有结束信号，快照会挂着把下一次改动抹掉"
                )

    # ---- 规则 C：live 工厂的调用只准出现在允许的位置 ----
    for name in sorted(live_factories):
        for m in re.finditer(r"\b%s\s*\(" % re.escape(name), src):
            head = src[:m.start()]
            if re.search(r"\b(?:func|var)\s+$", head):     # 声明本身
                continue
            # 落成一个同样以 live 开头的**局部常量**也算：名字带着走了，
            # 下游（onScrubChanged 之类的闭包）一眼还是能看出来。
            if re.search(r"\blet\s+live\w*\s*(?::[^=]+)?=\s*$", head):
                continue
            label = re.search(r"(\w+):\s*$", head)
            if label and label.group(1).startswith("live"):
                continue
            if label and label.group(1) == "value" and encloser(src, m.start()) in SLIDERS:
                continue
            line = head.count("\n") + 1
            shown = (label.group(1) + ":") if label else "（没有实参标签）"
            failures.append(
                f"{path}:{line}: live 绑定 `{name}` 用在了 `{shown}` 上。只准给滑块的"
                f" value:，或转发到同样以 live 开头的参数/局部常量 —— 名字不带着走，"
                f"下游就看不出它需要结束信号"
            )

    # ---- 规则 D：裸 Slider 用 live 绑定要有结束信号 ----
    for m in re.finditer(r"(?<![A-Za-z])Slider\(", src):
        args = src[m.end():matching(src, m.end() - 1, "(", ")") - 1]
        found = re.search(r"\bvalue:\s*([^\n,]+)", args)
        if not found:
            continue
        head = re.match(r"\s*(\w+)", found.group(1))
        if not (head and head.group(1) in live_factories):
            continue
        if "endLiveEdit" not in args:
            line = src[:m.start()].count("\n") + 1
            failures.append(
                f"{path}:{line}: Slider 用了 live 绑定却没有 endLiveEdit，松手后快照收不掉"
            )

if failures:
    for line in failures:
        print("FAIL " + line)
    print(f"\n{len(failures)} 处问题。合同见 "
          f"VideoEditInspector+Text.swift 的「离散 vs 连续」小节。")
    sys.exit(1)

print("✓ 检查器接线守卫通过：live 绑定都带 live 前缀，且只接在滑块和 scrub 上")
PYEOF
