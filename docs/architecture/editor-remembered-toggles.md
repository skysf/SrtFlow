# 剪辑页上记住的开关：磁吸 / 吸附 / 联动 / 播放跟随，和字幕列表的跟随

> 2026-10-01 用户拍板。来由：播放预览时白色播放头走到视口右边，时间线自己翻了一页，用户要
> 「正常播放，但轨道区域停在哪里就停在哪，不要去动」。顺带把工具栏那几个开关从「每次启动回到默认」
> 改成记住。这是产品决定，不是 bug，所以没有 bugfix 案例；拍板的原话和取舍记在这里。

## 一、拍过的板（2026-10-01）

| # | 板 | 为什么 |
| --- | --- | --- |
| 1 | **播放跟随是开关，默认关。** 关着：播放头可以走出视口，停下来也不滚回来。开着：照旧翻页式跟随 —— 播放头到视口右边 80pt / 左边 40pt 以内才推一下，推到视口左侧 15% 的位置 | 用户：播放时轨道区域停在哪就停在哪。开关留着是因为有人（或他哪天）想要；平滑跟随不做：那要播放中每一跳都推滚动，整条时间线一秒重算二十遍，和 [播放丝滑](../plans/2026-09-25-smooth-playback.md) 的方向相反 |
| 2 | 停下来时播放头在视口外：**不动** | 按空格停下多半是想看眼前这一块。想找播放头，以后可以加「滚到播放头」的快捷键，这次不做 |
| 3 | 剪辑页的字幕列表「播放时滚到正在说的那句」：**默认关**、按钮留着、记住。烧录页的字幕表**不动**（默认跟、不记） | 烧录页上跟着看字幕是核对的主要用法 |
| 4 | Return / Home 回到开头照旧滚回最左，播放中按也滚 | 那是用户自己按的，开关不管它 |
| 5 | 磁吸、吸附、链接（2026-10-02 起叫联动）、播放跟随**四个工具栏开关一起记住**（UserDefaults，全 App 一份，不进工程文件）；字幕列表那个也记 | 用户：「这四个最好一起都是被记住的」。此前三个每次启动回到默认（[拖动手势 §4.5](timeline-drag-gestures.md) 2026-09-18 口径里「不写 UserDefaults」那一句作废，默认值不变） |
| 6 | **2026-10-02 改：磁吸跟着工程走**（同剪映，每个草稿各记各的）。开没开是 `state.mainMagnet`：进撤销栈、存进工程文件，老工程缺键 = 关；记住的那个只当**新建工程**的默认。另外**改别的永远不动 V1**：只有改到了 V1 的排布、或者磁吸这次才拨开，才排紧 | 南极工程（[案例](../bugfixes/2026-10-02-magnet-closes-v1-gaps-on-any-edit.md)）：磁吸被记住为开，打开一个 V1 有缝的工程，改一条音量曲线整条 V1 就被合拢、联动把 97 样东西跟着挪。剪映草稿里存着 `maintrack_adsorb`（这台机器上 37 个草稿 15 关 22 开）。第 5 条对吸附、联动、播放跟随照旧 |

**会改工程内容的开关是工程的属性**：吸附、联动、播放跟随只影响「之后怎么拖、怎么播」，记在全 App 一份没问题；磁吸决定 V1 上的东西在哪，
全局记住它就等于让上一个工程的设置去改下一个工程。以前这里写着「磁吸记住为开时，打开有缝的工程，第一次改动合拢」并当成预期行为 —— 那是错的，
2026-10-02 起：打开工程不改工程，磁吸照文件里的（老文件 = 关）；磁吸开着也只在改到 V1 的排布时排（`MainMagnet`）。

## 二、默认值和记忆只有一份：`EditorToggles`

`Sources/SrtFlow/EditorToggles.swift`。键、默认值、读、写都在这一个类型里，别处只调它：

| `Key` | UserDefaults 键 | 默认 | 谁读初值、谁回写 |
| --- | --- | --- | --- |
| `.magnet` | `magnetEnabled` | 关 | **只当新建工程的默认**：`VideoEditProject.newTimeline()` 读；拨工具栏开关走 `setMagnet` 回写。工程自己的磁吸是 `state.mainMagnet`（存进工程文件、进撤销栈），`VideoEditProject.magnetEnabled` 是给界面读的只读镜子 |
| `.snapping` | `snappingEnabled` | **开** | `VideoEditProject.snappingEnabled` |
| `.linkage` | `linkageEnabled` | **开**（2026-10-02 起） | `VideoEditProject.linkageEnabled`（联动，[timeline-linkage.md](timeline-linkage.md)） |
| `.followPlayhead` | `timelineFollowsPlayhead` | 关 | `VideoEditProject.timelineFollowsPlayhead` → 时间线按值传给 `TimelinePlayheadLines(follows:)` |
| `.subtitleListFollows` | `subtitleListFollowsPlayback` | 关 | `VideoEditSubtitlePanel` 的 `@State followsPlayback`（`onChange` 回写） |

