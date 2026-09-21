# 刚加进轨道的素材没贴左边，飘在中间

2026-09-21。用户报的。和
[2026-09-20 播放头断线 / 标尺点不动](2026-09-20-playhead-line-broken-and-ruler-dead.md)
**是同一个根因的另一根轴** —— 那次只堵了纵向，横向这一半漏了四个月没人发现。

## 症状

拖一段素材进空工程，它不贴时间线左边，而是连标尺带轨道整块飘到视口中间，左边空
出一大片。素材本身没放错：标尺的 `00:00` 就在块的左沿上，它确实在 0 秒。

工程越短、窗口越宽，飘得越远。

## 根因

内容比视口小时，SwiftUI 的 `ScrollView` 会把内容**居中**。时间线的滚动内容当时
只钉了纵向那一半：

```swift
ScrollView([.horizontal, .vertical]) {
    scrolledContent
        .frame(width: contentWidth, alignment: .topLeading)
        .frame(minHeight: viewportHeight, alignment: .top)   // ← 只有纵向
}
```

而 `contentWidth = max(600, duration * pps + 320)`：一个十几秒的素材在默认
`pixelsPerSecond = 24` 下算出来 600 多点，窗口拉宽一点视口就远大于它。于是整块
内容（标尺 + 轨道 + 播放头）被推到中间，偏移量正是 `(视口宽 - 内容宽) / 2`。

**居中是实测出来的，不是推断**。独立探针（`NSHostingView` 挂在屏幕外的窗口上，
读内容在 `.named("scroll")` 里的 frame）：

| 内容 frame | 视口 | 实测 minX |
| --- | --- | --- |
| `.frame(width: 200, alignment: .topLeading)` | 800 | **300**（= (800-200)/2） |
| 再加 `.frame(minWidth: 800, …, alignment: .topLeading)` | 800 | **0** |

### 还带着一个没人报的症状

框选的两个端点算的是 `内容 x = 视口 x + offsetX`
（`VideoEditTimelineMarqueeGesture.swift` 的 `beginMarquee` / `applyMarqueePoint`；
手势坐标系钉在视口上，滚动量从 `NSScrollView` 现读）。横向居中把这个换算前提打
破了 —— 真实关系是 `内容 x = 视口 x - (视口宽 - 内容宽)/2 + offsetX`。所以在短
工程 + 宽窗口下拉框，框会整体画到指针**右边** `(视口宽 - 内容宽)/2` 那么远，用户
报的截图里目测就有 300 多点。

这条和「素材不贴左边」是同一个根，一起修好。这也是
[2026-09-18 框选的框不跟鼠标](2026-09-18-marquee-anchored-at-stale-scroll-offset.md)
之后，同一个换算式第二次被外部因素打破：那次坏在「量取得不对」，这次坏在「量对
了，但式子少了一项」。

## 修法

两轴一起钉，一行：

```swift
.frame(minWidth: viewportWidth, minHeight: viewportHeight, alignment: .topLeading)
```

`viewportWidth` 和 `viewportHeight` 都早就在 `@State` 里跟着同一个 `GeometryReader`
量了，不用新接线。内容比视口大时这行不起作用，两向滚动照旧。

`contentWidth` **一个字没动**（产品决策：轨道底色仍然止于内容末尾，不铺满整
个视口）。这一行只改「内容整体摆在哪儿」，不改「内容有多宽」。

**注意它不做什么**：`minWidth` 只是把内容**摆**到左上角，`scrolledContent` 那层
ZStack 自己仍然是 `contentWidth` 宽，所以它的 `.contentShape` / `.onDrop` 命中区
**没有**跟着铺满视口 —— 内容右边那片空白照旧不接受拖放、也起不了框。要改那个是
另一件事（得动 `contentWidth` 或给 ZStack 单独加命中面），这一刀不碰。

## 怎么验的

1. **探针实测**（上表）：修前 `minX = 300`，修后 `minX = 0`。
2. `swift build --arch arm64` 通过。
3. `bash checks/timeline-drag-wiring.sh` 绿。
4. **反向验证**（两种失败形态都红过）：
   - 把那一行换回修复前的 `.frame(minHeight: viewportHeight, alignment: .top)` → 红；
   - 整行删掉 → 红；恢复 → 绿。

## 守卫

`checks/timeline-drag-wiring.sh` 里原来那一节（「滚动内容必须填满视口」）扩成两
轴，断言升级为单行匹配
`minWidth: viewportWidth, minHeight: viewportHeight, alignment: \.topLeading)`。

仍然必须写成**同一行**上的匹配：拆开写的话 `alignment: .topLeading` 会被上一行
的 `.frame(width: contentWidth, alignment: .topLeading)` 顺手匹配掉，对齐那条就是
永远为真的假绿（上一次已经栽过一回）。同时 `grep -A` 的行数从 12 提到 18 ——
注释写长了之后 12 行够不到断言那一行，扫空 = 假绿。

## 教训

1. **SwiftUI 的 `ScrollView` 在两根轴上都会居中**。修了一根轴就以为修完了，另一
   根轴会在另一种常态下（这次是「工程短 + 窗口宽」）原样复发。守卫当时只钉了报
   过 bug 的那一半，所以也拦不住。凡是「内容尺寸可能小于视口」的容器，两轴一起钉。
2. **`视口坐标 + 滚动量 = 内容坐标` 这个式子有前提**：内容的原点必须真的贴在滚动
   区原点上。任何让内容整体位移的布局（居中、padding、`.offset`）都会让这条式子
   少一项，而**只有用绝对坐标的框选会露馅**，别的手势走 translation 相对量，误差
   自己抵消了 —— 所以这类 bug 永远是「看起来只是界面歪了」，实际手势也已经错了。
   长期约束见
   [拖动手势](../architecture/timeline-drag-gestures.md)。
