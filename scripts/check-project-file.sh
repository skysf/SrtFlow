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

echo "==> swift build ${ARCH_FLAG} --target SrtFlowCore（拿 SrtFlowCore 的模块和目标文件）"
# SwiftPM 的编译诊断走 stdout：静默成功可以，失败必须倾倒完整输出
#（>/dev/null 会把编译错误吞成无字天书，见 docs/bugfixes/ 2026-08-08 CI 首跑案例）。
BUILD_OUT="$(swift build ${ARCH_FLAG} --target SrtFlowCore 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_DIR="$(swift build ${ARCH_FLAG} --show-bin-path)"

OUT="$(mktemp -d)/projcheck"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

echo "==> 编译自检二进制"
xcrun swiftc \
  -target "$TRIPLE" \
  -wmo \
  -I "$BUILD_DIR/Modules" \
  -o "$OUT" \
  Sources/SrtFlow/VideoEditModels.swift \
  Sources/SrtFlow/VideoEditClipCrop.swift \
  Sources/SrtFlow/VideoEditShapeModels.swift \
  Sources/SrtFlow/VideoEditSoundScene.swift \
  Sources/SrtFlow/PerfCounters.swift \
  Sources/SrtFlow/VideoEditVolumeCurve.swift \
  Sources/SrtFlow/VideoEditFilterModels.swift \
  Sources/SrtFlow/VideoEditFilterLUT.swift \
  Sources/SrtFlow/VideoEditFadeWindow.swift \
  Sources/SrtFlow/VideoEditAudioFade.swift \
  Sources/SrtFlow/VideoEditVideoFade.swift \
  Sources/SrtFlow/VideoEditClipAnimation.swift \
  Sources/SrtFlow/VideoEditClipAnimator.swift \
  Sources/SrtFlow/VideoEditTrackPalette.swift \
  Sources/SrtFlow/VideoEditTextStyle.swift \
  Sources/SrtFlow/VideoEditTextEasing.swift \
  Sources/SrtFlow/VideoEditTextAnimation.swift \
  Sources/SrtFlow/VideoEditTextAnimator.swift \
  Sources/SrtFlow/VideoEditTextNumber.swift \
  Sources/SrtFlow/VideoEditTextOdometer.swift \
  Sources/SrtFlow/VideoEditTextNumberRenderer.swift \
  Sources/SrtFlow/VideoEditTextModels.swift \
  Sources/SrtFlow/VideoEditTextRows.swift \
  Sources/SrtFlow/VideoEditTextLayout.swift \
  Sources/SrtFlow/VideoEditTextRenderer.swift \
  Sources/SrtFlow/VideoEditTextDrawing.swift \
  Sources/SrtFlow/VideoEditTextExport.swift \
  Sources/SrtFlow/VideoEditSubtitleDocuments.swift \
  Sources/SrtFlow/VideoEditAnimation.swift \
  Sources/SrtFlow/VideoEditClipMarker.swift \
  Sources/SrtFlow/VideoEditTimelineEdits.swift \
  Sources/SrtFlow/VideoEditTimelineRowSelection.swift \
  Sources/SrtFlow/VideoEditClipVisibility.swift \
  Sources/SrtFlow/VideoEditTransitionHandles.swift \
  Sources/SrtFlow/VideoEditTimelineSnap.swift \
  Sources/SrtFlow/VideoEditTimelineRowHeights.swift \
  Sources/SrtFlow/VideoEditFormatVersion.swift \
  Sources/SrtFlow/VideoEditProjectFile.swift \
  Sources/SrtFlow/VideoEditMediaBookmarkCache.swift \
  Sources/SrtFlow/AudioLibraryCache.swift \
  Sources/SrtFlow/AudioLibraryManifest.swift \
  Sources/SrtFlow/VideoEditSelection.swift \
  Sources/SrtFlow/SubtitleGen/SubtitleAudibleClips.swift \
  Sources/SrtFlow/SubtitleGen/AudioWindowReader.swift \
  Sources/SrtFlow/SubtitleGen/TranscriptSidecarStore.swift \
  Sources/SrtFlow/MediaProbe.swift \
  Sources/SrtFlow/StillImageClipFactory.swift \
  Sources/SrtFlow/AppLanguage.swift \
  checks/ProjectFile/main.swift \
  checks/ProjectFile/VolumeCurve.swift \
  checks/ProjectFile/RowHeights.swift \
  checks/ProjectFile/SoundScene.swift \
  checks/ProjectFile/BookmarkCache.swift \
  checks/ProjectFile/NumberDelay.swift \
  checks/ProjectFile/TextRows.swift \
  checks/ProjectFile/SelectAll.swift \
  checks/ProjectFile/SplitGroups.swift \
  checks/ProjectFile/HiddenItems.swift \
  checks/ProjectFile/SubtitleTracks.swift \
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
# ⌘A 全选 / ⌘⇧A 取消（2026-09-25 用户拍板）：接在同一个本地监听里，且要在「带修饰键一律放行」
# 那道闸门之前；全选走框选的那一个混选入口（applyBoxSelection），滤镜也进框选。
require "⌘A 必须接上全选（selectAllOnTimeline）" \
  Sources/SrtFlow/VideoEditView.swift 'project\.selectAllOnTimeline\(\)'
