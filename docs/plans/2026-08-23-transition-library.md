# 2026-08-23 转场库扩充与悬停预览选择器

## 产品决策（用户拍板）

- 转场从 3 种（叠化/黑场/白场）扩到 **11 种 + 无**：新增推移 4 向
  （向左/右/上/下推）和擦除 4 向（向左/右/上/下擦除），对齐 CapCut 的
  基础转场档位。
- 检查器里的转场入口从下拉菜单换成 **CapCut 式卡片网格弹窗**：按
  基础 / 推移 / 擦除分组，**鼠标悬停卡片时循环演示该转场的效果**，
  演示画面用接缝两侧的真实缩略帧（出场段尾帧 + 进场段首帧），点卡片
  立即应用、弹窗不关（方便连着试几种）。

## 选型约束（为什么是这 8 种）

预览/导出同账是硬约束（见
[preview-free-transform.md](../architecture/preview-free-transform.md)）。
预览是 AVFoundation 默认合成器，只有透明度/变换/裁切三种斜坡，所以只收
**斜坡能精确表达**的转场：

- 推移 → `setTransformRamp` 平移；擦除 → `setCropRectangleRamp` 窗口。
  两者在导出侧都有现成的 xfade（slideleft/…、wipeleft/…），vendor 的
  ffmpeg 8.1 全支持。
- xfade 里预览表达不了的（circleopen、pixelize、radial、hblur、zoomin…）
  **故意不收**：要么上自定义 Metal 合成器（违背轻量化原则，需用户批准），
  要么接受预览和导出长得不一样（违背同账）。以后要加从这里起步。
- 方向语义（pushLeft 从右边进）以 xfade 纯色实测为准，预览照抄，
  合同写在 `ClipTransition.motion`。

## 实施落点

| 部件 | 位置 |
| --- | --- |
| 枚举 + 族 + 方向几何 | `VideoEditModels.swift`（`ClipTransition`） |
| 预览接缝分派（精确/回退） | `VideoEditCompositionBuilder.swift`（主轨接缝后处理） |
| 导出 | 不变（`xfadeName` 驱动既有 xfade 链） |
| 选择器 UI | `VideoEditTransitionPicker.swift`（新文件） |
| 回归 | `check-preview-composition.sh` 推移/擦除组、`check-export-frame-rate.sh` 逐种转场真导出 |
