# AGENTS.md — 文档索引与协作规则

给 AI 代理与新贡献者的导航页。**本文件只做目录和规则，不写细节**；细节按分类
放在 `docs/` 下。

## 规则（所有 AI / 贡献者必须遵守）

1. **修复任何 bug 后，必须在 `docs/bugfixes/` 写一份案例**（按
   [TEMPLATE.md](docs/bugfixes/TEMPLATE.md)：症状 → 根因 → 修复 → 验证 → 教训），
   文件名 `YYYY-MM-DD-<slug>.md`，并在下方索引里补一行。**自检够得着的层面
   还必须落一条会红的守卫**进对应 check，并做反向验证（临时撤掉修复、确认
   守卫真的红过再恢复 —— 没红过的守卫就是假绿）；自动化够不着的
   （手势手感、TCC、系统 UI）落进对应架构文档的回归清单，发版前人肉过。
2. 案例中沉淀出的**长期约束**（"这里只能这样做"）单独落到 `docs/architecture/`，
   案例里链接过去，避免只存在于一次性记录中。
3. 新增其他文档归入 `docs/` 对应分类目录，并回本文件补一行索引。
4. **语言约定**：GitHub 对外可见的文字一律**英文** —— commit message、
   PR/issue/release 的标题与正文、分支名、Actions 的 workflow/job/step 名。
   README 保持**中英双语**。仓库内部文档（docs/、本文件）与代码注释
   维持现状用中文。

## 全局工程原则（动手写代码前先过一遍）

1. **轻量化优先。** 能白嫖 macOS 现成能力（AVFoundation / AppKit / SwiftUI）
   就不自建，不引第三方依赖；同一个功能有重量级和轻量级两种做法时选轻的，
   重量级方案（自写合成器、自建文件管理这类）必须先问用户。先例：混合模式
   因为要自写 Metal 合成器被否、工程的文件管理整个交给 Finder。
2. **复用优先，抽象克制。** 同一个模式出现**第二次**就抽成共享组件，按仓库
   现有先例的粒度来（`ResizableFrameBox` 同时服务剪辑和形状、
   `LenientCodableEnum` 统一宽容解码、`liveApply`/`perform` 统一改动入口）；
   但别为想象中的将来提前造泛型 —— 有真实的第二个用例再抽象，泛型只用在
   真正多类型复用的地方（提前抽象既违背轻量化，堆多了还会拖垮 Swift 类型
   检查）。
3. **单文件别养大。** 新类型/新功能默认开新文件（按职责命名，先例：
   `VideoEditPreviewTransform.swift`）；单文件超过 **~800 行**就是警戒线，
   新代码别再往超标文件里堆，改到超标文件时顺手把职责独立的块拆出去。
   **不要**为拆而拆地搞一次性大重构。当前超标待瘦身：
   `VideoEditTimelineView`、`VideoEditProject`、`VideoEditModels`。

## 构建（docs/build/）

- [build-and-packaging.md](docs/build/build-and-packaging.md) —
  ⚠️ Rosetta 终端必须 `swift build --arch arm64`、常用命令、打包脚本、产物验收清单

## 测试（docs/testing/）

- [gui-smoke-testing.md](docs/testing/gui-smoke-testing.md) —
  真实窗口冒烟测试全流程：改名启动避同名进程、按窗口 ID 截图、事件注入边界、
  `SRTFLOW_SMOKE_VIDEO` / `SRTFLOW_FFMPEG` 环境变量钩子

**一条命令跑全部：`scripts/check-all.sh`**（聚合下面所有自检 + 扫描守卫，
任何一项红整体就红；CI 在每个 PR 上跑同一条命令，见
`.github/workflows/checks.yml` —— 改完代码、发 PR 前先本地跑它）。

