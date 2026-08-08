# 2026-08-08 悬停扫块拖走播放头（改成影子指针）+ 删除键删不掉选中剪辑

一次修的两个时间线交互问题，症状独立、根因独立。

## 症状

1. **悬停偷走播放头**：用户在标尺上点好 35s，鼠标只是扫过轨道上的块看看内容，
   播放头就被悄悄拖走了 —— 回不到自己点定的位置。期望（对齐主流剪辑软件）：
   点定的播放头固定不动；悬停时另有一根「影子指针」跟手预览，鼠标离开画面
   跳回播放头。
2. **删除键无效**：选中轨道上的块按 ⌫，什么都不发生，只能去点工具栏的
   trash 按钮。

## 根因

1. `ClipBlockView.hoverScrub` 里悬停直接调 `clock.seek(precise: false)` ——
   `seek` 的语义就是移动播放头（写 `time`），预览跟手的代价是播放头被劫持。
   当时只有一根指针的概念，没有「看一眼但不落脚」的语义。
2. 其实早就「接过」：视图上挂着 `.onDeleteCommand { project.deleteSelected() }`
   （`VideoEditView.swift:63`）。但 `onDeleteCommand` 走的是 SwiftUI 焦点链
   （responder chain 的 `deleteBackward:`），这个窗口里没有任何可聚焦的
   SwiftUI 元素持有键盘焦点，它**一次都不会触发** —— 挂着一行看似接上的
   代码，比完全没接更能骗过 review。而真正在收键盘的 local monitor
   （`handleEvent`）只认了空格 / V / A / B，⌫（keyCode 51）落进 `default:`
   原样放行。又一例「功能写对了但没被接上」，且这次「接上」的假象是双重的。

## 修复

1. **`PlayerClock` 新增 peek 语义**（`VideoPreviewView.swift`）：
   - `peek(at:)`：画面走链式 seek 去看指的那一帧，`time`（播放头）不动；
     `peekTime` 发布给时间线画半透明细线的影子指针（`hoverPointer`，
     `VideoEditTimelineView.swift`）。
   - `endPeek()`：影子消失，画面滚回播放头。悬停 `.ended`、开始拖块、
     开始裁切都会调它。
   - **任何真正的定位都终结 peek**：`seek` / `togglePlayback`（必须从播放头
     起播）/ `attach` / `attachItem` / `detach` 全部清 `peekTime`；周期性时间
     回调在 peek 期间不写回 `time`，否则播放头照样被拖走。
   - `displayTime = peekTime ?? time`：叠在预览画面上的东西（字幕文本、
     形状出没、变换框）读它，才和画面显示的那一帧对得上；播放头线、
     transport 时间、Split at Playhead 一类「播放头语义」继续读 `time`。
2. **⌫ / fn⌫ 接上删除**：`handleEvent` 里按 keyCode（51 / 117）认，调工具栏
   trash 同一个 `deleteSelected()`（剪辑含链接组、形状都覆盖）；正在输入
   （NSTextView 第一响应者）和带修饰键的组合照旧放行。

## 验证

- `scripts/check-player-clock.sh`（新增）：peek 状态机 17 项 —— 播放头在
  peek 期间不动、endPeek 回位、seek/播放/换片终结 peek、空 endPeek 无害、
  负数收口。
- 真机冒烟（SrtFlowDev 流程）：**删除键端到端通过** —— 选中 clipB 按 ⌫，
  轨道当场清空（Main track clips 1→0），⌘Z 撤销恢复也正常。
- 悬停链路的 SwiftUI 事件递送（`onContinuousHover` → 回调）是**未改动的
  既有管线**（原 bug 恰恰证明真实鼠标下它必然触发）；本次改的是回调体内
  seek→peek 与渲染，由上面的状态机自检钉住。**合成事件在这台机器上发不出
  hover**（详见 gui-smoke-testing 的注入边界），影子指针的手感与「鼠标离开
  跳回播放头」由用户真机过一遍。

## 教训 / 防回归

- **「预览跟手」和「移动播放头」是两个语义**，共用一个 `seek` 迟早互相
  践踏。凡是「看一眼」类交互（悬停、将来可能的缩略图 hover），一律走
  peek，不许碰 `time`。
- 画面叠层（字幕/形状/变换框）跟 **displayTime**，播放头语义跟 **time** ——
  新增任何读时间的 UI 前先分清楚它属于哪边，混用会出现「画面是 15s、
  字幕是 8s」的错帧。
- 键盘快捷键的「没实现」和「实现了没接上」外观完全一样；这个窗口的键盘
  入口**只有 local monitor（`handleEvent`）一个**，`.onDeleteCommand` /
  `.keyboardShortcut` 这类依赖 SwiftUI 焦点的修饰符在这里不会触发，
  别再往上挂；加新动作去 `handleEvent`，工具栏按钮和快捷键必须指向
  **同一个**入口函数。
- 冒烟注入的新边界（合成点击滞后要 flush、hover 发不出来）已并入
  [gui-smoke-testing](../testing/gui-smoke-testing.md)。