require "⌘⇧A 必须接上取消选择" \
  Sources/SrtFlow/VideoEditView.swift 'modifiers == \[\.command, \.shift\]'
require "全选走框选那一个混选入口" \
  Sources/SrtFlow/VideoEditProject+Selection.swift 'applyBoxSelection\('
require "框选把滤镜段也交给选择" \
  Sources/SrtFlow/VideoEditTimelineMarqueeGesture.swift 'filters: session\.hit\.filters'
# 滤镜块的选中态 = 模型里的多选 + 拖框中的实时高亮。2026-09-25 起实时高亮不再经时间线的
# isSelected(filter:)，块自己从拖动盒子里收框选命中（五种块的收法都钉在
# checks/timeline-drag-wiring/drag-box.sh；这里只钉滤镜这一类还在多选、还看框）。
require "滤镜块的选中态走模型里的多选（selectedFilterIDs）" \
  Sources/SrtFlow/VideoEditTimelineFilterRow.swift 'isSelected: project\.selectedFilterIDs\.contains\(filter\.id\)'
require "滤镜块拖框中实时高亮（从拖动盒子里收框选命中的滤镜）" \
  Sources/SrtFlow/VideoEditTimelineFilterRow.swift '\$0\.filters\.contains\(filter\.id\)'
require "滤镜行的轨道头点得出整层" \
  Sources/SrtFlow/VideoEditTimelineRowSpec.swift 'return \.filterLayer\(filterLayer\)'
# 垃圾桶 2026-09-25 从根视图拆进了 SelectionToolbarButtons（根视图读选择 = 点选一段叫醒整个编辑器）。
require "工具栏垃圾桶的置灰判据必须和 ⌫ 是同一个表达式" \
  Sources/SrtFlow/VideoEditToolbarStateButtons.swift '\.disabled\(project\.selection\.isEmpty\)'
# 按钮亮不亮和真正会打在哪几段，必须是同一个函数算出来的。
require "工具栏书签按钮的置灰走 canAddMarker" \
  Sources/SrtFlow/VideoEditView.swift 'project\.canAddMarker'
require "canAddMarker 与打标记共用同一份落点判据" \
  Sources/SrtFlow/VideoEditProject+Markers.swift \
  'var canAddMarker: Bool \{ !markerTargetsAtPlayhead\(\)\.isEmpty \}'
require "剪辑块要真的画出标记条" \
  Sources/SrtFlow/VideoEditTimelineClipBlock.swift 'ClipMarkerStrip\('