单项自检：`swift run SrtFlowCoreChecks`（核心库）、
`scripts/check-project-file.sh`（工程存盘与素材重链接，源码在 `checks/ProjectFile/`）、
`scripts/check-player-clock.sh`（预览时钟的悬停预览 peek 状态机：播放头不被
悬停拖走、seek/播放/换片终结 peek，源码在 `checks/PlayerClock/`）、
`scripts/check-preview-composition.sh`（预览合成的叠化×变换模型，真取帧量像素，
源码在 `checks/PreviewComposition/`）、
`scripts/check-export-alpha-compositing.sh`（导出画中画动画的 fill+matte 合成，
真跑一遍项目自带 ffmpeg 量输出像素，纯 shell 不依赖 Swift 编译）、
`scripts/check-export-frame-rate.sh`（**真实生产导出滤镜**的帧率回归：调
`VideoEditExportGraph.plan()` 拿生产 ffmpeg 参数、真跑、数帧，源素材故意造成
10fps 以排除源帧透传）、
`checks/no-hardcoded-fps.sh`（扫描守卫：Video Edit 管线里不许再写死帧率，
帧率必须来自 `TimelineState.frameRate`；用文件系统枚举，未跟踪的新文件也覆盖）、
`scripts/check-freeze-frame.sh`（定格的时间线变换：分割+同轨让位+音轨波纹+
叠化区判定+关键帧烘焙，纯值函数无 GUI 无 ffmpeg，源码在 `checks/FreezeFrame/`）、
`scripts/check-still-clip-encode.sh`（**图片转静帧的真实产物**：拿
`StillImageClipFactory.conversionArguments()` 的生产参数真跑，量帧数/时长/两条
尺寸政策/首尾帧 PSNR/动图截断，还有一条**边际耗时**断言守「一张图只解一次」，
源码在 `checks/StillClipEncode/`）

## 规划（docs/plans/）

- [2026-08-06-native-screen-recording.md](docs/plans/2026-08-06-native-screen-recording.md) —
  Edit Video 原生录屏完整方案（ScreenCaptureKit 整屏/窗口/单屏区域、电脑声音 +
  独立麦克风轨、录前选保存位置、主轨末尾导入、工程 24/30/60 fps、全局提升到
  macOS 15）：**Phase 0–4 代码完成、Phase 5 待实机验证**（自动化验证已过，
  真机 picker/TCC/多屏/音频/长时仍未跑）。计划正文有若干条已被 Phase 0 实测推翻（`canApply` 预检、
  固定 69ms 补偿、`SCDisplay.width` 当像素用等）——
  **当前状态与实测结论一律以
  [实施报告](docs/reports/2026-08-06-native-screen-recording-implementation-report.md)
  为准**
- [2026-08-06-native-subtitle-generation.md](docs/plans/2026-08-06-native-subtitle-generation.md) —
  原生字幕生成（SpeechAnalyzer 转写 + Translation 翻译、canonical 原文 +
  companion 译文轨、按需 formatVersion v4、sidecar 词级缓存）：**主体已实现**
  （2026-08-06，含端到端冒烟）。原「基线 .v14 / 按 macOS 14/15/26 分层」已被
  录屏功能的**全局 macOS 15** 取代（2026-08-07，见其顶部注记）：现行分层
  **15/26**，翻译自基线可用、生成需 26+；改这块前必读，剩余实机验证项见其 17.2/17.3
- [2026-08-08-freeze-frame.md](docs/plans/2026-08-08-freeze-frame.md) —
  定格（工具栏雪花 / ⇧⌘F）：**已实现并实机验证**（2026-08-08）。产品参数、
  评审后改掉的提交模型与分辨率政策、已知代价都在正文；长期约束见
  [freeze-frame.md](docs/architecture/freeze-frame.md)

## 实施报告（docs/reports/）

- [2026-08-06-native-screen-recording-implementation-report.md](docs/reports/2026-08-06-native-screen-recording-implementation-report.md) —
  原生录屏 Phase 0–5 的实施记录：环境基线、每项硬门槛的真实结果与证据、偏差、
  阻塞项；**状态与「哪些已验证/未验证」以本报告为准**

## 架构与实现决策（docs/architecture/）

- [timeline-pinch-zoom.md](docs/architecture/timeline-pinch-zoom.md) —
  时间线捏合缩放为什么只能用 local NSEvent monitor（含全部失败方案与回归清单）；
  **改时间线手势/滚动代码前必读**
- [video-edit-project-file.md](docs/architecture/video-edit-project-file.md) —
  `.srtflowproj` 工程格式、为什么不做 App 内文件夹管理、素材重链接的四层线索、
  脏标记与自动保存的唯一入口；**改工程存盘/素材路径/自动保存前必读**
- [timeline-drag-gestures.md](docs/architecture/timeline-drag-gestures.md) —
  块布局原点恒为 0、边缘把手手势必须 `.global` 坐标系（反馈回路）、拖动中的
  动画豁免与异步缩略图去抖；**给时间线加把手/改拖动手势前必读**
- [preview-free-transform.md](docs/architecture/preview-free-transform.md) —
  预览区变换框与 `ClipPlacement`：归一化摆放、九宫格互斥、预览/导出两条管线
  同账（导出用 overlay 不用 pad）；**改预览合成/导出滤镜图/变换框前必读**
