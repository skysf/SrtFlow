#!/usr/bin/env bash
# 扫描守卫：时间线复制 / 剪切 / 粘贴的接线（2026-09-26 用户拍板，docs/plans/2026-09-26-timeline-clipboard-and-zoom.md）。
#
# 拿什么、粘到哪是纯值，由 scripts/check-timeline-clipboard.sh 钉；这里钉自检编不动的那一半：
# 编辑菜单的三项接到哪、五种块和轨道空白处的右键菜单、落点鼠标优先（含 Finder 文件的 ⌘V）、
# 标尺不算「在轨道上」、剪贴板只有一套且不写纯文本。长期约束见 docs/architecture/timeline-clipboard.md。
#
# 用法：checks/timeline-clipboard-wiring.sh
set -uo pipefail
cd "$(dirname "$0")/.."

APP="Sources/SrtFlow/SrtFlowApp.swift"
CLIPBOARD="Sources/SrtFlow/VideoEditTimelineClipboard.swift"
POINTER="Sources/SrtFlow/VideoEditTimelinePointer.swift"
PINCH="Sources/SrtFlow/VideoEditTimelinePinchZoom.swift"
VIEW="Sources/SrtFlow/VideoEditTimelineView.swift"
FILE_DROP="Sources/SrtFlow/VideoEditMediaFileDrop.swift"
CLIP_BLOCK="Sources/SrtFlow/VideoEditTimelineClipBlock.swift"
FAILED=0

fail() {
  echo "✗ $1" >&2
  FAILED=1
}

# 只看真代码行（注释里写了同一串不算接上了）。
grep_code() {
  grep -n "$1" "$2" | grep -vE '^[0-9]+:[[:space:]]*//' | grep -c . >/dev/null
}

for f in "$APP" "$CLIPBOARD" "$POINTER" "$PINCH" "$VIEW" "$FILE_DROP" "$CLIP_BLOCK"; do
  [ -f "$f" ] || fail "找不到 ${f}：文件挪走了，这条守卫会扫个空 —— 同步改这里"
done

# ── 1. 编辑菜单的三项（响应链的最末端：输入框里的 ⌘C 还是复制文字） ───────────
grep_code 'VideoEditProject.shared.copySelection()' "$APP" || fail "⌘C 没接到 copySelection（时间线上的东西拷不了）"
grep_code 'VideoEditProject.shared.cutSelection()' "$APP" || fail "⌘X 没接到 cutSelection"
grep_code 'VideoEditProject.shared.pasteTimelineItems(at: .keyboard)' "$APP" \
  || fail "⌘V 没接到 pasteTimelineItems(at: .keyboard)（鼠标优先、否则播放头）"
grep_code 'VideoEditProject.shared.canCopySelection' "$APP" \
  || fail "编辑菜单里拷贝 / 剪切的亮灭没看 canCopySelection：要么点了没反应，要么明明能拷却是灰的"
grep_code 'TimelineClipboard.hasContent ||' "$APP" \
  || fail "编辑菜单里粘贴的亮灭没看时间线的剪贴板"

# ── 2. 剪贴板只有一套，不写纯文本 ─────────────────────────────────────────────
if grep -rn 'FilterClipboard\|com\.srtflow\.filter-clip' Sources packaging --include='*.swift' --include='*.plist' \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' | grep -c . >/dev/null; then
  fail "滤镜那套剪贴板又回来了：同一件事两份剪贴板，迟早有人读错（并进了 TimelineClipboard）"
fi
grep_code 'setString(' "$CLIPBOARD" \
  && fail "时间线的剪贴板写了纯文本：复制一段剪辑会把用户剪贴板里的字换成一串 JSON"

# ── 3. 右键菜单：五种块各有「剪切 / 拷贝 / 粘贴」，轨道空白处有「粘贴」 ───────────
grep_code 'TimelineClipboardMenu.items { project.runClipboardCommand($0, on: .clip(clip.id)) }' "$CLIP_BLOCK" \
  || fail "剪辑块的右键菜单没有剪切 / 拷贝 / 粘贴"
for pair in \
  "VideoEditTimelineShapeRow.swift:shape(shape.id)" \
  "VideoEditTimelineTextRow.swift:text(overlay.id)" \
  "VideoEditTimelineFilterRow.swift:filter(filter.id)" \
  "VideoEditTimelineSubtitleRow.swift:cue(cue.id)"; do
  file="Sources/SrtFlow/${pair%%:*}"
  ref="${pair#*:}"
  grep_code "onClipboard: { project.runClipboardCommand(\$0, on: .${ref}) }" "$file" \
    || fail "${file} 没把右键菜单的剪切 / 拷贝 / 粘贴接到 runClipboardCommand（.${ref}）"
done
for file in Sources/SrtFlow/VideoEditTimelineShapeRow.swift Sources/SrtFlow/VideoEditTimelineTextRow.swift \
  Sources/SrtFlow/VideoEditTimelineFilterRow.swift Sources/SrtFlow/VideoEditTimelineSubtitleCueBlock.swift; do
  grep_code 'TimelineClipboardMenu.items(onClipboard)' "$file" || fail "${file} 的右键菜单里没有剪切 / 拷贝 / 粘贴"
done
grep_code 'TimelineClipboardMenu.pasteOnly { project.pasteFromContextMenu() }' "$VIEW" \
  || fail "轨道空白处的右键菜单没有「粘贴」"
# 右键菜单里的粘贴落在右键按下的那一处：时间线的事件监视器得记下那一处。
grep_code 'TimelineContextClick.note(event)' "$PINCH" \
  || fail "右键按在哪没人记：右键菜单里的粘贴只能退回播放头"

# ── 4. 落点：鼠标优先、否则播放头；标尺不算「在轨道上」 ─────────────────────────
grep_code 'TimelinePointer.hit(site == .contextMenu ? .contextClick : .now, project: self)' "$CLIPBOARD" \
  || fail "粘贴的落点没问指针（TimelinePointer.hit）：鼠标停在轨道上也会落到播放头"
grep_code 'let hit = TimelinePointer.hit(.now, project: self)' "$FILE_DROP" \
  || fail "Finder 文件的 ⌘V 没改成鼠标优先（和时间线内容的 ⌘V 各走各的规则了）"
grep_code 'location.viewport.y) < ruler.maxY' "$POINTER" \
  || fail "指针落在钉住的标尺上也算「在轨道上」了：粘贴会落在标尺那个时刻而不是播放头"

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi
echo "✓ timeline-clipboard-wiring：编辑菜单三项 / 剪贴板只有一套且不写纯文本 / 五种块和轨道空白处的右键菜单 / 右键按在哪有人记 / 落点鼠标优先（含 Finder 文件）/ 标尺不算轨道"