# 标记的点击语义（2026-09-24 用户拍板）：单击只选中、双击才弹面板、右键有菜单。
# **单击不许弹面板**：面板一开，里面的备注框就成了第一响应者，⌫ 全进了输入框，标记怎么都
# 删不掉（docs/bugfixes/2026-09-24-marker-delete-key-eaten-by-note-field.md）。
MARKERS="Sources/SrtFlow/VideoEditTimelineMarkers.swift"
require "标记双击弹面板（count: 2 的手势在前）" "$MARKERS" '\.onTapGesture\(count: 2\)'
require "标记右键菜单（删除 / 换色 / 编辑备注）" "$MARKERS" '\.contextMenu \{'
SINGLE_TAP="$(awk '/^ *\.onTapGesture \{$/ { inside = 1; next } inside && /^ *\}$/ { exit } inside { print }' "$MARKERS")"
if [ -z "$SINGLE_TAP" ]; then
  echo "✗ 接线守卫：标记的单击手势（.onTapGesture {）不见了：单击选不中" >&2
  WIRING_FAIL=1
elif grep -c 'editing' <<<"$SINGLE_TAP" >/dev/null; then
  echo "✗ 接线守卫：标记单击又弹面板了（单击手势里出现了 editing）：备注框会把 ⌫ 吃掉" >&2
  WIRING_FAIL=1
fi
# 标记的帽子是可命中的子视图，但容器那圈 onContinuousHover 不会因为指针压在子视图
# 上就停发（2026-09-21 起扫帧 peek 的唯一所有者是时间线容器）。没有这道让位，
# 鼠标悬在标记上时容器下一拍就会把画面从标记那一帧拽回指针底下。
require "扫帧 peek 要给标记让位" \
  Sources/SrtFlow/VideoEditTimelineView.swift 'guard markerPeekTime == nil else'
# 块自己不许写 peek：两处都写 = 谁后到谁赢的竞态。它只把「悬着哪一枚」报上去。
require "剪辑块把标记悬停上报给容器" \
  Sources/SrtFlow/VideoEditTimelineClipBlock.swift 'onMarkerPeek\(time\)'
# 只禁「写」：`endPeek()` 是合法的 —— 裁切起手要把已经画出来的影子收掉，
# 容器那边的 guard 只能拦住「继续扫帧」，拦不住「已经亮着的那根线」。
forbid "剪辑块不许自己写 peek（所有者是时间线容器）" \
  Sources/SrtFlow/VideoEditTimelineClipBlock.swift '^[^/]*clock\.peek\(at:'
# 单段隐藏（V，2026-09-18 用户拍板）：两级隐藏的渲染语义是同一条，
# 预览和 ffmpeg 两条链路都得滤掉它 —— 漏一条就是「预览里没了、成片里还在」。
# 合同见 docs/architecture/clip-visibility.md。
require "预览合成的主轨要跳过单独隐藏的段" \
  Sources/SrtFlow/VideoEditCompositionBuilder.swift 'guard !state\.mainHidden, !clip\.isHidden'
require "预览合成的上层轨/音频轨要走 ClipVisibility.visible" \
  Sources/SrtFlow/VideoEditCompositionBuilder.swift 'ClipVisibility\.visible\('
require "任一侧被隐藏的接缝不许挂转场（否则预览淡进黑场、导出却是硬切）" \
  Sources/SrtFlow/VideoEditCompositionBuilder.swift 'guard !state\.mainClips\[index - 1\]\.isHidden'
require "ffmpeg 导出要滤掉隐藏的段" \
  Sources/SrtFlow/VideoEditExportGraph.swift 'ClipVisibility\.visible\('
# 上面那条只证明「文件里出现过」：主轨那一行就满足了，叠上层轨那一圈照样按轨去 lane.clips 里取段，
# 单段隐藏（V）漏进成片（2026-09-26 案例 hidden-upper-clip-still-exported）。真正的守卫是
# check-video-fade.sh 的真导出抽帧；这条只挡「又回到按轨取段」的写法。
forbid "ffmpeg 导出不许按轨去 lane.clips 里取段（走 overlayVisible 那一份清单）" \
  Sources/SrtFlow/VideoEditExportGraph.swift '^[^/]*in lane\.clips'
require "「只导出选中的」也要滤掉隐藏的段" \
  Sources/SrtFlow/VideoEditModels.swift 'ClipVisibility\.visible\(allClips'
require "V 键切的是选中的那几段" \
  Sources/SrtFlow/VideoEditView.swift 'toggleHiddenForSelection\(\)'