- [keyframe-animation.md](docs/architecture/keyframe-animation.md) —
  关键帧动画：源时间锚定（变速/分割自动正确）、切片规则（旋转 ≤6°/片）、
  导出走 AVFoundation 预渲染 + 画中画 fill+matte；**改动画/预渲染前必读**
- [project-frame-rate.md](docs/architecture/project-frame-rate.md) —
  工程帧率的唯一事实来源（`TimelineState.frameRate`）、v5 无条件落盘、关键帧
  容差**分空间**（source 侧 × |speed|、timeline 侧不乘）、各回归各守什么与
  各自的局限；**改帧率/关键帧容差/导出滤镜前必读**
- [screen-recording-lifecycle.md](docs/architecture/screen-recording-lifecycle.md) —
  录屏状态机（写盘期无直达 `.failed`、importing/partialRecovery 持锁）、提交
  journal（rename 前先 persist、恢复=stage×目录观察、卷不可达不清 manifest）、
  请求快照（全 `let`、显式 sessionID）；**改录屏生命周期/恢复/状态机前必读**
- [inspector-scrub-number-field.md](docs/architecture/inspector-scrub-number-field.md) —
  Inspector 数值框：离散/live 两条写入路径、拖调取消收尾、拒绝自动聚焦、
  cursor rect 局部光标；**改数值框/拖调/Transform 写入入口前必读**
- [freeze-frame.md](docs/architecture/freeze-frame.md) —
  定格：复用图片素材管线不写合成器、**转码成功后一次性提交**（CAS + 单飞 +
  `committed` 以时间线为准）、PNG 归属与清理、波纹只到主轨+音频、抽帧零容差
  与叠化区禁用、关键帧烘成静态值、纯值变换必须留在 `VideoEditTimelineEdits`；
  **改定格/静帧管线/时间线插入前必读**
- [subtitle-language-flow.md](docs/architecture/subtitle-language-flow.md) —
  字幕面板语言流：目标语言必须当着用户的面选定、翻译入口一律预检
  （同语种/unsupported 提交前拦下）、生成后翻译遇同语种=跳过不是失败、
  TranslationError 不许原样透传、Auto-detect 两段式检测合同与人肉回归清单；
  **改字幕面板/翻译服务/转写任务的语言逻辑前必读**
- [subtitle-track-visibility-and-layout.md](docs/architecture/subtitle-track-visibility-and-layout.md) —
  字幕轨可见性与工程级布局：眼睛走 `visibleSubtitleDocument` 单一收口
  （文件导出故意豁免）、SubtitleLayout 只有 1080p 基准一种坐标系且预览与
  ASS 共用同一份、覆盖后锚定固定底部中心、拖框语义（框体=移动/边=换行
  宽度/角=等比字号）、分段默认单行 + 参数集版本合同；
  **改字幕轨 UI/预览叠层/烧录样式/分段默认值前必读**

## Bug 修复案例（docs/bugfixes/）

- [2026-08-03-trackpad-pinch-zoom.md](docs/bugfixes/2026-08-03-trackpad-pinch-zoom.md) —
  触控板捏合缩放反复"修好"又失败：事件序列锁定 + Rosetta 旧二进制两个根因
- [2026-08-03-project-file-lifecycle.md](docs/bugfixes/2026-08-03-project-file-lifecycle.md) —
  工程文件首版的 11 处数据丢失路径：书签被自动保存抹掉、切工程/退出不看写盘
  成败、导入竞态、静帧静默丢失等；教训是生命周期边界要逐条过失败分支
- [2026-08-03-scrub-preview-keyframe-snap.md](docs/bugfixes/2026-08-03-scrub-preview-keyframe-snap.md) —
  拖播放头/悬停扫块时预览不逐帧刷新：不带 tolerance 的 seek 是无穷容差吸关键帧；
  修成零容差 + 链式 seek（QA1820）防洪
- [2026-08-03-trim-flicker-halved.md](docs/bugfixes/2026-08-03-trim-flicker-halved.md) —
  裁切块闪烁卡顿 + 裁切量恰好半速：把手 .local 坐标系随裁切自移形成反馈回路；
  另修动画豁免与缩略图/波形去抖
- [2026-08-04-editor-tools-review.md](docs/bugfixes/2026-08-04-editor-tools-review.md) —
  评审返工三连：工具模式要整个关掉旧手势（GestureMask 不是 guard 回调）、
  画中画升主轨要丢 placement、线条选中框要按旋转后包络
