# 2026-09-21 时间线右边小半个视口是死区：点不动、也拉不起框

做「点非素材处移动播放头」这一刀时顺带发现并修掉的。它自己是个独立的既有
缺陷，从时间线支持双向滚动（2026-09-18）起一直在。

## 症状

工程短、窗口宽的时候（一条 6 秒素材 + 1200pt 宽的窗口就够了），轨道底色明显
止于窗口中间，**右边那一大片黑区对鼠标完全没反应**：

- 在那儿按下拖动，拉不起选择框；
- 在那儿点一下，已有的选择也不会被清掉。

看起来像"那片本来就不是时间线"，但它确实在滚动区里 —— 往下滚、往右滚都会
带着它一起动，标尺的刻度也一路画到更右边。

## 根因

滚动内容的命中区只有 `contentWidth` 宽，而 `contentWidth` 有个 **600pt 的地板**：

```swift
var contentWidth: Double { max(600, project.duration * pps + 320) }
```

6 秒素材在默认缩放下只占 ~150pt，加上 320 的尾部空白还够不着 600，于是内容宽
就是 600pt —— 视口有 920pt，右边 320pt 是 `.frame(minWidth: viewportWidth …)`
替它撑出来的空白。

而 `.contentShape(Rectangle())`（以及挂在它后面的点击、框选）当时排在那个
`minWidth` frame **前面**，盖住的只有 `contentWidth` 那一段：

```swift
ZStack { … }
    .contentShape(Rectangle())     // ← 命中区在这里定死 = contentWidth 宽
    .onTapGesture { … }
    .gesture(marqueeGesture, …)
    // ↓ 外面（ScrollView 里）才撑到视口宽，撑出来的部分没有命中区
    .frame(width: contentWidth, alignment: .topLeading)
    .frame(minWidth: viewportWidth, minHeight: viewportHeight, alignment: .topLeading)
```

**纵向没事纯属巧合**：播放头那条线带着 `.frame(maxHeight: .infinity)`，ZStack
被它撑到了视口高，所以轨道**下方**的空白一直是能点的。两根轴看起来一样，只有
一根有人撑着。

这也是 [2026-09-20](2026-09-20-playhead-line-broken-and-ruler-dead.md) /
[2026-09-21](2026-09-21-timeline-content-centered-horizontally.md) 那两条
「内容比视口小」的第三种表现：前两次修的是**内容摆在哪儿**（别被居中），
这次是**撑出来的空白算不算内容的一部分**（要能点）。

## 修复

把两个尺寸 frame 从 `ScrollView { }` 里挪进 `scrolledContent`，让命中区排在
「填满视口」**之后**：

```swift
    .frame(width: contentWidth, alignment: .topLeading)
    .contentShape(Rectangle())
    .onDrop(of: [FilterDrag.type], …)        // ← 故意只盖到内容区
    .frame(minWidth: viewportWidth, minHeight: viewportHeight, alignment: .topLeading)
    .contentShape(Rectangle())               // ← 盖住撑出来的空白
    .onTapGesture(coordinateSpace: .local) { … }
    .gesture(marqueeGesture, …)
```

`.onDrop`（从滤镜库拖卡片进来）**故意留在内容区那一层**：右边撑出来的空白在
时间轴上远远超出工程长度，而滤镜段不计入 `duration`（2026-09-21 口径），落到
那儿就是凭空多出一段谁也看不见、也滚不到的调色。

轨道底色仍然止于 `contentWidth`，**视觉零变化** —— 改的只有命中区。

## 验证

真机注入（SrtFlowDev，6 秒素材 + 1200×860 窗口，内容宽正好落在 600pt 地板上）：

- 从右边那片空白往左拖过素材 → 素材被框中（检查器从 Project 变成
  `smoke 1280×720 · 0:06`）。修之前这一拖什么都不会发生。
- 在那片空白里点一下 → 播放头挪到 0:06.0（被夹在片尾），选择被清空。

守卫 `checks/timeline-drag-wiring.sh` 新增顺序断言，并做了反向验证：把
`.contentShape` 挪回 frame 前面 → 红；把盖住空白的那层 `contentShape` 删掉
→ 红；改回来 → 绿。

## 教训 / 防回归

- **`.frame(minWidth:minHeight:)` 撑出来的空白不会自带命中区。** 尺寸约束和
  命中区是两件事，修饰符的顺序决定后者盖多大 —— 而这件事在界面上看不出来：
  那片空白画得和别处一模一样，只有"点了没反应"这一个征兆。
- **别拿「另一根轴没事」当作这根轴也没事的证据。** 这次纵向是被播放头的
  `maxHeight: .infinity` 顺手撑住的，跟命中区的写法无关；两轴的结论碰巧不同，
  正好把问题藏了三天。
- 长期约束写在
  [时间线拖动手势 §5e](../architecture/timeline-drag-gestures.md)，守卫按
  **行号比大小**钉顺序（对比的是最后一个 `.contentShape`，因为前面还有一个是
  给滤镜拖放用的）。