- **默认值的字面量就是产品口径**：磁吸默认关是因为这个用户的剪法就是留着间隙，吸附默认开是因为它不改任何自动行为
  （2026-09-18）；播放跟随、字幕列表跟随默认关（2026-10-01）；**联动默认开**（2026-10-02，同剪映：压在主轨块上的东西跟着
  它挪、跟着它删，关着剪掉一段之后后面的字幕、音效全错位；以前叫「链接」、默认关，理由「分离音频就是为了单独动它」在联动下
  照样成立 —— 拖音频本身永远只动音频）。
  顺手「改回 true」会静默改掉整个剪辑手感，所以守卫按字面量钉。
- 没记过、或记的不是布尔 → 默认值。写回只在 `didSet` / `onChange` 里，拨一下记一下。
- 这几个键**别处不许**拿字符串直接去 `UserDefaults` / `@AppStorage` 读：那样就绕开了下一节的规矩（守卫钉着）。
- 四个工具栏开关在自己的小视图 `TimelineToolbarToggles` 里拨（`VideoEditToolbarIcons.swift`）：拨一个只重算这一小块，
  编辑器根视图不再 `@Bindable`（它 body 里读到的工程属性越少越好，[预览性能 ratchet](preview-perf-ratchet.md) 第十三节）。

## 三、冒烟 / 性能场景起手永远是默认值，拨了也不落盘

`EditorToggles.store` 按 `PerfCounters.isEnabled`（性能测试 `SRTFLOW_BENCH_OUT` 或冒烟脚本 `SRTFLOW_SMOKE_SCRIPT`
开着）分两路：平时是 `UserDefaults.standard`；脚本驱动时是 **nil** —— 读永远给默认值、写丢掉。

为什么：这两样起的是真 App。记住的开关会把这台机器上次拨的状态带进来，场景就不是固定的了 —— 本机存着
「磁吸开」，冒烟里拖一段落地就会被合拢；CI 的 runner 虽然每次都是新机器，规矩也要一样，不然同一份脚本本机和
CI 跑出两样。写不落盘，是免得冒烟里拨过的开关留在 SrtFlowDev 那份 defaults 里、带进下一轮。

- 冒烟的 `toggles` 步骤能拨四个（`magnet` / `snapping` / `linkage` / `followPlayhead`），拨完的值写进日志。
- `-mainWindowSection videoEdit` 这类 `@AppStorage` 的键仍走启动参数域（参数域覆盖 UserDefaults、不写回去），不归这里管。

## 四、播放跟随怎么推：`PlayheadFollow`（纯值）

`Sources/SrtFlow/VideoEditTimelinePlayheadFollow.swift`，不 import AppKit，自检直接编。

- `scrollTarget(playheadX:offsetX:viewportWidth:enabled:)`：开关关着、或视口不到 80pt → 不推；播放头在
  `offsetX + 40` … `offsetX + viewportWidth − 80` 之间 → 不推；越过了 → 推到 `x − viewportWidth × 0.15`
  （可能是负的，交给 `TimelineScrollGeometry.scrollHorizontally(to:animated:)` 夹到滚得动的范围，同缩放锚点的做法）。
- **只碰横向**（§5 的老规矩：锚点双轴的 `scrollTo` 会把正在看下面几条轨的人拽回顶上）。
- 调用处 `TimelinePlayheadLines.followPlayhead`：时钟每一跳调一次、只在播放中。节流（推过一次 0.15 秒内不再推）
  **只在真要推的时候记** —— 它是 `@State`，写一次就多重算一遍；以前关着也每 0.15 秒写一次。
- 开关作为**值**从时间线传进来（`follows: project.timelineFollowsPlayhead`）：拨开关时时间线本体重算一次（罕见的用户动作），
  播放的每一跳仍只有 `TimelinePlayheadLines` 和标尺上的把手订阅时钟（[预览性能 ratchet](preview-perf-ratchet.md) 第十二节）。

## 五、加一个记住的开关

1. `EditorToggles.Key` 加一个 case：UserDefaults 键 + `defaultValue` 里的字面量（写明为什么是这个默认）。
2. 用的地方初值 `EditorToggles.read(.x)`，改了 `EditorToggles.write(.x, …)`（工程属性放 `didSet`，视图的 `@State` 放 `onChange`）。
3. 工程上的属性要进 `SmokeProjectChanges.watched`（冒烟起手对 `Mirror`，漏了直接报错）。
4. 自检 `checks/TimelineZoom/TogglesChecks.swift`（个数、默认值）和守卫 `checks/timeline-drag-wiring/toggles.sh`（字面量、接线）跟着改。
5. 第二节的表补一行。

