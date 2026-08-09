#!/usr/bin/env bash
# 工程文件（.srtflowproj）存盘与素材重链接的自检，外加两块同样编得动的
# 纯值合同：字幕生成的「可听快照 / 探针来源」（SubtitleAudibleClips）与
# 三类选择的互斥（EditSelection）。
#
# 用法：
#   scripts/check-project-file.sh
#
# 为什么是个脚本而不是 SwiftPM 的 target：
#   被测的代码（VideoEditProjectFile / VideoEditModels）在 SrtFlow 这个 app
#   target 里，SwiftPM 不允许两个 target 共用同一批源文件，所以这里直接把需要
#   的几个文件和 checks/ProjectFile/main.swift 编成一个独立二进制来跑。
#   核心库（SrtFlowCore）那部分的自检在 `swift run SrtFlowCoreChecks`。
set -euo pipefail
cd "$(dirname "$0")/.."

# Rosetta 终端下必须显式指定 arm64，否则会去编 x86_64（见 docs/build/）。
ARCH_FLAG="--arch arm64"
TRIPLE="arm64-apple-macosx15.0"

echo "==> swift build ${ARCH_FLAG}（拿 SrtFlowCore 的模块和目标文件）"
# SwiftPM 的编译诊断走 stdout：静默成功可以，失败必须倾倒完整输出
#（>/dev/null 会把编译错误吞成无字天书，见 docs/bugfixes/ 2026-08-08 CI 首跑案例）。
BUILD_OUT="$(swift build ${ARCH_FLAG} 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_DIR="$(swift build ${ARCH_FLAG} --show-bin-path)"

OUT="$(mktemp -d)/projcheck"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

echo "==> 编译自检二进制"
xcrun swiftc \
  -target "$TRIPLE" \
  -I "$BUILD_DIR/Modules" \
  -o "$OUT" \
  Sources/SrtFlow/VideoEditModels.swift \
  Sources/SrtFlow/VideoEditSubtitleDocuments.swift \
  Sources/SrtFlow/VideoEditAnimation.swift \
  Sources/SrtFlow/VideoEditTimelineEdits.swift \
  Sources/SrtFlow/VideoEditFormatVersion.swift \
  Sources/SrtFlow/VideoEditProjectFile.swift \
  Sources/SrtFlow/VideoEditSelection.swift \
  Sources/SrtFlow/SubtitleGen/SubtitleAudibleClips.swift \
  Sources/SrtFlow/SubtitleGen/TranscriptSidecarStore.swift \
  Sources/SrtFlow/MediaProbe.swift \
  Sources/SrtFlow/StillImageClipFactory.swift \
  Sources/SrtFlow/AppLanguage.swift \
  checks/ProjectFile/main.swift \
  "$BUILD_DIR"/SrtFlowCore.build/*.o

echo "==> 运行"
"$OUT"

# ---- 扫描守卫：纯值合同必须真的被生产代码调用 ----
#
# 上面那批断言只证明「函数算得对」；VideoEditProject / TranscriptionTask 是
# @MainActor 的 App 类型，自检编不动它们，所以「有没有被调用、参数对不对」
# 只能在源码层面钉住。这正是 2026-08-07 Phase 2–4 那轮的病根
#（canClearManifest 写对了却一次没被调用）。
# 不单开一个 check-all 条目 —— 它守的就是本脚本这批合同的接线。
echo "==> 扫描守卫：生产接线"
WIRING_FAIL=0
require() { # require <描述> <文件> <正则>
  if ! grep -Eq "$3" "$2"; then
    echo "✗ 接线守卫：$1（在 $2 里找不到 /$3/）" >&2
    WIRING_FAIL=1
  fi
}
forbid() { # forbid <描述> <文件> <正则>
  if grep -Eq "$3" "$2"; then
    echo "✗ 接线守卫：$1（$2 里仍有 /$3/）" >&2
    WIRING_FAIL=1
  fi
}

# 选择互斥：三类选择只能有 EditSelection 一个真身，清理要接在生产入口上。
require "VideoEditProject 的选择必须由 EditSelection 持有" \
  Sources/SrtFlow/VideoEditProject.swift 'var selection = EditSelection\(\)'
require "state 的 didSet 要摘掉失效的字幕 cue 选择" \
  Sources/SrtFlow/VideoEditProject.swift 'pruneSubtitleCueSelection\(\)'
require "切工程必须三类选择一起清" \
  Sources/SrtFlow/VideoEditProjectDocument.swift 'clearSelection\(\)'

# 自动检测：metadata 只许消费冻结的可听快照，探针也从同一份里挑。
require "detectSourceLocale 必须从 SubtitleAudibleClips 取探针" \
  Sources/SrtFlow/SubtitleGen/TranscriptionTask.swift \
  'SubtitleAudibleClips\.detectionSources\(in:'
require "metadata 查询必须吃 [SoundClip] 快照" \
  Sources/SrtFlow/SubtitleGen/TranscriptionTask.swift \
  'metadataLanguageTag\(in clips: \[SoundClip\]\)'
forbid "metadata 不许再从 TimelineState 自己枚举素材" \
  Sources/SrtFlow/SubtitleGen/TranscriptionTask.swift \
  'state\.mainClips \+ state\.audioTracks'
forbid "Auto-detect 不许留「单候选直接采用」的无证据捷径" \
  Sources/SrtFlow/SubtitleGen/TranscriptionTask.swift \
  'candidates\.count == 1'

if [ "$WIRING_FAIL" -ne 0 ]; then
  echo "接线守卫失败" >&2
  exit 1
fi
echo "✓ 接线守卫通过"