- [2026-08-04-opacity-green-background.md](docs/bugfixes/2026-08-04-opacity-green-background.md) —
  半透明图层让预览背景变暗绿：默认合成器混合路径不铺 backgroundColor
  （YUV 零填充=绿），修法是垫一条 AVAssetWriter 生成的不透明黑底轨
- [2026-08-04-transform-review.md](docs/bugfixes/2026-08-04-transform-review.md) —
  Transform 评审返工三连：加字段必须升 formatVersion（旧版拒开胜过静默毁字段）、
  叠化「垫底=精确」的前提被变换破坏、缓存文件要「临时名→校验→原子替换」
- [2026-08-04-prerender-avfoundation-pitfalls.md](docs/bugfixes/2026-08-04-prerender-avfoundation-pitfalls.md) —
  预渲染两坑：空轨在 AVPlayer 能播但导出报 "Operation Stopped"；
  backgroundColor 的 alpha 被忽略 → 带透明的产物走 fill+matte 双渲染
- [2026-08-05-inspector-scrub-field-gestures.md](docs/bugfixes/2026-08-05-inspector-scrub-field-gestures.md) —
  Inspector 数值框拖调完全无效：`currentEditor()` 对没在编辑的字段也返回非
  nil、检查器出现时字段被自动聚焦进编辑态；另修 ±1px 被固定归一化容差吞掉
  （容差必须亚像素）。长期约束见 architecture/inspector-scrub-number-field
- [2026-08-05-export-prerender-review.md](docs/bugfixes/2026-08-05-export-prerender-review.md) —
  导出评审三轮六连：预渲染失败删用户目标文件、画中画边缘因预乘 alpha 被
  多乘一次而变暗（`alpha=premultiplied` 实测不生效，改手动除回真实色）、
  预渲染 Stop 无效+泄漏临时文件；复审又抓到三个：Stop 点在 build() 期间
  崩溃整个 App（对未起跑的 session 调 cancelExport() 再 export()，这个
  修了两版——原子登记不够，`exportAsynchronously` 的启动动作必须进临界区）、
  修复本身把 fill 的 opacity 除没了（除法只测了 coverage 没测 opacity）、
  ffmpeg 成功后提交前还有一条没查的取消窗口
- [2026-08-06-subtitle-generation-review.md](docs/bugfixes/2026-08-06-subtitle-generation-review.md) —
  字幕生成评审返工十连 + 二至五轮共十四连：长素材缺口必须切窗逐窗落盘、
  跨 await 写回要带 generation+快照双守卫（且 generation 挡不住同工程改
  时间线 —— 写回一侧用当下状态重算或对映射输入 CAS）、纯音频 clip 的
  info 为 nil（指纹要回退磁盘线索）、可听性只有 CompositionBuilder 一份
  合同、`.onSubmit` ≠ 编辑结束且兜底提交自身要 dirty+CAS、取消检查的
  完备面 = 每个 await 前后 + 终态提交前且要逐阶段核对取消通道（下载靠
  Progress.cancel）、「不存 session」包括不存它的衍生闭包（取消动作留在
  withTaskCancellationHandler 的结构化作用域）、continuation 收尾责任按
  状态机点名（queued 取消当场自收）、**身份要随触发源传递**（jobID 绑
  configuration 进 action、回调捕获 token 执行时 CAS，进门才读「当前值」
  等于没有身份）、App 级 reservation 走引用计数账本且清理在终态前
  await 完成（fire-and-forget 会拆掉新任务的租约）、租约语义写死
  （成功=调用方持有）、覆盖类账本宁缺毋假（静默跳块 = 永久缺口）、
  catch 面 = 责任面、错误路径禁止返回成功零值、预览堆叠方向要对齐
  libass（最早在最底）、缓存读时 touch 才是真 LRU + checksum 信封；
  共性：每轮修复自身就是下一轮 P1 的攻击面
- [2026-08-06-build-version-and-shell-traps.md](docs/bugfixes/2026-08-06-build-version-and-shell-traps.md) —
  打包脚本写死 `VERSION:-0.3.0` 默认值，发到 0.4.1 后不传 VERSION 就静默打出贴错
  版本号的 DMG（dist/ 里真有两个）；改成兜底取 git tag。修它时又踩两个 shell 陷阱：
  裸 `$VAR` 紧跟中文会把多字节首字节吃进变量名（`set -u` 直接挂，与 bash 版本/
  locale 无关），`pipefail` 下 `VAR="$(a|b)"` 会在赋值处就死掉、绕开自己写的报错。
  **改 `.sh` 前必读**
