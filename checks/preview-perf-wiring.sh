#!/usr/bin/env bash
# 扫描守卫：预览性能测试的计数必须接满（docs/architecture/preview-perf-ratchet.md）。
#
# CI 上卡的是「做了多少件活」（PerfCounters）：哪个视图的 body 被重算了几次、
# updateNSView 被调了几次、Canvas 画了几次。**漏插一个，那个视图每跳一下都在重算，
# 账上也看不见** —— 性能测试照样绿，ratchet 就成了摆设。所以：
#
# 1. 每个 SwiftUI 视图 / 修饰器的 body 下一行必须是 `let _ = PerfCounters.body(Self.self)`；
# 2. 视图 / 修饰器的个数必须等于标准写法的 body 个数 —— 把 body 写成一行、或者换了
#    写法，第 1 条就扫不到它，这里直接判红（请写成标准形式）；
# 3. 每个 `updateNSView` 下一行是 `PerfCounters.update(Self.self)`，个数和
#    NSViewRepresentable 对得上；每个 Canvas 的绘制闭包第一行是 `PerfCounters.canvas(Self.self)`；
# 4. 视图不许重名：计数按类型名记账，重名就串成一笔；
# 5. 非视图的几处埋点和测试入口都还接着。
#
# 用法：checks/preview-perf-wiring.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# 用文件系统枚举，不用 git ls-files：新文件还没 add 时会被静默跳过。
SWIFT_FILES=$(find Sources/SrtFlow -name '*.swift' -type f | sort)
fail=0

