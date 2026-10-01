#!/usr/bin/env bash
# 扫描守卫：成片的声音只有一条管线 —— 预览那个音频引擎离线渲出来（ExportAudioMixdown → TimelineAudioEngine）。
#
# 2026-09-24 以前，导出在 ffmpeg 滤镜图里另搭一整套声音链（atrim → atempo → volume / aeval →
# afade → adelay，主轨 concat / acrossfade，最后 amix），和预览的 AVFoundation 混音各算一份，
# 靠一堆「先后顺序」规矩对齐。用户嫌每个声音功能都要做两遍，于是成片的声音改成预览那份混音
# 原样读出来（docs/plans/2026-09-24-sound-scenes.md，长期约束 docs/architecture/export-audio-mixdown.md）。
#
# 这条守卫防的是「顺手又在图里搭一段声音」，让两份账重新长出来：
#   1. 导出图的真代码里不许出现声音滤镜（注释里提到不算）。垫静音的 anullsrc 除外 ——
#      一个出声的段都没有时成片照样要有一条音轨。
#   2. 导出图必须调 ExportAudioMixdown.render，把它的文件接成音轨。
#   3. 混音是 AudioEngineConfig.make 那份配置（和预览同一份：段落、增益、曲线、推子、场景、变速）交给
#      TimelineAudioEngine 的离线模式渲出来的（2026-10-01 PR3a 起；以前是读 AVFoundation 的合成 + audioMix，
#      PR3b 连播放器那条声音路一起删了：播放条目里只有画面）。
#
# 用法：checks/export-audio-single-pipeline.sh
set -euo pipefail
cd "$(dirname "$0")/.."

GRAPH="Sources/SrtFlow/VideoEditExportGraph.swift"
MIXDOWN="Sources/SrtFlow/VideoEditExportMixdown.swift"
FAILED=0

fail() {
  echo "✗ $1" >&2
  FAILED=1
}

for file in "${GRAPH}" "${MIXDOWN}"; do
  [ -f "${file}" ] || { echo "✗ 找不到 ${file}：被改名了，守卫会扫空 —— 同步改这里" >&2; exit 1; }
done

# 只看真代码行（去掉 // 注释行和行尾注释）。
code_of() { sed -e 's,[[:space:]]*//.*$,,' "$1"; }

GRAPH_CODE="$(code_of "${GRAPH}")"
for filter in atrim asetpts atempo afade aeval adelay apad acrossfade amix aresample aformat 'volume='; do
  HITS="$(grep -c -- "${filter}" <<<"${GRAPH_CODE}" || true)"
  [ "${HITS}" -eq 0 ] \
    || fail "导出图里又出现了声音滤镜 ${filter}（${HITS} 处）：成片的声音只能是预览那份混音，别在图里另搭一段"
done

grep -qF 'ExportAudioMixdown.render(' <<<"${GRAPH_CODE}" \
  || fail "导出图没有调 ExportAudioMixdown.render：成片的声音从哪来？"
grep -qF 'ExportAudioMixdown.inputArguments(' <<<"${GRAPH_CODE}" \
  || fail "导出图没有把混音文件接成输入"

MIXDOWN_CODE="$(code_of "${MIXDOWN}")"
grep -qF 'AudioEngineConfig.make(from: state)' <<<"${MIXDOWN_CODE}" \
  || fail "混音不是从预览那份配置渲的（AudioEngineConfig.make）：段落、增益、场景、变速会和预览分叉"
grep -qF 'TimelineAudioEngine(config: config, mode: .offline)' <<<"${MIXDOWN_CODE}" \
  || fail "混音不是预览那个引擎离线渲出来的（TimelineAudioEngine .offline）"
grep -qF 'engine.renderOffline(' <<<"${MIXDOWN_CODE}" \
  || fail "混音没有走引擎的 renderOffline"

if [ "${FAILED}" -ne 0 ]; then
  exit 1
fi
echo "✓ export-audio-single-pipeline：导出图里没有声音滤镜，成片的声音就是预览那份混音"
