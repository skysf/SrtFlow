# 2026-09-18 预渲染把该让位给转场的画面渐变烤进了中间片

## 症状

主轨上一段**带关键帧动画**的素材，同时满足三件事时：

1. 设了画面渐变（`videoFadeOutDuration > 0`）；
2. 这一边的接缝上有转场；
3. 导出。

预览里那条渐变是**不生效**的（接缝整个归转场管），成片里却还在淡黑 ——
转场处先暗下去一块再交叉淡变。「预览让位、成片还在淡」，正是两条管线同账
这条合同要防的那种分叉。

今天要凑齐关键帧动画才撞得上，所以一直没人报。2026-09-18 把入/出场动画
和画面渐变合并成一个槽之后，`In=Fade + Out=Rise` 这种再普通不过的组合就会
走上这条路，于是当场修掉。

## 根因

带逐帧动画的段导出前要先用**预览同一套合成**渲成中间片
（`AnimatedClipPrerenderer`）。而那条临时时间线里**只有这一段**：

```swift
var state = TimelineState()
state.mainClips = [normalized(clip)]   // 没有邻居，transitionAfter 也被清成 .none
```

于是合成器里那句仲裁

```swift
VideoFade.effective(clip:hasTransitionBefore:hasTransitionAfter:)
```

拿到的必然是「两边都没转场」，渐变原样生效、被烤进中间片的像素里。
回到主图之后，ffmpeg 这一侧又按转场接了 `xfade` —— 两段衰减相乘，
接缝处压出一个坑。

真正的非预渲染路径（`transformSteps`）是**对的**：它拿分节表算
`hasTransitionBefore/After`，有转场就不挂 `fade`。两条路一个对一个错，
因为仲裁被抄成了两份，而预渲染那份没有上下文。

## 修复

仲裁在**外面**做完再传进去，预渲染不再自己判断：

- `AnimatedClipPrerenderer.renderMain/renderOverlay` 新增
  `fades: FadeWindow` 参数，`normalized(_:fades:)` 把它写回临时段的
  `videoFade*` 字段；
- `VideoEditExportGraph.plan()` 里的预渲染循环**移到分节之后**，判据与下面
  非预渲染分支那句 `VideoFade.effective` 逐字相同（`segments[i-1].transition`
  / `segment.transition`）——分节表才知道"转场只在两段真的首尾相叠时成立"。

顺带的好处：入/出场动画的时长就是这两个字段，所以这一手把动画那一侧的
转场仲裁也一并做了（`ClipPreset.effective` 在临时时间线里读到的是 0，
效果自动归零）。

关键文件：`Sources/SrtFlow/VideoEditPrerender.swift`、
`Sources/SrtFlow/VideoEditExportGraph.swift`。

## 验证

`checks/VideoFade` 第 5 组（真跑导出、真抽帧）：白段带恒等关键帧动画 +
`videoFadeOutDuration = 1` + 接缝 0.5s 叠化，量 t=1.4s 的整幅亮度 ——
那一刻在"被烤进去的渐出"窗口里、还没进转场窗口。

- 修复后：0.98（满白）✓
- **反向验证**：临时撤掉 `normalized` 里那两行写回，守卫当场变红，
  实测 0.584 —— 正是 60% 亮度的那一帧。

回归面：`scripts/check-video-fade.sh`、`scripts/check-preview-composition.sh`
（预渲染的两组中间片断言）、`scripts/check-project-file.sh`、
`scripts/check-all.sh` 全绿。

## 教训 / 防回归

**给"临时时间线"渲东西时，凡是依赖邻居的量都必须由调用方算好传进去。**
预渲染的临时状态天生没有上下文：没有前后段、没有转场、没有轨道层级，
任何在里面重新做的仲裁都会得到"世界上只有我一段"这个错误答案。

同一条约束的另一面是「仲裁只能有一处」：`VideoFade.effective` 已经是画面渐变的
唯一收口，预渲染却在它之外又隐式判了一次（判据是"临时时间线里没转场"），
两份判断迟早分叉。长期约束写在
[画面段的入场 / 出场动画](../architecture/clip-animation.md#三条容易踩的线)。