# 下一行必须是 <want> 的开头行（awk：逐文件记住「上一行是开头」）。
# $1 开头行的正则，$2 下一行必须完全匹配的正则，$3 人话
next_line_must_be() {
  local label="$3" bad
  # 正则走环境变量传进 awk：`awk -v` 会先处理反斜杠转义，`\(` 变成 `(`，正则就错了。
  # shellcheck disable=SC2086
  bad=$(OPENER="$1" WANT="$2" awk '
    FNR == 1 { expect = 0 }
    expect {
      if ($0 !~ ENVIRON["WANT"]) printf "    %s:%d\n", FILENAME, FNR - 1
      expect = 0
    }
    $0 ~ ENVIRON["OPENER"] && $0 !~ /^[[:space:]]*\/\// { expect = 1 }
  ' $SWIFT_FILES)
  if [ -n "${bad}" ]; then
    echo "✗ ${label}，这几处下一行不是计数："
    printf '%s\n' "${bad}"
    fail=1
  fi
}

# 数某个正则在全部文件里的匹配行数（去掉注释行）。
count_lines() {
  # shellcheck disable=SC2086
  { grep -hE "$1" $SWIFT_FILES || true; } | { grep -vE '^[[:space:]]*//' || true; } | wc -l | tr -d ' '
}

BODY_OPENER='^[[:space:]]+var body: some View \{$'
MODIFIER_OPENER='^[[:space:]]+func body\(content: Content\) -> some View \{$'
UPDATE_OPENER='^[[:space:]]+func updateNSView\(.*\) \{$'
# 以 Canvas 开头的闭包：前面不许紧挨标识符字符（ShapeOverlayCanvas( 那种是视图名，不算）。
CANVAS_OPENER='(^|[^A-Za-z0-9_])Canvas[ ]?[({]'

echo "==> body 第一行是计数"
next_line_must_be "$BODY_OPENER" '^[[:space:]]+let _ = PerfCounters\.body\(Self\.self\)$' "视图 body"
next_line_must_be "$MODIFIER_OPENER" '^[[:space:]]+let _ = PerfCounters\.body\(Self\.self\)$' "修饰器 body"
next_line_must_be "$UPDATE_OPENER" '^[[:space:]]+PerfCounters\.update\(Self\.self\)$' "updateNSView"
next_line_must_be "$CANVAS_OPENER" '^[[:space:]]+PerfCounters\.canvas\(Self\.self\)$' "Canvas 绘制闭包"

echo "==> 视图个数和标准 body 个数对得上"
VIEW_DECL='^(private |fileprivate )?struct [A-Za-z0-9_]+(<[^>]*>)?: ([A-Za-z0-9_.]+, )*View([ ,{]|$)'
MODIFIER_DECL='^(private |fileprivate )?struct [A-Za-z0-9_]+(<[^>]*>)?: ([A-Za-z0-9_.]+, )*ViewModifier([ ,{]|$)'
REPRESENTABLE_DECL='^(private |fileprivate )?struct [A-Za-z0-9_]+(<[^>]*>)?: ([A-Za-z0-9_.]+, )*NSViewRepresentable([ ,{]|$)'
views=$(count_lines "$VIEW_DECL")
modifiers=$(count_lines "$MODIFIER_DECL")
representables=$(count_lines "$REPRESENTABLE_DECL")
bodies=$(count_lines "$BODY_OPENER")
modifier_bodies=$(count_lines "$MODIFIER_OPENER")
updates=$(count_lines "$UPDATE_OPENER")
# 扫了个空（路径、写法全变了）也是绿的 —— 先钉一个下限。
if [ "${views}" -lt 50 ]; then
  echo "✗ 只扫到 ${views} 个视图，守卫多半扫空了（Sources/SrtFlow 里应该有 90 个上下）"
  fail=1
fi
if [ "${views}" != "${bodies}" ]; then
  echo "✗ 有 ${views} 个视图，标准写法的 body（var body: some View {）只有 ${bodies} 个："
  echo "  有视图的 body 换了写法（写成一行？），第一条扫不到它。请写成标准形式。"
  fail=1
fi
if [ "${modifiers}" != "${modifier_bodies}" ]; then
  echo "✗ 有 ${modifiers} 个修饰器，标准写法的 body（func body(content: Content) -> some View {）只有 ${modifier_bodies} 个"
  fail=1
fi
if [ "${representables}" != "${updates}" ]; then
  echo "✗ 有 ${representables} 个 NSViewRepresentable，标准写法的 updateNSView 只有 ${updates} 个"
  fail=1
fi
echo "    视图 ${views}、修饰器 ${modifiers}、NSViewRepresentable ${representables}"

echo "==> 视图不重名"
# shellcheck disable=SC2086
dupes=$({ grep -hE "$VIEW_DECL|$MODIFIER_DECL|$REPRESENTABLE_DECL" $SWIFT_FILES || true; } \
  | sed -E 's/^(private |fileprivate )?struct ([A-Za-z0-9_]+).*/\2/' | sort | uniq -d)
if [ -n "${dupes}" ]; then
  echo "✗ 这几个视图重名了（计数按类型名记账，会串成一笔）：${dupes}"
  fail=1
fi

echo "==> 非视图的埋点和测试入口"
need() {   # need <文件> <正则> <人话>
  if [ ! -f "$1" ]; then echo "✗ 文件不在：$1"; fail=1; return; fi
  if ! grep -cE "$2" "$1" >/dev/null; then
    echo "✗ $1 少了 $3（模式 /$2/）"
    fail=1
  fi
}
need Sources/SrtFlow/VideoPreviewView.swift 'self\?\.observePlaybackTime\(cmTime\.seconds\)' '播放器的时间回调走 observePlaybackTime（测试的时钟连跳也走它）'
need Sources/SrtFlow/VideoPreviewView.swift 'PerfCounters\.event\(\.clockTick\)' '时钟每跳一下的计数'
need Sources/SrtFlow/VideoPreviewView.swift 'PerfCounters\.event\(\.playerItemAttach\)' '换播放条目的计数'
need Sources/SrtFlow/VideoEditCompositionBuilder.swift 'PerfCounters\.event\(\.compositionBuild\)' '建合成的计数'
need Sources/SrtFlow/VideoEditCompositionBuilder.swift 'PerfCounters\.event\(\.compositionAssetOpen\)' '开素材文件的计数'
need Sources/SrtFlow/VideoEditAudioMeter.swift 'PerfCounters\.event\(\.meterTapCreate\)' '新建电平表 tap 的计数'
need Sources/SrtFlow/VideoEditProject.swift 'PerfCounters\.event\(\.audioMixRefresh\)' 'audioMix 快路径的计数'
need Sources/SrtFlow/VideoEditView.swift 'PreviewBench\.startIfRequested\(project: project\)' '编辑器出现时启动性能测试的入口'
# 后台读媒体的起止：少了它，测试会在缩略图 / 波形还没读完时就开始量，数时有时无。
need Sources/SrtFlow/VideoEditTimelineThumbnails.swift 'PerfCounters\.backgroundReadBegan\(\)' '缩略图开始取图的登记'
need Sources/SrtFlow/VideoEditTimelineThumbnails.swift 'PerfCounters\.backgroundReadEnded\(\)' '缩略图取完的登记'
need Sources/SrtFlow/VideoEditWaveformData.swift 'PerfCounters\.backgroundReadBegan\(\)' '波形开始解码的登记'
need Sources/SrtFlow/VideoEditWaveformData.swift 'PerfCounters\.backgroundReadEnded\(\)' '波形解码完的登记'

if [ "${fail}" -eq 0 ]; then
  echo "✓ 预览性能计数全部接上"
  echo "All checks passed"
else
  echo
  echo "规矩见 docs/architecture/preview-perf-ratchet.md「计数必须接满」。"
  exit 1
fi
