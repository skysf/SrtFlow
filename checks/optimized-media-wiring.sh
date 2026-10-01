#!/usr/bin/env bash
# 扫描守卫：优化媒体（预览画面的代理）的生产接线（docs/architecture/optimized-media.md）。
#
# 管什么：`scripts/check-optimized-media.sh` 和 `scripts/check-preview-composition.sh` 的「按块换源」只证明函数算得对；
# 换源有没有只接在预览重建那一处、成片 / 预渲染 / AI 看是不是永远原片、转码是不是在 proxy 队列上且登记了后台读、
# 换源是不是只在停着时做、切工程有没有作废路上的转码、菜单有没有偷读工程、性能台架量的是不是原片那条路，
# 以及 V3：设置里清空之后有没有让协调者作废 + 重建、改上限有没有当场 enforce、缓存目录和上限的键是不是只经 Store、
# 启动时有没有在 proxy 队列上过期、转不了的是不是只在菜单里标（不进提示条）——
# 这些 VideoEditProject / 协调者是 @MainActor 的 App 类型，自检编不动，只能在源码层面钉住。
# 不管什么：判据、分块、缓存、转码本身（scripts/check-optimized-media.sh）。
#
# 用法：checks/optimized-media-wiring.sh（check-all 第 1 组）
set -euo pipefail
cd "$(dirname "$0")/.."

FAIL=0
require() { # require <描述> <文件> <正则>
  if ! grep -Eq -e "$3" "$2"; then
    echo "✗ optimized-media-wiring：$1（在 $2 里找不到 /$3/）" >&2
    FAIL=1
  fi
}
forbid() { # forbid <描述> <文件> <正则>
  if grep -Eq -e "$3" "$2"; then
    echo "✗ optimized-media-wiring：$1（$2 里仍有 /$3/）" >&2
    FAIL=1
  fi
}

PROJECT=Sources/SrtFlow/VideoEditProject.swift
COORDINATOR=Sources/SrtFlow/OptimizedMedia/OptimizedMediaCoordinator.swift
TRANSCODER=Sources/SrtFlow/OptimizedMedia/OptimizedMediaTranscoder.swift
BUILDER=Sources/SrtFlow/VideoEditCompositionBuilder.swift
STORE=Sources/SrtFlow/OptimizedMedia/OptimizedMediaStore.swift
CACHE_SETTINGS=Sources/SrtFlow/OptimizedMedia/OptimizedMediaCacheSettings.swift
SETTINGS_SECTION=Sources/SrtFlow/OptimizedMediaSettingsSection.swift
MENU=Sources/SrtFlow/OptimizedMediaMenu.swift
APP=Sources/SrtFlow/SrtFlowApp.swift

# 换源只在预览重建那一处传 proxies；成片、预渲染、AI 看永远用原片。
require "预览重建把转好的块交给 builder" "$PROJECT" \
  'VideoEditCompositionBuilder\.build\(from: snapshot, proxies: self\.optimizedMedia\.lookup\(for: snapshot\)\)'
require "重建落地之后按这份时间线排转码（sync）" "$PROJECT" 'self\.optimizedMedia\.sync\(state: snapshot, playhead: time\)'
OTHER_PROXIES="$(grep -rlnE --include='*.swift' 'build\(from:.*proxies:' Sources/SrtFlow | grep -v "^${PROJECT}$" || true)"
if [ -n "${OTHER_PROXIES}" ]; then
  echo "✗ optimized-media-wiring：只有预览重建能传 proxies，这些文件也传了：${OTHER_PROXIES}" >&2
  FAIL=1
fi
for f in Sources/SrtFlow/VideoEditPrerender.swift Sources/SrtFlow/AIFrameComposer.swift; do
  forbid "${f} 永远用原片（不许碰优化媒体）" "${f}" 'OptimizedMedia'
done
for f in Sources/SrtFlow/VideoEditExport*.swift Sources/SrtFlow/ExportAudioMixdown.swift; do
  [ -f "$f" ] || continue
  forbid "成片那一路不碰缓存目录（${f}）" "${f}" 'OptimizedMedia'
done
# builder 插画面只走 CompositionClipInsert（主轨 + 上层轨两处），老的 insert 不许回来。
INSERTS="$(grep -cE 'CompositionClipInsert\.insert\(' "$BUILDER" || true)"
if [ "${INSERTS}" != "2" ]; then
  echo "✗ optimized-media-wiring：builder 应有两处（主轨、上层轨）走 CompositionClipInsert.insert，实际 ${INSERTS}" >&2
  FAIL=1
