#!/usr/bin/env bash
# 扫描守卫：优化媒体（预览画面的代理）的生产接线（docs/architecture/optimized-media.md）。
#
# 管什么：`scripts/check-optimized-media.sh` 和 `scripts/check-preview-composition.sh` 的「按块换源」只证明函数算得对；
# 换源有没有只接在预览重建那一处、成片 / 预渲染 / AI 看是不是永远原片、转码是不是在 proxy 队列上且登记了后台读、
# 换源是不是只在停着时做、切工程有没有作废路上的转码、菜单有没有偷读工程、性能台架量的是不是原片那条路 ——
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
forbid "菜单不许读工程" Sources/SrtFlow/OptimizedMediaMenu.swift 'project'
require "菜单订阅协调者" Sources/SrtFlow/OptimizedMediaMenu.swift '@ObservedObject var coordinator: OptimizedMediaCoordinator'
# 性能台架量原片那条路（托管 runner 没硬件编码器的保证）。
require "性能台架用参数域关掉优化媒体" scripts/check-preview-perf.sh '-optimizedMedia\.previewMode original'

if [ "${FAIL}" -ne 0 ]; then exit 1; fi
echo "✓ optimized-media-wiring：换源只在预览重建、成片 / 预渲染 / AI 看永远原片、转码在 proxy 队列并登记后台读、停着才换、切工程作废、菜单不读工程"