# 回到开头（Return / 小键盘 Enter / Home，2026-09-26）：按键在编辑器的监听里接、只认主窗口，
# 时间线只听专门的 wentToStart 滚回最左 —— 听 placed 的话，重建后放回播放头那一下也会把时间线拽走。
require "Return / Home 回到开头接在编辑器的按键监听上" \
  Sources/SrtFlow/VideoEditView.swift 'clock\.goToStart\(\)'
require "回到开头只认主窗口（sheet / 弹窗里的 Return 是它们的默认按钮）" \
  Sources/SrtFlow/VideoEditView.swift 'event\.window\?\.isMainWindow == true'
require "时间线听「回到开头」滚回最左" \
  Sources/SrtFlow/VideoEditTimelinePlayhead.swift 'onReceive\(clock\.wentToStart\)'
forbid "时间线不许听 placed 去滚（重建之后放回播放头也发 placed）" \
  Sources/SrtFlow/VideoEditTimelinePlayhead.swift 'onReceive\(clock\.placed\)'
forbid "V 不许再切整轨（整轨显隐只剩轨道头那只眼睛一个入口）" \
  Sources/SrtFlow/VideoEditView.swift 'toggleHiddenForSelectionLane'
require "V 的切换规则必须走纯值 ClipVisibility.nextHidden" \
  Sources/SrtFlow/VideoEditProject.swift 'ClipVisibility\.nextHidden\('
require "链接开着时 V 连带分离出来的音频一起切" \
  Sources/SrtFlow/VideoEditProject.swift 'if linkageEnabled \{'
require "定格不给隐藏的段（它在预览和成片里都不存在）" \
  Sources/SrtFlow/VideoEditFreezeFrame.swift '!clip\.isHidden'
# 灰显只有一份实现（`timelineHiddenLook`，剪辑块那个文件里）：四种块都用它，2026-09-26 起文字 / 形状 / 滤镜也能藏。
require "单个隐藏的灰显只有一处实现" \
  Sources/SrtFlow/VideoEditTimelineClipBlock.swift 'opacity\(hidden \? 0\.4 : 1\)'
require "藏起来的剪辑在时间线上要灰显（否则看不出它不会进成片）" \
  Sources/SrtFlow/VideoEditTimelineClipBlock.swift 'timelineHiddenLook\(clip\.isHidden\)'
require "藏起来的文字块要灰显" \
  Sources/SrtFlow/VideoEditTimelineTextRow.swift 'timelineHiddenLook\(overlay\.isHidden\)'
require "藏起来的形状块要灰显" \
  Sources/SrtFlow/VideoEditTimelineShapeRow.swift 'timelineHiddenLook\(shape\.isHidden\)'
require "藏起来的滤镜块要灰显" \
  Sources/SrtFlow/VideoEditTimelineFilterRow.swift 'timelineHiddenLook\(filter\.isHidden\)'
# 进预览和成片的清单只有一份（ClipVisibility 那个文件里的 rendered*）：预览和导出都读它，
# 直接读 state.shapes / textOverlaysInStackingOrder / orderedFilters 去渲染就会漏过 V。
require "V 也切文字 / 形状 / 滤镜段" \
  Sources/SrtFlow/VideoEditProject.swift 'selectedTextIDs\.union\(selectedShapeIDs\)\.union\(selectedFilterIDs\)'
require "预览上的形状读 renderedShapes" \
  Sources/SrtFlow/VideoEditProject.swift 'state\.renderedShapes\.filter'
require "预览上的文字读 renderedTextOverlays" \
  Sources/SrtFlow/VideoEditProject+Text.swift 'state\.renderedTextOverlays\.filter'
require "预览的调色读不含隐藏的 activeFilters" \
  Sources/SrtFlow/VideoEditFilterModels.swift 'renderedFilters\.filter \{ \$0\.contains\(time: time\) \}'
require "导出的形状读 renderedShapes" \
  Sources/SrtFlow/VideoEditExportGraph.swift 'state\.renderedShapes\.enumerated\(\)'
require "导出的文字读 renderedTextOverlays" \
  Sources/SrtFlow/VideoEditExportGraph.swift 'state\.renderedTextOverlays, canvas:'