fi
forbid "builder 里不许再有自己的 insert(source:" "$BUILDER" 'private static func insert\('
require "几何按插进去的那条源轨算（4K 减半的代理尺寸是它自己的）" "$BUILDER" 'geometrySource\.load\(\.naturalSize\)'

# 转码在 proxy 队列上、登记后台读（性能测试和冒烟的「落定」要等它）。
require "转码在 MediaReadQueue.proxy 上" "$COORDINATOR" 'MediaReadQueue\.run\(on: MediaReadQueue\.proxy\)'
require "转码登记后台读（开始）" "$COORDINATOR" 'PerfCounters\.backgroundReadBegan\(\)'
require "转码登记后台读（结束）" "$COORDINATOR" 'PerfCounters\.backgroundReadEnded\(\)'
require "写索引（touch）也走 proxy 队列，不在主线程上" "$COORDINATOR" 'MediaReadQueue\.proxy\.addOperation'
# 换源只在停着时：播放中等暂停。
require "换源之前先看播放状态" "$COORDINATOR" 'if project\.clock\.isPlaying \{'
require "播放中等暂停再换" "$COORDINATOR" 'project\.clock\.\$isPlaying'
# 切工程：路上的转码作废。
require "切工程作废路上的转码" Sources/SrtFlow/VideoEditProjectDocument.swift 'optimizedMedia\.reset\(\)'
# 转码参数（改了要 +1 parametersVersion）。
require "代理 0.5 秒一个关键帧" "$TRANSCODER" 'AVVideoMaxKeyFrameIntervalDurationKey: OptimizedMediaPolicy\.keyframeInterval'
require "代理没有 B 帧" "$TRANSCODER" 'AVVideoAllowFrameReorderingKey: false'
require "代理经视频合成读（变帧率的录屏静止期一帧撑住、块头先出一帧）" "$TRANSCODER" 'AVAssetReaderVideoCompositionOutput\('
require "块的轨铺到块尾（整块都在静止期里只有块头那一帧）" "$TRANSCODER" 'writer\.endSession\(atSourceTime: CMTime\(seconds: end'
require "合成输出的像素缓冲必须拷贝（不拷贝编码器在第 4、5 帧上报 kVTParameterErr）" "$TRANSCODER" 'output\.alwaysCopiesSampleData = true'
require "块只有画面：输入只有视频轨" "$TRANSCODER" 'AVAssetWriterInput\(mediaType: \.video'
# 菜单只订阅协调者，不读工程。
forbid "菜单不许读工程" "$MENU" 'project'
require "菜单订阅协调者" "$MENU" '@ObservedObject var coordinator: OptimizedMediaCoordinator'
# 性能台架量原片那条路（托管 runner 没硬件编码器的保证）。
require "性能台架用参数域关掉优化媒体" scripts/check-preview-perf.sh '-optimizedMedia\.previewMode original'

# ---- V3：设置里的占用 / 上限 / 清空、启动时过期、转不了的提示 ----
# 清空之后：协调者作废内存里那张表 + 重建一次（不然合成还指着删掉的块文件：builder 退回原片，但表上写着「齐了」就不会再排转码）。
# `removeAll()` 在 proxy 队列上、和转码串着；之后紧跟 reset 再 scheduleRebuild。
require "清空在 proxy 队列上删目录" "$CACHE_SETTINGS" 'MediaReadQueue\.run\(on: MediaReadQueue\.proxy\) \{ OptimizedMediaStore\.removeAll\(\) \}'
if ! perl -0ne 'exit(($_ =~ /OptimizedMediaStore\.removeAll\(\) \}\n(?:[^\n]*\n){0,3}\s*project\.optimizedMedia\.reset\(\)\n\s*project\.scheduleRebuild\(\)/) ? 0 : 1)' "$CACHE_SETTINGS"; then
  echo "✗ optimized-media-wiring：清空之后必须紧跟 optimizedMedia.reset() 再 scheduleRebuild()（${CACHE_SETTINGS}）" >&2
  FAIL=1
fi
REMOVE_ALL_CALLERS="$(grep -rlE --include='*.swift' 'OptimizedMediaStore\.removeAll\(' Sources/SrtFlow | grep -v "^${CACHE_SETTINGS}$" || true)"
if [ -n "${REMOVE_ALL_CALLERS}" ]; then
  echo "✗ optimized-media-wiring：清空缓存只许设置那一节的模型调（它负责 reset + 重建），这些文件也调了：${REMOVE_ALL_CALLERS}" >&2
  FAIL=1
