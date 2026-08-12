#!/usr/bin/env bash
# 工程文件（.srtflowproj）存盘与素材重链接的自检，外加两块同样编得动的
# 纯值合同：字幕生成的「可听快照 / 探针来源」（SubtitleAudibleClips）与
# 三类选择的互斥（EditSelection）。
#
# 需要 ffmpeg：探针那组要现造「真的没有音轨的 mp4」+「真有声音的 m4a」，
# 假文件（重复字节）过不了真实解码，测不出「文件存在 ≠ 音轨可读」。
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
  Sources/SrtFlow/VideoEditAudioFade.swift \
  Sources/SrtFlow/VideoEditSubtitleDocuments.swift \
  Sources/SrtFlow/VideoEditAnimation.swift \
  Sources/SrtFlow/VideoEditClipMarker.swift \
  Sources/SrtFlow/VideoEditTimelineEdits.swift \
  Sources/SrtFlow/VideoEditTimelineSnap.swift \
  Sources/SrtFlow/VideoEditFormatVersion.swift \
  Sources/SrtFlow/VideoEditProjectFile.swift \
  Sources/SrtFlow/VideoEditSelection.swift \
  Sources/SrtFlow/SubtitleGen/SubtitleAudibleClips.swift \
  Sources/SrtFlow/SubtitleGen/AudioWindowReader.swift \
  Sources/SrtFlow/SubtitleGen/TranscriptSidecarStore.swift \
  Sources/SrtFlow/MediaProbe.swift \
  Sources/SrtFlow/StillImageClipFactory.swift \
  Sources/SrtFlow/AppLanguage.swift \
  checks/ProjectFile/main.swift \
  "$BUILD_DIR"/SrtFlowCore.build/*.o

# ---- 真实媒体素材（探针「文件存在 ≠ 音轨可读」那一组要用）----
#
# 假文件（重复字节）过不了真实解码，测不出这个回归，所以这里现造两个真素材：
# 一个**没有音轨**的 mp4 和一段真的有声音的 m4a。
# 需要真跑 ffmpeg 的自检**不允许静默跳过**（跳过 = 假绿），没有就明确失败。
FFMPEG_BIN="${SRTFLOW_FFMPEG:-$(pwd)/vendor/ffmpeg}"
if [ ! -x "${FFMPEG_BIN}" ]; then
  echo "✗ 找不到可执行的 ffmpeg：${FFMPEG_BIN}" >&2
  echo "  先运行 scripts/vendor-ffmpeg.sh，或用 SRTFLOW_FFMPEG= 指定一份。" >&2
  exit 1
fi
MEDIA_DIR="$(dirname "$OUT")/media"
mkdir -p "$MEDIA_DIR"
echo "==> 现造真实媒体素材"
"${FFMPEG_BIN}" -y -loglevel error \
  -f lavfi -i "testsrc2=size=320x180:rate=15:duration=5" \
  -an -c:v h264_videotoolbox -pix_fmt yuv420p "$MEDIA_DIR/silent-no-audio.mp4"
"${FFMPEG_BIN}" -y -loglevel error \
  -f lavfi -i "sine=frequency=440:duration=5" \
  -c:a aac "$MEDIA_DIR/real-voice.m4a"
# 验明正身：第一个真的没有音轨，第二个真的有。
# `ffmpeg -i` 不给输出文件时**退出码是 1**，而本脚本开着 pipefail ——
# 直接写 `ffmpeg ... | grep -q` 会被 ffmpeg 的退出码判成「没匹配到」，
# 两条判断都会得出错误结论（2026-08-06 shell 陷阱案例同款）。先取回文本再判。
SILENT_INFO="$("${FFMPEG_BIN}" -hide_banner -i "$MEDIA_DIR/silent-no-audio.mp4" 2>&1 || true)"
VOICE_INFO="$("${FFMPEG_BIN}" -hide_banner -i "$MEDIA_DIR/real-voice.m4a" 2>&1 || true)"
case "${SILENT_INFO}" in
  *"Audio:"*) echo "✗ silent-no-audio.mp4 竟然带音轨，素材没造对" >&2; exit 1 ;;
esac
case "${VOICE_INFO}" in
  *"Audio:"*) ;;
  *) echo "✗ real-voice.m4a 没有音轨，素材没造对" >&2; exit 1 ;;
esac
export SRTFLOW_CHECK_MEDIA="$MEDIA_DIR"

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
require "切工程必须四类选择一起清" \
  Sources/SrtFlow/VideoEditProjectDocument.swift 'clearSelection\(\)'

# 标记（2026-08-09）：纯值合同在上面断言过了，这里钉住它在生产里的接线。
require "state 的 didSet 要摘掉失效的标记选择" \
  Sources/SrtFlow/VideoEditProject.swift 'pruneMarkerSelection\(\)'
require "⌫ 必须经统一删除入口认标记（不许另开一条删除路径）" \
  Sources/SrtFlow/VideoEditProject.swift 'if let ref = selectedMarkerRef'
# 判据必须问 `EditSelection` 自己（它认全四类，含框选来的混选），别在视图里
# 重列一遍类别 —— 重列的那份每加一类就会漏一处，历史上就是这么漏的。
require "⌫ 的按键守卫要问 EditSelection 自己（放行「只选中了标记」等全部情况）" \
  Sources/SrtFlow/VideoEditView.swift 'guard !project\.selection\.isEmpty'
require "M 必须接上打标记" \
  Sources/SrtFlow/VideoEditView.swift 'addMarkerAtPlayhead\(\)'
require "工具栏垃圾桶的置灰判据必须和 ⌫ 是同一个表达式" \
  Sources/SrtFlow/VideoEditView.swift '\.disabled\(project\.selection\.isEmpty\)'
# 按钮亮不亮和真正会打在哪几段，必须是同一个函数算出来的。
require "工具栏书签按钮的置灰走 canAddMarker" \
  Sources/SrtFlow/VideoEditView.swift 'project\.canAddMarker'
require "canAddMarker 与打标记共用同一份落点判据" \
  Sources/SrtFlow/VideoEditProject+Markers.swift \
  'var canAddMarker: Bool \{ !markerTargetsAtPlayhead\(\)\.isEmpty \}'
require "剪辑块要真的画出标记条" \
  Sources/SrtFlow/VideoEditTimelineView.swift 'ClipMarkerStrip\('
# 标记的帽子是可命中的子视图，指针一进去块自己的 onContinuousHover 立刻收到
# .ended。没有这道让位，鼠标一碰标记画面就弹回播放头（扫帧 peek 被掐断）。
require "扫帧 peek 要给标记让位" \
  Sources/SrtFlow/VideoEditTimelineView.swift 'guard markerHoverTime == nil else'
# 标记纯属编辑期标注：进了合成/导出就等于把它烧进成片。
forbid "标记不许进预览合成" \
  Sources/SrtFlow/VideoEditCompositionBuilder.swift '\.markers'
forbid "标记不许进导出" \
  Sources/SrtFlow/VideoEditExporter.swift '\.markers'
# 改标记不该重建预览（画面一帧都不会变，白付一次 AVComposition 重搭）。
if grep -Eq 'perform \{' Sources/SrtFlow/VideoEditProject+Markers.swift; then
  echo "✗ 接线守卫：标记的写入必须走 perform(rebuildsPreview: false)" >&2
  WIRING_FAIL=1
fi

# 一个语言一条轨：显示/烧录只能由两只眼睛推导，不许再有第二套模式选择。
forbid "预览轨道模式选择器已删除，不许复活" \
  Sources/SrtFlow/VideoEditView.swift 'subtitlePreviewTrack'
forbid "面板不许再有 Preview track 选择器" \
  Sources/SrtFlow/SubtitleGen/SubtitleGenPanel.swift 'subtitlePreviewTrack'
forbid "旧的按选择取可见文档的入口已废弃（会绕开眼睛推导）" \
  Sources/SrtFlow/VideoEditView.swift 'visibleSubtitleDocument\(for:'
require "预览必须走两只眼睛推导出的合同" \
  Sources/SrtFlow/VideoEditView.swift 'visibleSubtitleDocument\(\)'
require "烧录必须与预览同一份合同（眼睛说了算）" \
  Sources/SrtFlow/SubtitleGen/SubtitleExportSection.swift 'state\.visibleSubtitleDocument\(\)'
forbid "导出面板不许再自己选烧哪条轨" \
  Sources/SrtFlow/SubtitleGen/SubtitleExportSection.swift 'enum Burn'
require "时间线要给译文轨一只自己的眼睛" \
  Sources/SrtFlow/VideoEditTimelineView.swift 'toggleTranslationHidden\(\)'

# 自动检测：metadata 只许消费冻结的可听快照，探针也从同一份里挑。
require "detectSourceLocale 必须走 selectProbe（真抽一次才算定下探针）" \
  Sources/SrtFlow/SubtitleGen/TranscriptionTask.swift \
  'SubtitleAudibleClips\.selectProbe\('
require "生产抽取器必须真接上 AudioWindowReader" \
  Sources/SrtFlow/SubtitleGen/TranscriptionTask.swift \
  'AudioWindowReader\.extract\('
# selectProbe 自己也要拿到任务的取消通道 —— 只靠抽取器内部那道，
# 无音轨素材在检查之前就抛 ReadError，取消会被跳过逻辑吞成「素材都读不了」。
if ! grep -A2 'SubtitleAudibleClips\.selectProbe(' \
      Sources/SrtFlow/SubtitleGen/TranscriptionTask.swift \
      | grep -q 'isCancelled: { token.isCancelled }'; then
  echo "✗ 接线守卫：selectProbe 必须收到 token 的取消通道" >&2
  WIRING_FAIL=1
fi
require "metadata 顺序必须以选定的探针为首" \
  Sources/SrtFlow/SubtitleGen/TranscriptionTask.swift \
  'SubtitleAudibleClips\.metadataOrder\(in: clips, probe:'
require "metadata 查询必须吃 [SoundClip] 快照" \
  Sources/SrtFlow/SubtitleGen/TranscriptionTask.swift \
  'metadataLanguageTag\(in clips: \[SoundClip\]\)'
forbid "metadata 不许再从 TimelineState 自己枚举素材" \
  Sources/SrtFlow/SubtitleGen/TranscriptionTask.swift \
  'state\.mainClips \+ state\.audioTracks'
forbid "Auto-detect 不许留「单候选直接采用」的无证据捷径" \
  Sources/SrtFlow/SubtitleGen/TranscriptionTask.swift \
  'candidates\.count == 1'
require "候选去重必须走按语言的 selectCandidates" \
  Sources/SrtFlow/SubtitleGen/TranscriptionTask.swift \
  'SubtitleLanguageDetection\.selectCandidates\('
forbid "候选不许再按 locale 标识符自己去重截断（同语言变体会吃光名额）" \
  Sources/SrtFlow/SubtitleGen/TranscriptionTask.swift \
  'candidates\.count < 3'
require "已装语言那一档必须排序（系统返回顺序实测会变）" \
  Sources/SrtFlow/SubtitleGen/TranscriptionTask.swift \
  'installed\.map\(\\\.identifier\)\.sorted\(\)'

# 可听性只有一份合同：快照判「有没有声音」只能用 EditClip.hasAudio。
require "可听快照必须用 clip.hasAudio" \
  Sources/SrtFlow/SubtitleGen/SubtitleAudibleClips.swift 'guard clip\.hasAudio else'
forbid "不许再把 info == nil 当成「有声音」" \
  Sources/SrtFlow/SubtitleGen/SubtitleAudibleClips.swift 'if let info = clip\.info, !info\.hasAudio'

# 同语种判据只有一份：TranslationPreflight 委托到 Core，不许自己再写一遍。
require "TranslationPreflight 必须委托 Core 的 languageKey" \
  Sources/SrtFlow/SubtitleGen/TranslationPreflight.swift \
  'SubtitleLanguageDetection\.languageKey\(of:'
forbid "TranslationPreflight 不许自己再实现一套 maximal 比较" \
  Sources/SrtFlow/SubtitleGen/TranslationPreflight.swift 'maximalIdentifier'

# 翻译任务的 configuration 必须换代：同样语言直接新建，两次配置完全相等，
# .translationTask 就不重跑 action，continuation 永久悬挂（面板停在 0/N）。
require "coordinator 必须经发放器取 configuration" \
  Sources/SrtFlow/SubtitleGen/TranslationHost.swift \
  'configurations\.next\(source:'
forbid "coordinator 不许自己新建 configuration（会与上一次完全相等）" \
  Sources/SrtFlow/SubtitleGen/TranslationHost.swift \
  'TranslationSession\.Configuration\(source:'
require "发布 pendingJob 之后必须装起跑看门狗（没人收尾就如实报错）" \
  Sources/SrtFlow/SubtitleGen/TranslationHost.swift 'armStartWatchdog\('

if [ "$WIRING_FAIL" -ne 0 ]; then
  echo "接线守卫失败" >&2
  exit 1
fi
echo "✓ 接线守卫通过"
