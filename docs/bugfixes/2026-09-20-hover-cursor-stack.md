# 2026-09-20 悬停光标卡住：修了一版「自己记账」，实测没修对

## 症状

六处把手（转场遮罩两边、片段裁切、形状轨与文字轨裁切、标尺调轨高、预览变换）
都写成这样：

```swift
.onHover { inside in
    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
}
```

全 App 共用系统**同一个**光标栈，漏押/错弹一次就全局卡住。典型现场是拖着改转场
时长，手一松光标卡成左右箭头，只能靠划过另一个会 push 的把手把栈冲掉。

## 第一版修法（错的）

判断是「视图在悬停中被重建/销毁时 `onHover(false)` 不会来 → 押了没弹」，于是写了
`HoverCursor.swift`：自己记一笔账只弹自己押的那次，再用 `onDisappear` 兜底。

用户试了，**症状还在**。

## 实测

搭了个探针把三种实现摆进同一个窗口（`Pane(variant:)`：A 旧写法 / B 自记账 /
C `.pointerStyle`），几何照抄 `TransitionMaskView`——宽度 = 时长 × pps、位置按窗口
中心算，所以拖到 `maxDuration` 夹紧之后把手不再跟手、从指针底下跑掉。用 CGEvent
合成一套「移进把手 → 按下 → 拖过夹紧点 → 松手 → 挪到空白处」，同时在 App 内读
`NSCursor.current`、在另一个进程里读 `NSCursor.currentSystem` 对照。

结果：

```
[706.051] B/右 push
[706.079]    光标 → resizeLeftRight
[706.644] B/右 拖动开始
[706.742] B/右 pop            ← 拖动才开始 100ms，hover 就没了
[707.661] B/右 拖动结束，时长 2.00
[707.662]    光标 → arrow
```

两件事当场推翻了原来的判断：

1. **`onDisappear` 那条兜底压根没被触发过。** 遮罩挂在
   `ForEach(seamIndicesWithTransition, id: \.self)` 上，拖时长时缝下标不变，身份
   稳定，视图根本不重建。
2. **SwiftUI 在拖动一开始就发 `onHover(false)`。** 光标在拖到一半时就弹回箭头 ——
   而拖动全程恰恰是最该保持左右箭头的时候。记账再精细也救不了：push/pop 这套本来
   就在跟 SwiftUI 自己的指针管理抢方向盘。

同一套动作驱 C（`.pointerStyle`）：光标全程保持左右箭头，松手挪开才回箭头。

## 修复

改走 SwiftUI 原生 `.pointerStyle(_:)`（macOS 15 起，包的最低系统正好是 15.0）：
指针归视图区域管，挪走/变形/消失/拖动中全由 SwiftUI 维护，没有全局栈可漏。
条件光标（刀片十字）用 `.pointerStyle(cond ? .rectSelection : nil)`，nil 即
「这一处不接管、交回外层」，不需要任何 `@State`。

外观零变化，三种都实测对照过是**像素级同图**（同一 tiff 哈希 + 同一 hotSpot）：

| 原来 | 现在 |
| --- | --- |
| `NSCursor.resizeLeftRight` | `.columnResize` |
| `NSCursor.resizeUpDown` | `.rowResize` |
| `NSCursor.crosshair` | `.rectSelection` |

守卫 `checks/hover-pointer-style.sh`：Sources/ 里连 `NSCursor` 都不许出现（注释
除外），外加七处把手的样式逐个钉死。

## 教训

1. **「视图被重建」是个很顺嘴的解释，但这次是错的。** 挂载点写着
   `ForEach(id: \.self)`，读一眼就能排除重建——比写一版修法再让用户试便宜得多。
2. **手感类的 bug 别靠推理结案。** 合成事件驱不动标尺 scrub，但这种 `DragGesture`
   驱得动；把 `NSCursor.current` 打进日志，几十行探针就能把「谁在什么时候弹的」
   摆在眼前。三种实现并排驱同一套动作，差异一眼可见。
3. **系统给了原生 API 就别自己造栈。** push/pop 是 AppKit 时代的接口，在 SwiftUI
   里和框架自己的指针管理是两套人马。