fi
# 改上限：写只经 Store，写完当场 enforce（在 proxy 队列上）。
require "改上限经 Store 写" "$CACHE_SETTINGS" 'OptimizedMediaStore\.setCapacityBytes\('
require "改上限之后立刻 enforceCapacity" "$CACHE_SETTINGS" 'MediaReadQueue\.run\(on: MediaReadQueue\.proxy\) \{ OptimizedMediaStore\.enforceCapacity\(limit: limit\) \}'
require "占用在 proxy 队列上算（和转码串着，不在主线程上读索引）" "$CACHE_SETTINGS" 'MediaReadQueue\.run\(on: MediaReadQueue\.proxy\) \{ OptimizedMediaStore\.totalBytes\(\) \}'
# 缓存目录、上限的键只经 Store：别处不许自己拼路径、不许自己读写 UserDefaults 里的那个键。
CACHE_PATH_USERS="$(grep -rlE --include='*.swift' 'SrtFlow/OptimizedMedia' Sources/SrtFlow | grep -v "^${STORE}$" || true)"
if [ -n "${CACHE_PATH_USERS}" ]; then
  echo "✗ optimized-media-wiring：缓存目录的路径只许写在 Store 里，这些文件也拼了：${CACHE_PATH_USERS}" >&2
  FAIL=1
fi
CAPACITY_KEY_USERS="$(grep -rlE --include='*.swift' 'optimizedMedia\.capacityBytes|capacityDefaultsKey' Sources/SrtFlow | grep -v "^${STORE}$" || true)"
if [ -n "${CAPACITY_KEY_USERS}" ]; then
  echo "✗ optimized-media-wiring：上限的 UserDefaults 键只许 Store 读写，这些文件也碰了：${CAPACITY_KEY_USERS}" >&2
  FAIL=1
fi
for f in "$CACHE_SETTINGS" "$SETTINGS_SECTION"; do
  forbid "设置那一节不许自己动文件（只经 Store）" "$f" 'FileManager'
  forbid "设置那一节不许自己读 UserDefaults（上限只经 Store）" "$f" 'UserDefaults'
done
# 设置那一节只订阅自己的小对象，不读工程（docs/architecture/preview-perf-ratchet.md 第十节）。
forbid "设置那一节不许读工程" "$SETTINGS_SECTION" 'project'
require "设置那一节订阅缓存设置那个小对象" "$SETTINGS_SECTION" '@ObservedObject private var settings = OptimizedMediaCacheSettings\.shared'
require "设置窗口里有这一节" "$APP" 'OptimizedMediaSettingsSection\(\)'
# 启动时过期：proxy 队列上、天数从 Store 来、登记后台读（冒烟的「落定」等它）。
if ! perl -0ne 'exit(($_ =~ /PerfCounters\.backgroundReadBegan\(\)\n\s*MediaReadQueue\.proxy\.addOperation \{\n\s*OptimizedMediaStore\.expire\(olderThan: OptimizedMediaStore\.expiryDays\)\n\s*PerfCounters\.backgroundReadEnded\(\)/) ? 0 : 1)' "$APP"; then
  echo "✗ optimized-media-wiring：启动时要在 proxy 队列上 expire(olderThan: expiryDays)，并登记后台读（${APP}）" >&2
  FAIL=1
fi
require "启动时调过期（调用那一行，不是函数定义）" "$APP" '^[[:space:]]+expireOptimizedMedia\(\)[[:space:]]*$'
# 转不了的源只在菜单里标，不进提示条（提示条常驻、要用户点掉）。
forbid "协调者不许往提示条写" "$COORDINATOR" 'notice'
require "转不了的记在 unavailable" "$COORDINATOR" '@Published private\(set\) var unavailable: \[String\]'
require "菜单列出转不了的" "$MENU" 'coordinator\.unavailable'

if [ "${FAIL}" -ne 0 ]; then exit 1; fi
echo "✓ optimized-media-wiring：换源只在预览重建、成片 / 预渲染 / AI 看永远原片、转码在 proxy 队列并登记后台读、停着才换、切工程作废、菜单不读工程、清空之后 reset + 重建、缓存只经 Store、启动时过期、转不了的只在菜单里标"