## 六、守卫

- **纯值**：`scripts/check-timeline-zoom.sh` 第 4 节 —— `PlayheadFollow`（关着到哪都不推；开着只在边上推、推到 15%、边线跟着滚动量走、
  视口 ≤ 80 不推）和 `EditorToggles`（五个默认值、没记过 / 记了 / 记坏了各读到什么、脚本驱动时 store 为 nil 且写了也读不到）。
- **磁吸跟着工程走**：`scripts/check-timeline-snap.sh` 第 1g 组（只在改到 V1 的排布 / 刚拨开时排、南极工程那一步 V1 和压在上面的都不动）、
  `scripts/check-project-file.sh` 第 42 组（按需写键、缺键读作关、往返）、`toggles.sh` 第 11f 节（镜子只读、只经 `setMagnet` 和 `MainMagnet.settle`、新建工程走
  `newTimeline`、AI 看得见）。
- **接线**：`checks/timeline-drag-wiring/toggles.sh` —— 默认值的字面量、工程三个属性从 `EditorToggles` 读初值并回写（磁吸见上一条）、键不在别处出现、
  `store` 按 `PerfCounters.isEnabled` 分、冒烟清单登记、工具栏四个开关在小视图里、时间线把开关传给播放头竖线、
  `followPlayhead` 只问 `PlayheadFollow` 且只碰横向、播放头竖线里推横向滚动正好两处（跟随 + 回到开头）、字幕列表的按钮读写记忆。
- **反向验证（2026-10-02）**：见本文件末尾的记录。

## 七、人工回归

- 工程放大到比视口宽，播放头快到右边时**跟随关着**：时间线一动不动，播放头走出视口（标尺上的把手跟着消失）；按空格停，仍不动；
  再按空格从那儿接着播。**拨开跟随**再播：播放头到右边 80pt 以内翻一页、落在视口左侧 15% 处；拨开时播放头已经在视口外，下一跳就翻过去。
- 跟随开着、滚到下面几条轨再播：横向翻页，**纵向不动**。
- 播放中按 Return：滚回最左、从头接着播（开关关着也滚 —— 这是回到开头，不是跟随）。
- 拨四个开关、字幕列表的跟随按钮，退出 App 再开：吸附、联动、播放跟随、字幕列表跟随都是上次的状态；**磁吸是这个工程自己的**：
  工程 A 拨开磁吸、工程 B 关着，来回切换各是各的；退出再开、打开 A 仍是开的；⌘N 新建的工程是最后拨的那个值。
- 磁吸开着的工程里打开一个**磁吸关着时留了缝**的老工程：磁吸显示为关，缝都在；改字幕、改音量、往 V2 放东西，缝都在。
  拨开磁吸：缝合上（一步，⌘Z 连开关一起退回去）。
- 磁吸开着、V1 却有缝（手改过的工程文件）：改配乐音量、改一句字幕 —— V1 一段都不动；裁 V1 上的一段 —— 整条排紧。
- 剪辑页字幕列表默认不跟着滚；拨开后播放滚到正在说的那句。烧录页的字幕表照旧默认跟。
- 跑一遍进程内冒烟（`scripts/gui-smoke/in-process/run.sh`）：本机存着「磁吸开」也不影响落点；日志里 `toggles` 一步写出四个值。

## 反向验证记录（2026-10-02，逐条撤掉、确认红、恢复后再全绿）

| 撤掉什么 | 哪条红 |
| --- | --- |
| `PlayheadFollow.scrollTarget` 不看 `enabled`（关着也推） | `check-timeline-zoom.sh`：「开关关着时播放头在 0 / 39 / 721 / 3000 也不推」等 7 条 FAIL |
| `EditorToggles.Key.followPlayhead` 默认改成 `true` | `check-timeline-zoom.sh` 2 条 FAIL（「播放跟随默认关」「没有 store 时写了也读不到」）+ `toggles.sh`「播放跟随的默认值不是关」 |
| `EditorToggles.store(scripted:)` 一律 `.standard` | `check-timeline-zoom.sh`「性能测试 / 冒烟开着时没有 store」+ `toggles.sh`「脚本驱动时 store 不是 nil」 |
| `followPlayhead` 传 `enabled: true` 而不是 `follows` | `toggles.sh`「followPlayhead 没把开关交给 PlayheadFollow」 |
| 工程上 `var magnetEnabled = false` 写回字面量 | `toggles.sh`「magnetEnabled 没从 EditorToggles.read(.magnet) 读初值」 |