- [2026-08-06-subtitle-panel-language-defaults.md](docs/bugfixes/2026-08-06-subtitle-panel-language-defaults.md) —
  字幕面板默认翻译成阿拉伯语（源语言未知时全表状态占位，「已装优先」的排序退化成
  字母序，且自动挑的默认值会一直粘着等不到重挑）、对每个语言都假称「需要下载」、
  segmented 样式下逐项 `.disabled` 不生效导致点一下预览字幕静默消失。
  教训：占位值不许参与排序/判断/对用户断言；「默认值」和「用户的选择」必须可区分
- [2026-08-06-stale-bundled-license-notice.md](docs/bugfixes/2026-08-06-stale-bundled-license-notice.md) —
  换成 AGPL-3.0 之后，打出来的包里那份授权声明仍写着 MIT：它由
  `vendor-ffmpeg.sh` 生成、`vendor/` 又不入库，只在**重新下载 ffmpeg** 时才刷新，
  `git grep` 也查不到。修法是加 `--readme-only` 模式，打包时现生成再拷。
  教训：改生成器 ≠ 改产物；全仓文案替换要额外查一遍 .gitignore 覆盖的产物目录
- [2026-08-07-screen-recording-foundation-review.md](docs/bugfixes/2026-08-07-screen-recording-foundation-review.md) —
  录屏地基复审抓出七个问题，**其中四个是测试成功地守住了错误行为**（假绿）：
  工程 v5 把「默认值省略不写」当无害（旧版按硬编码 30fps 打开 = 同一文件出不同
  成片）、多屏翻转轴用了并集顶边而**错误公式同样自反**所以往返测试测不出、
  alpha 三档参数化因脚本抛异常没落盘却报告「全过」、磁盘开录阈值 200MB 低于
  运行期警戒线 500MB、坐标入口文档说返回 nil 实现却静默裁剪、扫描守卫用
  `git ls-files` 漏掉未跟踪文件、把声学测得的 69ms 当成通用常量补偿。
  教训：**往返/自反断言几乎测不出正确性，必须有外部真值对账**；
  每个守卫都要反向验证；脚本改完先验证落盘再报告。第二轮又修 3 个 P1：
  写盘期不得有直达 `.failed`（解锁态）的边、manifest 要 journal 式记 rename
  意向（两步操作中间全是崩溃窗）、「快照」必须类型上不可变（全 `let`）。
  第三轮再修 3 个 P1：**UserDefaults 是异步落盘，不能当持久化栅栏**（改单文件
  原子写的 ManifestStore）、已提交阶段也要实测 final 在不在且「缺失」≠「卷不
  可达」、manifest 身份与路径全 `let`；另修 `exit()` 绕过顶层 `defer` 的
  自检泄漏（previewcheck 攒了 52 个目录）。第四轮修「拿文件现场当清账判据」——
  能否清 manifest = 现场有结论 **且** 流程走完，缺一维就会留下孤儿文件；
  并清掉 canonical 计划里被否方案的旧合同。
  **加自检/守卫/状态机前必读**
