#!/usr/bin/env bash
# 扫描守卫：App 代码里不许同步问播放器要时间（`currentTime()`），AVKit 的 Now Playing 更新必须关着。
#
# 由来（docs/bugfixes/2026-10-01-meter-current-time-blocks-main-thread.md）：电平条每秒 300 次在主线程上调
# `player.currentTime()`，它要拿播放器内部那把锁；多轨工程播放中播放器自己的队列一忙，主线程就被堵住
# 几百毫秒到 2.4 秒，空格按下去图标慢半拍。AVKit 往「正在播放」报状态走的是同一把锁（874 ms）。
# 播放头的时间只从时钟的回调来（`PlayerClock.time` / `estimatedTime`），谁都别再问播放器。
#
# 用法：checks/player-time-no-sync-read.sh
set -uo pipefail
cd "$(dirname "$0")/.."
FAILED=0

# 1. `currentTime()`：Sources/SrtFlow 下一处都不许有（注释里提到不算）。
HITS="$(grep -rn 'currentTime()' Sources/SrtFlow --include='*.swift' | sed 's,//.*,,' | grep -c 'currentTime()' || true)"
if [ "${HITS}" != "0" ]; then
  echo "✗ player-time-no-sync-read：App 代码里出现了 currentTime()（同步问播放器要时间，会被播放器的锁堵住主线程）：" >&2
  grep -rn 'currentTime()' Sources/SrtFlow --include='*.swift' | sed 's,//.*,,' | grep 'currentTime()' >&2
  echo "  播放头的时间只从时钟的回调来：读 PlayerClock.time，跟着播放头画的高频读者读 PlayerClock.estimatedTime。" >&2
  FAILED=1
fi

# 2. AVPlayerView 的 Now Playing 更新必须关着。
if ! grep -q 'updatesNowPlayingInfoCenter = false' Sources/SrtFlow/PlayerViewRepresentable.swift; then
  echo "✗ player-time-no-sync-read：PlayerViewRepresentable 没有关掉 updatesNowPlayingInfoCenter（AVKit 会在主线程上反复问播放器 currentTime）" >&2
  FAILED=1
fi

# 3. 扫空 = 假绿：至少要扫到 estimatedTime 的那个读者。
if ! grep -q 'clock.estimatedTime' Sources/SrtFlow/VideoEditTrackFader.swift; then
  echo "✗ player-time-no-sync-read：电平条没有在读 clock.estimatedTime（读者改名了就同步改这里）" >&2
  FAILED=1
fi

if [ "${FAILED}" = "0" ]; then
  echo "✓ player-time-no-sync-read：App 代码里没有 currentTime()，Now Playing 更新关着，电平条读的是时钟外推的播放头"
fi
exit "${FAILED}"
