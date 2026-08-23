#!/usr/bin/env bash
# 扫描守卫：字幕文本编辑期间，编辑器的全局快捷键必须让路。
#
# 视频剪辑栏挂着一个 local keyDown monitor（空格/V/A/B/M/⌫），它跑在事件分发
# 之前。「第一响应者是 NSTextView」判不住所有正在打字的时刻：多行 TextField +
# 中文输入法下第一响应者会偶发丢掉，用户还在字幕输入框里退格删字，⌫ 就落进
# 快捷键，把正在编辑的 cue 整条从两条轨上删掉。字幕草稿（project.subtitleDraft）
# 在进入输入框时打开、提交（回车/失焦）时清空，是「正在编辑字幕文本」的唯一
# 可靠判据 —— handleEvent 必须在分发任何快捷键之前先问它。
#
# 焦点丢失本身自动化够不着（要真窗口 + 输入法），手感项在
# docs/architecture/subtitle-track-visibility-and-layout.md 的人肉回归清单里。
# 背景见 docs/bugfixes/2026-08-22-subtitle-editing-backspace-deletes-cue.md。
set -euo pipefail
cd "$(dirname "$0")/.."

VIEW="Sources/SrtFlow/VideoEditView.swift"
FAILED=0

fail() {
  echo "✗ $1" >&2
  FAILED=1
}

# 取一个方法的函数体（签名行 → 第一条 4 空格缩进的收尾大括号）。
extract_func() {
  awk -v pat="$1" '
    index($0, pat) { inside = 1 }
    inside { print }
    inside && /^    \}$/ { exit }
  ' "$2"
}

BODY="$(extract_func 'private func handleEvent' "$VIEW")"
if [ -z "$BODY" ]; then
  fail "找不到 handleEvent（在 ${VIEW}），守卫失去目标 —— 改名了就同步改这里"
else
  printf '%s\n' "$BODY" | grep -q 'subtitleDraft != nil { return event }' \
    || fail "handleEvent 没有在快捷键分发前给字幕草稿让路：焦点丢失的那一拍，⌫ 会把正在编辑的 cue 从轨上删掉"
  # 让路必须排在 ⌫ 分支之前 —— 草稿判据放在 keyCode 判断后面等于没判。
  DRAFT_LINE="$(printf '%s\n' "$BODY" | grep -n 'subtitleDraft != nil' | head -1 | cut -d: -f1 || true)"
  DELETE_LINE="$(printf '%s\n' "$BODY" | grep -n 'keyCode == 51' | head -1 | cut -d: -f1 || true)"
  if [ -n "${DRAFT_LINE}" ] && [ -n "${DELETE_LINE}" ] && [ "${DRAFT_LINE}" -gt "${DELETE_LINE}" ]; then
    fail "字幕草稿的让路排在 ⌫ 分支之后：删除仍然抢在编辑前面"
  fi
fi

# ⌫ 的第二条路：monitor 放行后，系统会把它解释成 delete command 沿响应链送到
# .onDeleteCommand —— 只堵 monitor 那条等于没堵。两条路必须同一条纪律。
CMD_BODY="$(awk '/\.onDeleteCommand/{inside=1} inside{print} inside&&/\}$/{if(NR>start&&inside>0){exit}}' "$VIEW" | head -6)"
if ! grep -q 'onDeleteCommand' "$VIEW"; then
  fail "找不到 .onDeleteCommand（在 ${VIEW}），守卫失去目标 —— 改名了就同步改这里"
else
  printf '%s\n' "$CMD_BODY" | grep -q 'subtitleDraft == nil' \
    || fail ".onDeleteCommand 没有给字幕草稿让路：⌫ 会从这条路把正在编辑的 cue 删掉"
fi

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi
echo "✓ subtitle-editing-wiring：字幕草稿开着时全局快捷键让路（⌫ 不删正在编辑的 cue）"