- [2026-08-07-screen-recording-phase2-4-review.md](docs/bugfixes/2026-08-07-screen-recording-phase2-4-review.md) —
  Phase 2–4 复审的 8 个 P1。**病根是"纯函数写对了但没被接上"**：
  `canClearManifest` 生产代码一次没调、`displayLocalRect` 就在那里却给了
  `sourceRect` 全局坐标（主屏原点为零所以看不出、副屏录错区域）。
  另有：恢复弹窗写着「Keep file only」实际删文件（**直接数据丢失**）、
  先 commit 后 probe 让损坏文件覆盖用户目标文件、配置期 Quit 落进
  `default:` 静默 return 导致 `.terminateLater` 永远收不到 reply（死锁）、
  收尾后直接 reply 跳过 `prepareToCloseDocument()`（未命名工程不问保存）、
  picker 前抢读 `SCShareableContent` 让 clean TCC 首跑必废、同尺寸双屏取
  `first` 会录错屏、`.started` 帧被当 idle 丢、idle 帧时间戳不记导致静止画面
  录出 0 秒、writer 停止没有采样队列栅栏、错误只写进已经关掉的设置页。
  教训：**自检覆盖的是「函数算得对不对」，不是「有没有被调用、参数对不对」**；
  验证必须在破坏之前；用户没确认过的覆盖一律避让；按钮文案就是合同；
  涉及异步 reply 的状态机分支必须穷举，不能留 `default:`。
  **同日第二轮**又抓出 8 个静态可判定的 P1：`MediaProbe` 无视频轨就抛错，
  拿它探纯音频 sidecar → **麦克风轨永远进不了时间线**；`offerSalvage` 的
  `main: nil` 被回退成不存在的路径 → **自检覆盖到的那一格，生产代码照样删
  用户的 mic 录音**；避让后的目标名在落 `committing` 意向**之后**才决定 →
  journal 身份被破坏；commit 失败仍清账；`recoverIfNeeded` 挂在会重跑的
  视图 task 上 → 录制中切回来会处理**当前正在写的** manifest；恢复导入
  期间无工程锁也无 generation CAS；`didStopWithError` 先置空 `stream` →
  后续 `stop()` 的采样队列栅栏整段跳过；音频成功契约从不验证。
  教训：**复用工具函数前先读它的前置条件**；**断言产出正确答案 ≠ 消费端
  用对了它**；「先落意向」的意向必须**包含最终目标**；异步回调里提前置空
  句柄会让后续清理整段失效。
  **第三、四轮**又各修 5–6 个 P1：`defer { if isBusy { 回 idle } }` 的终点恰是
  `.finished`/`.failed`（都不 busy）→ 状态永久卡住、按钮看着能点没反应；
  `try? load() != nil` 让**损坏账本**被当成没账本、下次录制覆盖它；
  **纯 mic 恢复复用 `committingMicrophone` 阶段** → `mainResolution` 无条件认定
  主文件已提交 → 用户原有的文件被认成本次录屏；可选麦克风的 writer 构造/
  stream 启动失败拖停主录屏；音频只验「有轨」→ 录一个包就断也算成功；
  `try? removeItem` 后无条件清账 → 删除失败就留下无人认领的文件；
  恢复入轨在清账**之前**进 `.finished` → Quit 时可能重复入轨。
  教训：**收尾守卫要检查终点**；「有没有 X」不能用「能不能解析 X」代替；
  **阶段语义不可复用**；可选通道的失败不得写进共用失败态；
  **反证没抓到本身就是发现**（说明那条契约根本没有守卫）。
  **第五轮是真机首测**，5 个问题当场暴露、**自检一个都没抓到**：状态机缺
  `.choosingSource → .choosingDestination` 一条边 → `transition` 静默返回 false
  → **录制永远不会开始**（一切都建好了，就是没按下开始）；音频容差照搬复审的
  「一个工程帧」，而计划自己写着 AAC priming 44ms **已大于一帧** → 每次录制
  都误报 partial；控制窗排除依赖广域授权（与 picker 路径的意义相悖）→ 改用
  `NSWindow.sharingType = .none`；notice `lineLimit(1)` 把权限指引截成半句。
  教训：**端到端走一遍，不能只逐条验单边**（补了 `checkStartHappyPath`）；
  **别把 A 场景的验收标准套到 B 场景**；`@discardableResult` + 静默失败是最难
  查的 bug。另记：系统 picker 文案不可改（只开放四个配置项）；
  Phase 0 的「启动器 + 负载」防 TCC 方案对完整 App 不适用（`execv` 后
  `Bundle.main` 变成负载目录，随包 ffmpeg 找不到）。
  **改 coordinator/恢复/退出/导入路径前必读**
- [2026-08-08-runtime-media-relink.md](docs/bugfixes/2026-08-08-runtime-media-relink.md) —
  工程开着时素材被改名/挪走：预览黑屏零提示、剪辑块一直挂旧名，用户以为是变速
  弄坏了视频。根因是四层重链接只在打开工程时跑；修法是抽出 `relocateMedia`
  在 App 激活和预览重建时重核对。教训：「打开时校验过」≠「一直有效」；
  静默跳过必须有人在上游补提示；缩略图是缓存、不代表素材还在
- [2026-08-08-hover-ghost-playhead-and-delete-key.md](docs/bugfixes/2026-08-08-hover-ghost-playhead-and-delete-key.md) —
  悬停扫块把用户点定的播放头拖走（修成 peek + 影子指针：`time` 是播放头、
  `displayTime` 给画面叠层）+ ⌫ 删不掉选中剪辑（keyCode 51/117 没人接）。
  教训：「预览跟手」和「移动播放头」是两个语义；快捷键和按钮必须指向同一个
  入口；合成点击滞后与 hover 不可注入的边界并入 gui-smoke-testing
