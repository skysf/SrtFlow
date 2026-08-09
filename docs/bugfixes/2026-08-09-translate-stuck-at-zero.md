# 2026-08-09 第二次翻译永久卡在 0/N：configuration 没换代，SwiftUI 就不重跑 action

- **日期**：2026-08-09
- **来源**：用户实机报告（真实课程工程，127 条 cue，en → zh）
- **相关**：[architecture/subtitle-language-flow](../architecture/subtitle-language-flow.md)、
  [2026-08-09-subtitle-translate-after-same-language](2026-08-09-subtitle-translate-after-same-language.md)、
  [2026-08-06-subtitle-generation-review](2026-08-06-subtitle-generation-review.md)（同一条
  「continuation 谁来收尾」的教训）

## 症状

「重新生成英文字幕 + 翻译成中文」：生成成功（127 条 cue、source=en），翻译区
进度条停在 **0/127** 不动，「Translating…」一直转，只能按 Stop。工程文件里
`translation cues = 0`。

**关键是它不是每次都发生**：第一次翻译好好的，紧接着第二次同样 en→zh 就必卡。

## 根因

`TranslationSession.Configuration` 是**带 `version` 字段的值类型**，`==` 把
version 一起比：

```swift
public struct Configuration : Equatable {
    public var source: Locale.Language?
    public var target: Locale.Language?
    public var version: Swift.Int { get }
    public mutating func invalidate()
}
```

而 `TranslationJobCoordinator.translate` 每个任务都**现新建一个**：

```swift
pendingJob = PendingJob(
    id: jobID,
    configuration: TranslationSession.Configuration(source: source, target: target)
)
```

新建出来的 version 恒为 0，于是**两次同样语言的任务拿到的配置完全相等**
（实测 `a == b` 为 true）。SwiftUI 的 `.translationTask(configuration)` 按
「配置变了才重跑 action」的语义判定「没变化」，action 不再执行 ——
`run(session:jobID:)` 永远收不到 session，`withCheckedThrowingContinuation`
的那条 continuation **永久悬挂**：phase 停在 `.running(0, 127)`，面板 0/127。

中间那次 `pendingJob = nil` 救不了：`.translationTask(nil)` 只是「当前没有
session 要开」，它不会重置 SwiftUI 记住的「上一次跑过的配置」。

Apple 给的换代通道就是 `invalidate()`（version +1、语言保留）——
这正是这套 API 里 `version` 和 `invalidate()` 存在的理由，我们没用上。

**为什么之前所有验证都没抓到**：分支上的两次真窗口冒烟，一次落在
「同语种 → 翻译跳过」（根本没提交翻译），一次是**首次**翻译。
「第二次」这个条件从来没被跑到过。

## 修复

1. **`TranslationConfigurationVendor`**（新文件，纯值逻辑）：一条流水线、
   **每次都 `invalidate()`**，语言变了就改字段而不是重建，于是 version 在
   App 生命周期内单调递增，**任何两次发出的配置都不相等**。
   > 刻意不写成「语言相同才复用、不同就新建」：新建的 version 从 0 起，
   > 语言在 A→B→A 之间来回切时又会和更早那份撞上。只保留一条流水线是唯一
   > 不用推理时序就成立的写法。
2. **起跑看门狗**：发布 `pendingJob` 后 10s 内没有 action 认领，就如实报
   「Translation didn't start. Close the panel and try again.」并收尾
   continuation。耗时的真活（模型下载、逐批翻译）都发生在 `run` **之后**，
   所以它只看「有没有起跑」，不会误伤慢任务。
   **「总会有人收」是悬挂的前奏** —— 这条 2026-08-06 的教训当时只落在
   「取消」路径上，这次证明「SwiftUI 不肯重跑 action」是同一类悬挂。

## 验证

**根因定位（先把系统摘干净）**：

- `checks/SubtitleGenSpike translate en zh "Welcome back."` → `installed`、
  译出「欢迎回来。」；en→zh-Hans、en→zh-Hans-CN 同样正常。
- 生产同款批量形态（`prepareTranslation()` + `translations(from:)` 32 条一批 ×
  127）独立探针：4 批全成，总耗时 ~4s。**系统和批量 API 都没问题。**
- `Configuration` 探针：新建两份同语言配置 `a == b == true`（version 都是 0）；
  `invalidate()` 后 version=1、不再相等、语言保留。

**真机复现与确认（用户授权的真实工程，全程只动副本）**：

- 面板「Translate All」第一次：**Translated 127 cues.**（<25s）
- 紧接着第二次（同样 en→zh）：**卡在 0/127**，60s 后仍是 0/127 —— 与用户
  截图一致。按 Stop 能收回（这是修复前唯一的逃生出口）。
- 修复后同一序列：见下方「修复后实测」。

**守卫（做过反向验证）**：`checks/TranslationPreflight` 新增 8 条 ——
先钉住外部事实（新建两份相等、invalidate 后不等、语言保留），再钉发放器的
硬不变量（连发 6 次含 A→B→A 两两不等）。把发放器退回「每次新建」
（= 修复前的生产写法）实测**红 2 条**，其中一条正是判别用例。
另加三条接线守卫：coordinator 必须经发放器取配置、**不许**自己
`TranslationSession.Configuration(source:`、必须装起跑看门狗。

## 教训 / 防回归

1. **值类型里的 `version` 字段就是在提醒你「这个值需要换代」。**
   `Configuration` 同时提供 `version`（只读）和 `invalidate()`（mutating），
   等于明说「相同内容的两份是同一份，要重来得自己换代」。看到这种成对的
   API，先问「我这条路径上会不会连续提交两份内容相同的值」。
2. **「第一次成功」不能当成这条路通了。** 分支上两次冒烟一次跳过翻译、
   一次是首次翻译，**第二次**这个条件从没被覆盖。凡是「提交 → 等回调 →
   清空 → 可以再提交」的循环，验收必须**连做两次**。
3. **等外部框架回调的 continuation 一律配看门狗。** 取消有通道、失败有
   catch，唯独「对方根本没来」没人管 —— 那正是无限转圈的形态。