require "导出的调色读 renderedFilters" \
  Sources/SrtFlow/VideoEditExportGraph.swift 'state\.renderedFilters\.filter'
require "轨道头的眼睛仍是整轨显隐的入口" \
  Sources/SrtFlow/VideoEditTimelineHeaderColumn.swift 'toggleLaneHidden\('

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
# 预览上的字幕 2026-09-25 从根视图搬进了 PreviewSubtitleLayer（根视图不再订阅时钟），2026-09-26
# 两条轨独立后改成「画面上排成几块」：预览和烧录读同一份 subtitleScreenBlocks，不许各算一份。
require "预览必须走眼睛推导出的字幕块（和烧录同一份）" \
  Sources/SrtFlow/VideoEditPreviewSubtitleLayer.swift 'project\.state\.subtitleScreenBlocks\(\)'
require "烧录必须与预览同一份合同（眼睛说了算）" \
  Sources/SrtFlow/VideoEditExportGraph.swift 'state\.subtitleScreenBlocks\(\)\.map\(\\\.renderBlock\)'
forbid "导出面板不许另算一份要烧的文档（关掉烧录 = 关眼睛）" \
  Sources/SrtFlow/SubtitleGen/SubtitleExportSection.swift 'func burnDocument'
forbid "导出面板不许再自己选烧哪条轨" \
  Sources/SrtFlow/SubtitleGen/SubtitleExportSection.swift 'enum Burn'
require "时间线要给译文轨一只自己的眼睛" \
  Sources/SrtFlow/VideoEditTimelineHeaderColumn.swift 'toggleTranslationHidden\(\)'

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
      | grep -c 'isCancelled: { token.isCancelled }' >/dev/null; then
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

# 入场/出场动画（2026-09-18）：纯值合同在上面断言过了，这里钉住生产接线。
#
# 效果和时长是同一个槽，**必须一起改**（不变量见 ClipPresetAnimation.isEmpty）：
# 只改效果会让用户选完 Rise 画面纹丝不动；只清时长会让界面显示"无"而画面还在淡。
require "选上效果时要顺手给时长（入场）" \
  Sources/SrtFlow/VideoEditProject+ClipAnimation.swift \
  'clip\.videoFadeInDuration = Self\.duration\('
require "选上效果时要顺手给时长（出场）" \
  Sources/SrtFlow/VideoEditProject+ClipAnimation.swift \
  'clip\.videoFadeOutDuration = Self\.duration\('
# 批量套用：写入路径收 [UUID]，界面把多选的段整批传进来。窄回单段就等于
# 悄悄砍掉批量能力（一节课几十张图，一张张点不现实）。
require "效果的写入必须收一组 id" \
  Sources/SrtFlow/VideoEditProject+ClipAnimation.swift \
  'func setClipPresetKind\(_ ids: \[UUID\]'
require "强度的写入必须收一组 id" \
  Sources/SrtFlow/VideoEditProject+ClipAnimation.swift \
  'func liveSetClipPresetIntensity\(_ ids: \[UUID\]'
require "多选时 Inspector 要给批量面板" \
  Sources/SrtFlow/VideoEditInspector.swift 'multiClipAnimationSection\('
# 逐帧效果的段导出前必须预渲染；判据只有 needsPerFrameRender 一个。
require "导出路由必须问 needsPerFrameRender（主轨）" \
  Sources/SrtFlow/VideoEditExportGraph.swift \
  'segment\.clip, clip\.needsPerFrameRender'
require "导出路由必须问 needsPerFrameRender（上层轨）" \
  Sources/SrtFlow/VideoEditExportGraph.swift \
  'where clip\.needsPerFrameRender'
# 预渲染的临时时间线里没有邻居，转场仲裁只能由调用方算好传进去
# （docs/bugfixes/2026-09-18-prerender-fade-ignores-transition.md）。
require "预渲染必须接收仲裁过的渐变窗口" \
  Sources/SrtFlow/VideoEditPrerender.swift \
  'private static func normalized\(_ clip: EditClip, fades: FadeWindow\)'

if [ "$WIRING_FAIL" -ne 0 ]; then
  echo "接线守卫失败" >&2
  exit 1
fi
echo "✓ 接线守卫通过"