- [2026-08-08-still-clip-loop-decode-slow.md](docs/bugfixes/2026-08-08-still-clip-loop-decode-slow.md) —
  图片转静帧慢 20 倍（4K 图 19.4s）：`-loop 1` 的 image2 输入帧率默认 25fps，
  1500 次解码只为 120 帧输出；补 `-framerate 2` 后连原生 4K 都比原来的 1080p
  快 9 倍。教训：循环单图的命令必须显式写死输入帧率（差价完全不体现在产物上）；
  换硬件编码器两分钟就证伪了「编码器慢」；顺带修了半成品缓存（原子改名）
- [2026-08-08-ci-first-run-sdk-and-swallowed-errors.md](docs/bugfixes/2026-08-08-ci-first-run-sdk-and-swallowed-errors.md) —
  CI 首跑 6 项齐红且日志零错误：`swift build >/dev/null` 吞掉 SwiftPM 走
  stdout 的诊断 + macos-15 runner 没有 macOS 26 SDK；修成 macos-26 镜像 +
  失败倾倒输出 + `no-swallowed-build-output` 扫描守卫。教训：部分绿比全红
  更有迷惑性；首个 PR 就是 CI 的验收测试
- [2026-08-08-main-track-array-order-black-frame.md](docs/bugfixes/2026-08-08-main-track-array-order-black-frame.md) —
  图片进主轨黑屏、转画中画就好：磁吸关掉的拖动让主轨**数组顺序 ≠ 时间顺序**，
  A/B 轨游标式插入被 `insertTimeRange` 挤歪（画中画路径有 sorted、主轨没有）；
  修成「改动入口维持 + 打开工程归一 + 消费端防御」三层。顺带修竖版画中画
  默认布局爆出画布（`OverlayAnchor.defaultSize` 三处同账）。三条新守卫都反向
  验证过。教训：同一份数据两条消费路径一条 sorted 一条没 sorted 就是定时炸弹
- [2026-08-08-still-clip-decode-per-frame.md](docs/bugfixes/2026-08-08-still-clip-decode-per-frame.md) —
  同一条命令的第二次性能修复：5MB 图进时间线仍要 5 秒、预览黑屏。`-loop 1` 的
  语义是「重放整个输入」，于是同一张图被解了 120 次（上一次只对齐了次数，
  没质疑重放本身）。改成**解一帧 + `loop` 滤镜复制** + `-frames:v` 截断，
  5.4MB 图 5s → 0.5s、9.5MB 图 8.8s → 0.63s，产物逐字节相同（缓存版本故意不升）。
  顺带修好 gif/heic：`-loop`/`-framerate` 是 image2 专属选项，这两类格式以前
  在开文件那一步就死。教训：修完性能要再量一次**边际**成本；性能断言用
  「多出来的 119 帧 ≤ 一次解码」这种自校准判据，别写死秒数；tile grid 型 heic
  不许用 `-filter_complex "[0:v]"` 绕（会把 4000×3000 悄悄变成一块 512×512 瓦片）
- [2026-08-09-subtitle-translate-after-same-language.md](docs/bugfixes/2026-08-09-subtitle-translate-after-same-language.md) —
  生成后翻译报「Unable to Translate」：目标语言在 Picker 未渲染时被自动敲定，
  英语系统上恰好等于源语言 → en→en 自我配对；系统对一切配对失败只回同一句
  通用文案、且无物可下载所以永远不弹下载确认，用户把红字安在了失败后才显示
  出来的中文头上。修成：目标语言必须可见才可被消费 + TranslationPreflight
  提交前预检 + 同语种按跳过处理 + 错误按 cause 分类；同时源语言默认
  Auto-detect（两段式探针检测）。教训：不可见的控件不许持有可生效的选择；
  上一次修复选出的"好默认值"换条路径就是事故值；「没弹下载确认」是无物可
  下载路径的**特征**而不是故障。长期约束见 architecture/subtitle-language-flow。
  **复审 follow-up 见下一条 —— 那次 review 并没有全过**
