# 2026-08-03 拖动/悬停扫时间线时预览画面不逐帧刷新

## 症状

在 Edit Video 时间线上拖刻度条的播放头，或鼠标悬停扫过视频块时，预览区画面
几乎不动，只偶尔跳一下——离"每帧都有"差得很远。Burn In 预览的进度条拖动
也有同样问题，只是素材关键帧密时不明显。

## 根因

1. **拖动过程中的 seek 全走了"关键帧吸附"**。`PlayerClock.seek(precise: false)`
   内部调用不带 tolerance 参数的 `player.seek(to:)`，其默认容差是**无穷大**，
   AVPlayer 只跳到离目标最近的关键帧（sync sample）。Edit Video 的预览播的是
   `AVMutableComposition` 拼出来的条目，源素材是 H.264 时关键帧通常隔 1–5 秒
   一个，于是拖动中绝大多数 seek 都被吸到同一帧上，画面看起来纹丝不动。
   当初写 `precise: false` 是"精确 seek 慢、粗定位才跟手"的老经验，在
   Apple Silicon 上已不成立——零容差解码单帧足够快，FCP/CapCut 拖动时都是
   精确 seek。
2. **没有防洪**。改成零容差后若每个 mouse move 直发 `player.seek`，在飞的
   seek 会被后来的反复取消，帧刷新率反而不稳。Apple QA1820 的推荐做法是
   链式 seek：在飞时只记最新目标，完成回调里再续发。
3. （小）`hoverScrub` 原有 `abs(time - lastHoverSeek) > 0.04` 的节流按时间轴
   秒数卡，30/60fps 素材达不到帧级，高倍缩放下鼠标移一像素也会被吞。

## 修复

- `Sources/SrtFlow/VideoPreviewView.swift` — `PlayerClock.seek(precise:)` 语义
  重定义：`true` = 立即精确定位（跳转/松手用），`false` = **同样零容差**但走
  链式 seek（`isScrubSeeking` + `pendingScrubTarget`，完成回调续发最新目标）。
  `attach` / `attachItem` / `detach` 时清掉挂起目标，防止换条目后续发旧 seek。
- `Sources/SrtFlow/VideoEditTimelineView.swift` — 删掉 `hoverScrub` 的 0.04s
  节流与 `lastHoverSeek` 状态，限流交给链式 seek。
- `Sources/SrtFlow/BurnInPreviewArea.swift` — 只更新过时注释，调用点不变。

调用点（刻度条拖动、悬停扫块、Burn In 进度条）传的参数都没改。

## 验证

- `swift build --arch arm64` 通过；`swift run SrtFlowCoreChecks` 184 项全过。
- 用户真机手测通过：拖刻度条播放头 / 鼠标扫过视频块，预览逐帧跟手。
- 插曲：首次复测曾报「没修好」，随后同一份修复代码手测正常——大概率踩了
  `docs/build/build-and-packaging.md` 里的坑（旧实例还在跑，或 `open` 只是把
  旧进程带到前台）。**复测「修没修好」之前，先确认跑的是新产物、旧实例已退出。**
- 回归面：字幕跳转（`seek(to: cue.start)`，precise 默认 true）、播放中悬停
  不抢画面（`hoverScrub` 的 isPlaying guard 未动）、切换工程后播放头恢复
  （`attachItem` 后的精确 seek 会清挂起目标）。

## 教训 / 防回归

- `player.seek(to:)` 不带 tolerance 参数 ≠ 默认精确，而是**容差无穷大**。
  给"跟手"用的粗定位在合成条目上等于画面不动，不要再退回这个方案。
- 高频 seek 一律走链式模式（QA1820），不要靠调用方各自节流——按秒数节流
  会在高 fps 素材和高倍缩放下出边界 bug。
