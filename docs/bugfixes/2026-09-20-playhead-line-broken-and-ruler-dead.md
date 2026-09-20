# 播放头的线是断的，而且点标尺没反应

2026-09-20。用户报的两个症状，**同一个根因**。从 v0.9.x 一直存在到 v0.10.0，
不是当天那几刀转场改动引入的（拿已发布的 0.10.0 做过对照实验）。

## 症状

1. 播放头那条白线不从标尺贯到底，中间断开一大截 —— 把手在标尺上，线从下面才
   开始。
2. 点/拖标尺，播放头不动（播放本身正常，空格一按时间照走）。

## 根因

时间线的滚动内容（`scrolledContent`）以前只钉了宽度：

```swift
ScrollView([.horizontal, .vertical]) {
    scrolledContent.frame(width: contentWidth, alignment: .topLeading)
}
```

轨道少的时候（常态：一条主轨）内容比视口矮，SwiftUI 就把它在纵向**居中**。于是：

- **线是断的**：播放头是 `scrolledContent` 那个 ZStack 的最后一个孩子，
  `.frame(maxHeight: .infinity)` 撑的是 ZStack 的高度。内容被居中之后，线只
  覆盖居中后那一段，上面接不到标尺 —— 实测间隙随视口高度变化（窗口拉高 125pt，
  压矮 84pt），正是「视口高度减内容高度的一半」。
- **标尺点不动**：标尺是内容里的第一行，靠 `.offset(y: geometry.offset.y)` 被
  拉回视口顶上（这样纵向滚动时它不跟着走）。内容被居中之后这个 offset 变成一个
  大负数，把标尺从它的布局槽里拽出去一大截 —— 画是画对了，**命中区没跟过去**，
  所以点可见的标尺什么也不会发生。

两条连在一起还有个副作用：播放头卡在 0:00，于是工具栏上所有「播放头得落在片段
内部」才可用的按钮（分割、冻结、标记、删左、删右）永远是灰的，看起来像是工具栏
也坏了。

## 修法

让内容至少填满视口并顶对齐：

```swift
.frame(minHeight: viewportHeight, alignment: .top)
```

`viewportHeight` 早就在 `@State` 里跟着量了，只是从来没用过。内容比视口高时这行
不起作用，纵向滚动照旧。

## 怎么验的

这个 bug 有个讨厌的地方：**合成鼠标事件驱不动标尺的手势**。CGEvent 和
System Events 两条路都试过，还补了 `mouseEventClickState`（CGEvent 造的鼠标事件
clickCount 默认是 0，AppKit 不当它是真点击）——都不行，而同一个工具能成功拖动
片段块。所以查的过程里只能靠用户的真实操作做二分。

修完之后**合成点击立刻生效了**（时间从 0:00.0 跳到 0:06.0，被 duration 正确夹
住）。这反过来也印证了机制：之前不是事件合成得不对，是命中区根本不在那儿。

## 守卫

`checks/timeline-drag-wiring.sh` 加了一节：滚动内容必须带
`.frame(minHeight: viewportHeight, alignment: .top)`。

断言写成**单行匹配**：分成两条写的话，`alignment: .top` 会被上一行的
`.topLeading` 顺手匹配掉，顶对齐那条就是永远为真的假绿 —— 第一版正是这么写的，
反向验证时发现的（同一天同一个脚本里已经踩过一次无锚点匹配的假绿）。