- [2026-08-09-pr22-review-followups.md](docs/bugfixes/2026-08-09-pr22-review-followups.md) —
  PR#22 复审四连：①**又忘升 formatVersion**（subtitleLayout/subtitleHidden 落了盘、
  版本号还停在 5，旧版打开→自动保存→排版删光、导出画面跟着变；设了「不烧字幕」
  的工程还会把字幕烧进成片），而守卫写的是 `latestFormatVersion == 5` ——
  自反断言，忘了升照样绿；②自动检测**敢猜**：阈值 0.45 低于实测错误模型的
  0.55（上限 0.74），`pick([错误模型])` 会成功，无 confidence 按 0.5 也过线，
  生产代码还留着「单候选直接采用」的零证据捷径；③`metadataLanguageTag` 自己扫
  `mainClips + audioTracks` 绕开可听合同（不看眼睛/静音、漏 overlay）——
  隐藏英文主轨 + 可听日文 overlay 会拿英文当首选候选却用日文做探针；
  ④三类选择（剪辑/形状/字幕 cue）互斥散在三处，漏了 shape ↔ cue 两条边，
  切工程也漏清 cue。修法共性是**让错误写法编不过**：删掉 `detectSourceLocale`
  的 `state:` 参数、`EditSelection` 字段全 `private(set)`、可听快照只有
  `SubtitleAudibleClips` 一个产地；再补一段 grep 级**接线守卫**（自检编不动
  @MainActor App 类型，「纯函数有没有被接上」只能在源码层面钉）。
  教训：**同一个坑第二次踩说明防线建在了注释上**；阈值要由实测数据反推、
  把判别区间本身写成断言；**「没得挑」不是「挑对了」**。
  **第二轮又在第一轮的修复上抓出 2 个 P2**（都在 Auto-detect 路径）：
  探针只验「文件存在」不验「音轨可读」（第一段是无音轨视频、后面有正常音频轨
  时整个检测失败），且可听快照把 `info == nil` 当成有声音（与
  `EditClip.hasAudio` 分叉，老工程/导入中素材全中招）；候选只按完整 locale
  标识符去重，`en_US`/`en_SG`/`en_IN` 吃光三个名额（实测取到
  `["en_US","zh_CN","en_IN"]`，装了日语模型也探不到日语），而
  `installedLocales()` 的顺序本机实测还会变。修法：探针**逐段真抽一次**
  （素材的错换下一段、基础设施错误与取消直穿）、快照改用 `clip.hasAudio`、
  去重改按 maximal 后的「语言码+文字系统」并与翻译预检共用同一份 `languageKey`、
  已装档排序后再截断。教训：**便宜的预筛不能当判据**；**假素材（重复字节）
  测不出真解码**，涉及「素材可不可读」的守卫必须用 ffmpeg 现造真实媒体。
  **第三轮再修 1 个 P2**：取消被跳过逻辑洗成「素材不可读」—— 无音轨素材在检查
  取消**之前**就抛 ReadError，取消期间剩下的候选各抛一个、全被吞掉走到
  `return nil`，调用方把 nil 翻成失败文案，终态从 `.cancelled` 变成
  `.failed`。修法是 `selectProbe` 三处都查取消（每轮开头 / 吞错误之前 /
  **返回 nil 之前**）、两条通道都问（token + `Task.checkCancellation()`）。
  教训：**「跳过某类错误」的逻辑必须先排除取消**（取消与「这一项失败了」正交，
  跳过逻辑会把二者压成同一分支）；**让哨兵值自带含义收窄**（nil 收窄成
  「确实全都读不出音频」后，调用方怎么翻译都不会错，比要求调用方记得先查可靠）

- [2026-08-09-translate-stuck-at-zero.md](docs/bugfixes/2026-08-09-translate-stuck-at-zero.md) —
  第二次翻译永久卡在 0/N（用户真机 127 条 cue，en→zh）：
  `TranslationSession.Configuration` 是**带 `version` 的值类型**，`==` 连
  version 一起比，而每个任务都现新建一个（version 恒 0）→ 两次同语言的配置
  **完全相等** → SwiftUI 的 `.translationTask` 判定「没变化」不重跑 action →
  `run(session:)` 收不到 session → continuation 永久悬挂。中间那次
  `pendingJob = nil` 救不了（它不重置 SwiftUI 记住的「上次跑过的配置」）。
  修法：`TranslationConfigurationVendor` 一条流水线**每次 invalidate()**
  （Apple 给的换代通道），外加起跑看门狗（10s 没人认领就如实报错，
  只看「有没有起跑」不误伤慢任务）。教训：**值类型里的 `version` 字段就是在
  提醒你这个值需要换代**；**「第一次成功」不能当成这条路通了** ——
  提交→回调→清空→再提交的循环，验收必须连做两次（分支上两次冒烟一次跳过
  翻译、一次是首次翻译，「第二次」从没被覆盖）；**等外部框架回调的
  continuation 一律配看门狗**

## 根目录既有文档

- [SrtFlow-Requirements.md](SrtFlow-Requirements.md) — 产品需求说明与技术结论总表
- [README.md](README.md) — 项目介绍（面向使用者）
