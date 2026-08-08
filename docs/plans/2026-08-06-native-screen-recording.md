# Edit Video 原生录屏完整实施方案

> 日期：2026-08-06
>
> 状态：**Phase 0–5 主链路已实机验收通过**（整屏 / 麦克风 / 自定义区域），
> 计划 §17.4 的完整矩阵（窗口来源、多屏、崩溃恢复、长时录制）仍未跑完。
> 进度、实测证据与被证伪条目的完整清单见
> [实施报告](../reports/2026-08-06-native-screen-recording-implementation-report.md)；
> 本文与报告冲突处**以报告为准**。正文中已按 §17.1 的要求回填实测订正（标
> 【Phase 0 实测订正】）。
>
> 范围：只规划 Edit Video 内的原生录屏、项目帧率与相关工程集成；本文不代表功能已完成

## 0. 结论先行

第一版采用 macOS 15 起可用的 ScreenCaptureKit，提供“整个显示器 / 单个窗口 /
自定义区域”三种来源，直接录制画面和电脑声音；麦克风默认关闭，但保留为一条与
视频严格对齐、建立链接关系的独立音频轨。用户在录制前选择保存位置，正常停止并
校验成功后，视频追加到主轨末尾，麦克风追加到单独音频轨。

工程拥有明确的 24 / 30 / 60 fps 帧率，默认 24 fps。录屏跟随工程帧率，预览、
导出、预渲染、转场和关键帧时间容差也统一使用同一个值，避免“AI 素材 24 fps、
录屏 30 fps、编辑器内部又按 30 fps”形成三套时间基准。

整个 App 的最低系统提升到 macOS 15，但继续使用 Swift tools 5.9；
`Package.swift` 使用 `.macOS("15.0")`，不为了写 `.v15` 而连带升级到 Swift tools
6.0。实现只依赖 ScreenCaptureKit、AVFoundation、CoreMedia、AppKit 和 SwiftUI，
不引第三方库、不装虚拟声卡、不做系统扩展。

本文没有遗留的产品问题。仍有若干必须在正式开发前用小型实测确认的技术点，已经
列为 Phase 0 的硬门槛；它们不会改变已确认的产品范围。

## 1. 已确认的产品决策

| 主题 | 决策 |
| --- | --- |
| 最低系统 | 整个 App 提升到 macOS 15，不保留 macOS 14 兼容层 |
| 录制来源 | 整个显示器、单个窗口、自定义区域 |
| 自定义区域 | 只能位于一块显示器内，不支持跨屏区域 |
| 区域比例 | 自由、16:9、9:16、4:3、3:4、1:1 |
| 工程画布 | 空工程采用所选固定比例；自由区域、显示器或窗口采用实际录制比例；已有视觉素材的工程不自动改画布 |
| 电脑声音 | 默认开启，录入屏幕内容正在播放的声音，也录入 SrtFlow 自己播放的声音 |
| SrtFlow 画面 | 不排除 SrtFlow 主窗口，允许录制产品演示 |
| 录制控制 UI | 倒计时、计时器和 Stop 控制窗不进入录制画面 |
| 麦克风 | 第一版保留，默认关闭并记住上次选择；录成独立音频文件和独立轨 |
| 回声消除 | 第一版不做；麦克风与电脑声音同时开启时提示优先使用耳机 |
| 麦克风拒权 | 继续录屏和电脑声音，明确提示麦克风没有被录入 |
| 保存位置 | 开始录制前由用户通过 Save Panel 选择 |
| 文件格式 | 主文件为 H.264 SDR `.mov`，包含画面与电脑声音；麦克风为同目录同 basename 的 `-Mic.m4a` |
| 入轨位置 | 成功停止后追加到主轨末尾；麦克风按视频的实际时间线起点进入单独音频轨 |
| 帧率 | 工程可选 24 / 30 / 60 fps，默认 24；录屏跟随工程帧率 |
| 倒计时 | 3 秒 |
| 鼠标 | 指针默认显示；点击圆圈效果默认关闭，可在录制设置里开启 |
| 暂停 | 第一版不做暂停 / 恢复，只做 Stop |
| 工程生命周期 | 录制流程占用当前工程；期间禁止新建、打开、切换工程，其他 App 内操作仍可使用 |
| 退出 App | 必须先停止、排空、封装并处理导入，再完成工程落盘和退出 |
| 意外中断 | 尽力封装有效的部分文件，让用户选择是否导入；不把损坏文件静默塞进轨道 |
| 旧工程 | 没有正式旧内容；缺失帧率字段统一按 24 fps 读取即可 |

## 2. 目标、非目标与成功边界

### 2.1 第一版目标

1. 用户从 Edit Video 内发起录屏，不需要先用其他工具录制再导入。
2. 一次 ScreenCaptureKit 会话同时产出画面、电脑声音和可选麦克风，三者共享录制
   时间基准。
3. 正常停止后先完成文件封装和可播放性校验，再用一次工程事务把素材加入时间线。
4. 录制 SrtFlow 自己时，主界面和它播放的声音都能进入成片，但录制控制 UI 不出现。
5. 24 / 30 / 60 fps 成为工程级唯一事实来源，而不是只影响录屏的临时选项。
6. 失败时保住已有目标文件、有效的部分录制和当前工程，错误不能伪装成成功。

### 2.2 第一版明确不做

- macOS 14 兼容路径。
- 扬声器回放条件下的应用级声学回声消除（AEC）。
- 暂停 / 恢复、分段继续录制。
- HDR、HEVC、ProRes 或透明录制。
- 摄像头画中画、提词器、直播、滚动缓存。
- 跨显示器自定义区域。
- 系统级全局快捷键；Stop 由浮动控制窗提供，避免新增辅助功能权限。
- 录制素材库或 App 内文件管理；仍由 Finder 和用户选择的目录负责。
- 第三方录屏库、虚拟声卡、DriverKit / System Extension。

## 3. 对现有代码的重新核对

### 3.1 构建和系统基线

- `Package.swift` 当前是 `swift-tools-version: 5.9` 和 `.macOS(.v14)`。
- `packaging/Info.plist` 当前 `LSMinimumSystemVersion` 为 `14.0`，还没有屏幕、电脑
  音频和麦克风用途说明。
- `scripts/build-app.sh`、README、Requirements、两个 Swift 自检脚本的 target
  triple，以及若干注释仍写着 macOS 14。
- 当前仓库构建文档已明确：Rosetta 终端必须执行 `swift build --arch arm64`。

结论：最低系统迁移必须作为独立提交层完成，且保持 tools 5.9。PackageDescription
5.9 还没有 `.v15` 枚举，因此写字符串版本 `.macOS("15.0")`；直接改用 `.v15`
会无必要地把包描述升级到 tools 6.0，并扩大编译迁移范围。

### 3.2 工程数据和存盘

- `TimelineState` 已保存主轨、画中画轨、音频轨、字幕、形状和 `canvasRatio`，但没有
  工程帧率。
- `TimelineState` 使用手写 Codable；新增持久字段必须同时处理编码、宽容读取和
  `selectionForExport` 的复制。
- `.srtflowproj` 当前 `latestFormatVersion = 4`；
  `VideoEditProjectFile.init(timeline:media:)` 根据
  `TimelineState.requiresFormatVersion4` 决定写 v3 还是 v4。现有架构约束要求新增会
  影响行为的持久字段必须提升格式版本。
- 素材继续存外部 URL / bookmark，不复制进工程包，符合“Finder 管文件”的既有
  架构。
- `VideoEditProject.documentGeneration` 已能防止跨 `await` 把结果写回错误工程；
  `VideoEditProjectDocument` 是它的使用方。该 generation 是录制结束导入时必须携带
  的工程身份。

### 3.3 预览、导出和动画目前的 30 fps 假设

- `VideoEditCompositionBuilder` 把 `AVMutableVideoComposition.frameDuration` 固定为
  `1/30`。
- `VideoEditExporter` 的 8 组生产滤镜位置把 `fps=30`、`color ... r=30` 和相关注释
  写死；实现时用扫描守卫兜底，不能只改其中一条管线。
- `VideoEditPrerender` 会建立新的临时 `TimelineState`，目前不会继承未来新增的
  工程帧率。
- `KeyframeTrack.timeTolerance` 固定为 `1/60`，实际是“30 fps 的半帧”。
- Video Edit 复用了通用 `EncodeSettingsView` 的 Resolution / Frame Rate 控件，
  但当前导出器并没有真正消费这两个值；UI 会给出并不存在的控制承诺。
- `scripts/check-export-alpha-compositing.sh` 还手工复制了一套固定 30 fps 的滤镜片段。
  它当前是独立 alpha fixture，并不会调用生产导出器；必须避免把它误称为“生产滤镜
  已回归”。

结论：帧率不能只加在录制设置里。它必须贯穿工程模型、预览合成、两条导出路径、
预渲染和关键帧判断；Video Edit 导出 UI 应显示工程固定输出规格，而不是继续展示
无效的独立帧率控件。

### 3.4 UI 和生命周期

- `VideoEditView` 已集中承接工具栏和 sheet，适合只增加很薄的入口，不适合继续塞入
  完整录制实现。
- `VideoEditProjectBar` / `VideoEditProjectDocument` 管理 New、Open、Open Recent、
  外部打开、自动保存和工程切换；录制锁必须在这些动作的执行入口再次校验，不能只
  依赖按钮 disabled。
- App 退出当前是同步的 `applicationShouldTerminate` 流程，而录制 Stop / writer
  finalize 是异步的；实现时必须切换到 `.terminateLater` 协调。
- `VideoEditTimelineView`、`VideoEditProject`、`VideoEditModels` 都已接近或超过仓库
  的单文件警戒线，新职责应放在新文件和窄 extension 中。

## 4. 总体架构

```text
VideoEditView 录制入口
        │
        ▼
@MainActor ScreenRecordingCoordinator（App 级唯一实例）
  来源选择 / 权限 / Save Panel / 倒计时 / 状态机 / 工程身份 / 提示
        │
        ▼
ScreenCaptureEngine（一个 SCStream）
  ├─ .screen ───────────────┐
  ├─ .audio（电脑声音）──────┼─► ScreenRecordingWriter
  └─ .microphone（可选）─────┘      ├─ 主 AVAssetWriter → 临时 .mov
                                    └─ 麦克风 AVAssetWriter → 临时 -Mic.m4a
        │
        ▼ Stop / drain / finish / validate / atomic commit
VideoEditProject.appendScreenRecording(...)
  ├─ 视频 → 主轨实际末尾
  └─ 麦克风 → 独立音频轨，同起点、同 linkGroup
```

### 4.1 为什么不用 `SCRecordingOutput`

macOS 15 的 `SCRecordingOutput` 很适合“把所有已捕获媒体直接写进一个文件”，但本
功能已经确认麦克风必须是独立文件和独立轨。若使用它，要么把麦克风混进主文件，
要么录完再拆轨；后者多一次完整读写，仍需处理精确起点、取消和磁盘空间，反而更
重。

因此采用一个 `SCStream` 收三类 sample buffer，再由两个 `AVAssetWriter` 写出主
文件和麦克风 sidecar。这样不需要两次捕获、虚拟设备或第三方组件，并且两路仍来自
同一个 ScreenCaptureKit 会话。

### 4.2 职责边界

- `ScreenRecordingCoordinator`：只在主线程管理状态、UI、权限、文档锁和最终导入。
- `ScreenCaptureEngine`：配置 `SCStream`、注册输出、接收中断，不碰工程模型。
- `ScreenRecordingWriter`：在专用串行队列上维护时间戳、背压、两套 writer 和封装。
- `ScreenRecordingSourcePicker`：封装系统 picker 与自定义区域选择，输出不可变的来源
  描述和 filter 构造信息。
- `VideoEditProject+ScreenRecording`：唯一知道“如何原子追加到当前时间线”的层。
- 录制文件属于用户，工程撤销只删除轨道引用，不删除磁盘文件。

## 5. 工程帧率：24 / 30 / 60 的唯一事实来源

### 5.1 数据模型

新增独立文件 `VideoEditFrameRate.swift`：

```swift
enum ProjectFrameRate: String, CaseIterable, Sendable {
    case fps24 = "24"
    case fps30 = "30"
    case fps60 = "60"

    var framesPerSecond: Int32 {
        switch self {
        case .fps24: 24
        case .fps30: 30
        case .fps60: 60
        }
    }
    var frameDuration: CMTime { CMTime(value: 1, timescale: framesPerSecond) }
    var halfFrameSeconds: Double { 0.5 / Double(framesPerSecond) }
}

extension ProjectFrameRate: LenientCodableEnum {
    static let decodingFallback = ProjectFrameRate.fps24
}
```

复用仓库现有 `LenientCodableEnum`，未知值回退 24，不能让未来值变成整份工程的解码
错误。`TimelineState` 增加 `frameRate: ProjectFrameRate`，新工程默认 `.fps24`。旧
v1–v4 工程若字段缺失也解码为 `.fps24`。`selectionForExport` 必须复制它，任何构造
临时 `TimelineState` 的位置也必须显式继承。

### 5.2 工程格式升级为 v5

帧率会改变预览、导出和关键帧行为，不能被旧版静默忽略，所以：

1. `latestFormatVersion` 升到 5。
2. 新版 writer 始终写 v5，不再根据 companion 字幕是否存在在 v3 / v4 之间摇摆。
3. reader 继续接受 v1–v4，缺失帧率按 24；v4 的 companion 归一化规则继续保留。
4. 老版本 App 看到 v5 必须拒绝打开，避免按 30 fps 误解释并回写破坏。
5. 工程文件自检新增 v5 round-trip、v1–v4 → 24 fps、未知帧率回退，以及
   `selectionForExport` 保留帧率的用例。

用户已经确认旧工程只是测试工程，因此不做“旧工程保持历史 30 fps”的兼容开关，
也不弹迁移选择框。

### 5.3 全链路消费规则

- 预览：`videoComposition.frameDuration = state.frameRate.frameDuration`。
- 原生导出与 ffmpeg 导出：所有 `fps=30`、`r=30` 改为工程值；视频输出元数据和
  生成黑底也使用同一值。
- 预渲染：临时 timeline 继承外层工程帧率，不能回到默认 24 或旧 30。
- 关键帧不再共享一个固定 `KeyframeTrack.timeTolerance`，而是按比较所在的时间空间
  显式传入容差，顺带修正现有变速 clip 的语义不一致：
  - `timelineHalfFrame = 0.5 / projectFPS`。
  - source-time 的 `key` / `set` / `remove`、`allKeyTimes` 和 `merged` 去重使用
    `sourceTolerance = timelineHalfFrame × abs(clip.speed)`。
  - ‹ / › 已把 source time 映射成 timeline time，寻找相邻关键帧时直接使用
    `timelineHalfFrame`，不能再乘 speed。
  - 插值中的极小 span 防除零属于数值稳定阈值，不等同于“同一帧”容差，继续独立。
- 逐帧前进、吸附和显示帧号：若现有路径有自己的时间常量，一并审计并统一。
- 录屏：`SCStreamConfiguration.minimumFrameInterval` 使用工程 frame duration。
- 静态屏幕允许 ScreenCaptureKit 输出可变间隔；编辑和最终导出仍按工程帧率规整。
  第一版不人为复制静止帧形成实时 CFR，除非 Phase 0 证明 writer / 导入不能正确
  处理该时间线。

### 5.4 UI

- 在画布比例菜单附近增加工程帧率菜单：24、30、60 fps；新工程选中 24。
- 录制设置只读显示“跟随工程：24 fps”等，不再创建第二份录屏帧率状态。
- Video Edit 的导出面板不再展示无效的独立 Resolution / Frame Rate 控件，改成
  只读输出规格“宽 × 高 · 24 fps”；Compress / Burn In 仍可继续使用通用控件。
- 已有素材不因切换工程帧率改变时间长度；只改变合成采样和输出节奏。

## 6. 录制来源与区域几何

### 6.1 显示器和窗口

- 使用系统 `SCContentSharingPicker`，只开放 `.singleDisplay` 和 `.singleWindow`。
- `allowsChangingSelectedContent = false`，录制中不能换来源；否则固定尺寸 writer、
  保存语义和入轨元数据会失去一致性。
- picker 返回的 filter 代表用户对所选内容的范围授权。单窗口路径直接使用它，不在
  picker 前调用广域屏幕权限 preflight，也不先读取 `SCShareableContent`；picker
  失败或取消时按系统结果处理。
- 不设置 SrtFlow bundle ID 为 excluded；SrtFlow 窗口必须可被选择，也必须在整屏
  录制中出现。
- 不依赖 picker 的 `excludedWindowIDs` 排除录制控制 UI：该属性的公开合同只是
  “不允许在 picker 中选择这些窗口”，不是“从整屏成片中扣掉这些窗口”；而且 picker
  出现时 Stop panel 尚未创建，根本没有可用 window ID。倒计时窗会在 capture 前
  消失，也无需进入排除集。
- 单窗口捕获直接使用系统返回的独立窗口 filter；其他窗口即使盖在它上面也不会进入
  该内容流，所以无需为 Stop panel 重建 filter。
- 整个显示器必须同时满足“系统 picker 选屏”和“仅排除持久 Stop panel”。基线实现
  在选屏后创建 Stop panel、取得 CGWindowID，刷新 `SCShareableContent` 匹配
  `SCDisplay` / `SCWindow`，再用 `SCContentFilter(display:excludingWindows:)` 重建
  最终 filter。这个步骤可能需要广域屏幕录制权限，不能再宣称整屏路径必然零 TCC；
  Phase 0 先验证 picker scope 下是否存在公开、稳定的免广域授权做法，验证不成立就
  以“控制窗不入画”为优先，保留分层权限引导。
- macOS 15.0 尚不能依赖 15.2 才有的 `includedDisplays` 直接取回所选 display；用
  picker filter 的 `contentRect` / scale 与 `SCShareableContent` 做唯一匹配。若不能
  唯一匹配，停止在开始前并要求重选，不能冒险录入控制窗。
- 窗口默认忽略阴影和 framing，得到可预测的内容边界；子窗口是否包含按
  ScreenCaptureKit 的 window filter 行为保持一致，不额外合成。

### 6.2 自定义区域

自定义区域不用自己抓屏，只自己做选择 UI：

1. 为每块 `NSScreen` 创建透明、无标题、borderless 的 AppKit overlay panel。
2. 第一次 mouse-down 锁定所在显示器，后续拖动只能在该屏边界内 clamp。
3. 自由模式按拖动矩形；固定比例模式以起点和当前指针计算最大内接矩形。
4. 支持从任意方向拖动，显示实时逻辑尺寸和最终像素尺寸；小于最低可用尺寸时禁止
   开始。
5. Return / 双击确认，Escape 取消；确认后所有选择 overlay 在倒计时前销毁。
6. 区域确认后先销毁选择 overlay；创建持久 Stop panel 并解析对应 `SCWindow`，再用
   `SCContentFilter(display:excludingWindows:)` 建立与整屏路径相同的排除 filter，
   最后把区域转成它的 `sourceRect`。即使 Stop panel 被拖进选区，也不能进入成片。

坐标转换必须放入无 UI 的 `ScreenRecordingCoordinateMapper`，统一处理：

- AppKit 的全局 bottom-left 坐标；
- 多屏可能存在的负原点；
- ScreenCaptureKit 的 display-local points；
- `pointPixelScale` / Retina 缩放；
- H.264 要求的偶数像素宽高；
- clamp 后比例不能被偶数取整明显破坏。

主屏、左侧副屏、上方副屏、不同 scaleFactor 和负原点都要有纯函数测试；Phase 0
还必须录一张带四角和中心标记的像素网格，人工确认没有上下翻转或 1–2 px 漂移。

### 6.3 比例和空工程画布

- 固定比例只作用于自定义区域选择；整个显示器和单窗口使用来源实际比例。
- 固定比例区域成功导入空工程时，画布设为对应 `CanvasRatio`。
- 自由区域、显示器或窗口导入空工程时，按最终录制像素宽高得到自动比例。
- request 保存 `hadVisualContentAtStart`、`canvasRatioAtStart` 和一个仅驻内存的
  `canvasEditGenerationAtStart`；`setCanvasRatio` 每次显式操作都递增 generation。
  只有开始录制时没有视觉 clip、导入时仍没有视觉 clip、当前画布等于快照且 edit
  generation 未变化时，才自动采用录制比例；仅有音频不阻止自动采用。即使用户改了
  又改回原比例，也以用户操作为准，不自动覆盖。
- 一旦已有视觉内容，录屏永远不改现有画布；沿用正常主轨适配规则。
- 用户在倒计时前取消或录制失败时，不能提前修改画布。

## 7. ScreenCaptureKit 配置

每次开始录制都从不可变的 `ScreenRecordingRequest` 生成配置，request 至少包含：
工程 generation、来源、逻辑区域、最终像素尺寸、工程帧率、画布 / 是否有视觉素材 /
画布编辑 generation 快照、系统音频开关、麦克风开关 / 设备 ID、鼠标与点击效果、
最终 URL 和唯一 session ID。

### 7.1 视频

- 为 stream 注册 `.screen` 输出，动态范围明确使用 SDR。
- `pixelFormat = kCVPixelFormatType_32BGRA`；macOS 15 SDK 明确说明系统
  `showMouseClicks` 当前作用于 BGRA 路径。
- `minimumFrameInterval = project.frameRate.frameDuration`。
- `showsCursor = true`，`showMouseClicks` 默认 false。点击圆圈只使用系统属性，系统
  输出什么就接受什么；绝不监听全局鼠标事件或自绘合成。
- `queueDepth = 5`；Apple 建议不要超过 8，5 在延迟和短时背压之间留出余量。
- 输出宽高优先使用 `points × pointPixelScale` 后的偶数像素尺寸，不直接把 points
  当 pixels。
- 保持来源比例；单窗口在录制中改变大小时继续缩放进启动时冻结的输出尺寸，不动态
  重建 writer。输出背景明确设为不透明黑色，避免 H.264 路径误解释透明像素。
- 【Phase 0 实测订正】`AVAssetWriter.canApply` **不能**当尺寸门槛：实测它对
  1080p 到 8K（含奇数宽）全部返回 true，只做设置字典的形状校验。真实约束是
  **硬件 H.264 编码器单边 ≤ 4096**（M1 实测，`RequireHardwareAcceleratedVideoEncoder`
  在 4200×2362 报 -12903；与总像素无关 —— 5120×1440 像素比 4K 少也落软件编码）。
  实现用 `ScreenRecordingCoordinateMapper.fitToHardwareEncoder`（等比缩到单边
  ≤4096 的最大偶数尺寸），并在倒计时前显示“实际将录制为 W×H”。
- H.264 采用较高质量的屏幕内容码率，按像素数 × fps 的有界规则计算；最大关键帧
  间隔为约 1 秒，兼顾文字清晰度和进入编辑器后的 seek。具体上下界由 Phase 0 的
  1080p / 4K / 5K 文本滚动样本定值。

### 7.2 电脑声音

- 设置 `capturesAudio = true`（默认），48 kHz、stereo，由 ScreenCaptureKit 输出
  统一格式，写入主 `.mov` 的 AAC track。
- `excludesCurrentProcessAudio = false`，这是“录到 SrtFlow 自己播放的声音”的明确
  条件，不能使用常见 sample 中排除当前进程的默认做法。
- 电脑声音关闭时允许生成 video-only `.mov`；开启但实际静音时仍是正常录制。
- 若 ScreenCaptureKit 能把系统音频拒绝 / 不可用与屏幕授权分开报告，不能静默降级：
  提示用户“继续仅录画面”或取消，选择继续后 request 中明确改成 false。若系统把
  屏幕与系统音频作为一个联合权限拒绝，则整次 capture 不能开始。

### 7.3 麦克风

- 默认关闭，只在用户开启时请求权限；选择记入 UserDefaults，不进入工程文件。
- 用 `AVCaptureDevice` 枚举可用音频输入。麦克风开启时，无论是用户所选设备还是
  系统默认设备，都先解析成真实 `AVCaptureDevice`，再把它的 `uniqueID` 显式写入
  `microphoneCaptureDeviceID`；不能用 nil 表示“默认设备”。找不到任何默认设备时
  关闭本次麦克风并提示，不能带着不确定配置启动。
- `captureMicrophone = true` 后接收 `.microphone` 输出；它保持设备原生采样格式，
  writer 根据第一份有效 format description 配置 AAC 输入，不假定一定是
  48 kHz stereo。
- 麦克风独立写 `Base-Mic.m4a`，绝不混入主 `.mov` 的电脑声音 track。
- 权限拒绝或设备启动失败时，明确提示并继续画面 + 电脑声音；这一路降级不应导致
  整次录屏失败。
- 麦克风与电脑声音同时开启时，在设置页显示“使用耳机可避免扬声器声音再次进入
  麦克风”的提示。

### 7.4 为什么第一版不做 AEC

高质量 AEC 通常要求应用掌握“送到扬声器的参考信号”和麦克风输入，并让二者进入
同一个 voice-processing I/O 图。这里的电脑声音来自 ScreenCaptureKit，可能来自
任意其他 App，并不是 SrtFlow 自己控制的播放图；简单把系统音频从麦克风波形里相减
会受设备延迟、房间反射、自动增益、采样率和时钟漂移影响，容易得到金属音或漏回声。

因此这不是加一个 flag 的小功能，而是中到大型的实时音频工程。第一版用独立轨 +
耳机提示保留后期可编辑性；未来若确实需要，应单独做原型和听感矩阵，不能把未经
验证的“降噪”命名为回声消除。

## 8. Writer、共同时间轴与同步

### 8.1 一个 stream，两套 writer

`ScreenCaptureEngine` 为 `.screen`、`.audio` 和可选 `.microphone` 分别注册输出，
delegate 只做轻量校验和转发；所有写入进入 `ScreenRecordingWriter` 的专用串行队列，
不阻塞主线程，也不让三个 callback 并发修改 writer 状态。

- 主 writer：`.mov`，H.264 SDR video + 可选 AAC system audio。
- 麦克风 writer：`.m4a`，AAC microphone audio only。
- 所有 `AVAssetWriterInput.expectsMediaDataInRealTime = true`。
- 每个 input 单独维护 last accepted PTS，拒绝倒退或重复时间戳，并把异常记录到会话
  诊断；不能让一次坏 sample 破坏整个封装。

### 8.2 共同零点

第一份状态为 `.started` 或 `.complete` 的可用 screen frame 定义录制锚点 `T0`。
在它到来前的电脑音频 / 麦克风只进入有严格时长上限的小缓冲；`T0` 确立后：

1. 丢弃完全早于 `T0` 的音频部分，裁切跨越 `T0` 的 sample。
2. 两个 writer 都以同一个 `T0` 启动 session，或把全部 timing 统一减去 `T0` 后
   从零启动；最终只保留一种经 Phase 0 证明可靠的实现，不能两种混用。
3. 正常 Stop 首次被接受时，从 `SCStream.synchronizationClock` 快照共同终点 `T1`，
   不使用 `Date` 当媒体时钟；clock 不可用时，在排空后取最后一份有效媒体时间。
   意外停止则取最后一个确定有效的共同时间。超出 `T1` 的部分裁切，缺少的尾部以
   容器时长 / 必要静音补齐，保证 sidecar 与主文件描述同一段真实时间。
4. 仅接受 ScreenCaptureKit frame status 为 complete / started 的可用帧；blank、
   idle、suspended 不能当正常画面写入。

【Phase 0 实测订正】本机实测三路 PTS **共享同一时基**（mach 绝对时间；
`synchronizationClock` 与 host clock 不是同一对象但背靠背连读差恒为 0），
不需要 epoch 换算 —— 但**麦克风的 timescale 是 48000、另两路是 1e9**，比较前
必须换算。共同零点直接取第一个到达采样的 PTS，各路写入前统一减 T0；
「各自第一帧都设为 0」依然禁止（会把真实启动差抹掉）。
另：声学测得麦克风内容比系统声音早约 69 ms（AAC 净贡献仅约 9.8 ms），但该值
含扬声器/声程/输入缓冲等环境成分，**不得当常量补偿写进实现**；30 分钟实测
无累积漂移。

### 8.3 对齐验收标准

- 主画面、电脑声音和麦克风不得产生累计漂移。
- 录制 30 分钟后，麦克风与主轨的末端差不得超过一个工程视频帧。
- 开始瞬态误差目标不超过一个麦克风 callback buffer，且必须小于一个工程视频帧。
- sidecar 从工程中与视频同一 timeline start 插入后，测试拍手 / 播放 click track
  的峰值位置满足上述标准。
- AAC priming / remainder 必须进入 Phase 0：Apple AAC encoder 常见前置 priming 为
  2112 samples，在 48 kHz 下约 44 ms，已经略大于 24 fps 的一帧。不能把编码包的
  首 PTS、容器 nominal duration 或未裁切的 PCM 直接当同步结论。
- 主 `.mov` 和麦克风 `.m4a` 应由 AVAssetWriter 正确写出 QuickTime edit list / sample
  group 等 priming 表达；用 `afinfo` / `ffprobe` 检查容器，再通过 AVFoundation 实际
  解码成 PCM 比较 click / 拍手峰值。验收以播放器会呈现的解码后有效 PCM 为准。
- 不在业务代码里无条件减去 2112，也不把非标准 `iTunSMPB` 当唯一合同；实际 delay
  可能随 codec 实现和采样率变化。只有 Phase 0 证明 AVAssetWriter 元数据不完整时，
  才选择明确、可测试的补偿路径。
- 若 AVAssetWriter 的独立 `.m4a` 会折叠开头空隙或尾部时长，Phase 0 必须先决定
  是保留 movie edit、用 AVMutableComposition 规范化，还是只合成缺失的短静音；
  未解决前不能进入正式 UI 实现。

### 8.4 背压和掉帧

- 视频 input 暂时不 ready 时允许 ScreenCaptureKit / writer 按实时语义丢视频帧，
  时间戳必须保留，不能压缩时间。
- 音频和麦克风不能无声丢 sample。采用有界 backlog；短暂阻塞稍后排空，超过预算
  立即把会话标记为可恢复失败并走 partial finalize。
- 记录收到 / 接受 / 丢弃的 sample 数、首末 PTS、最大 backlog 和 writer error，
  仅用于本地诊断，不记录音视频内容。

### 8.5 正常 Stop 顺序

Stop 必须幂等，且严格按以下顺序：

1. coordinator 将状态从 recording 原子切到 stopping，后续 Stop 只等待同一个结果。
2. 调用 `SCStream.stopCapture()`，等待 capture 确认停止。
3. 在 writer 队列执行 barrier，排空此前已经交付的全部 sample。
4. 用共同 `T1` 结束 session，mark 所有已添加 input finished。
5. 等待两套 writer `finishWriting`；麦克风关闭时只有主 writer。
6. 用 `AVURLAsset` 重新打开临时文件，校验可读 video track、时长、尺寸、帧率语义，
   以及请求开启时存在覆盖录制时段的 system audio / mic track；真正没有收到音频
   sample 时必须显式失败或降级，不能把“开启了声音但文件没音轨”当成功。
7. 临时文件通过后才提交到用户目标；再执行工程导入。

任何一步失败都不能回报“录制完成”。主 writer 有效而麦克风 writer 失败时，主文件
仍然有价值：保留并导入主文件，同时明确报告麦克风失败和可恢复临时文件位置；不因
可选麦克风失败删除完整的屏幕录制。

## 9. 文件命名、临时文件与提交

### 9.1 Save Panel

- 位于来源和音频设置确认之后、3 秒倒计时之前。
- 默认目录为上次成功使用的目录；首次使用为 Movies（不可用时回退用户可写目录）。
- 默认名：`Screen Recording YYYY-MM-DD HH.mm.ss.mov`，自动避开同名。
- 用户只选择主 `.mov`；若麦克风开启，sidecar 自动为同目录
  `Base-Mic.m4a`，不再弹第二个保存框。
- 若主目标或 mic sibling 已存在，必须在开始前明确处理冲突，禁止录完才发现。任何
  覆盖都要经过 Save Panel / 明确提示，不能静默覆盖 sibling。

### 9.2 临时与原子提交

- 在目标目录创建带 session UUID 的隐藏临时 sibling，使最终 rename / replace 留在
  同一 volume。倒计时前验证目录可写，并检查卷的可用空间是否高于最低安全余量；
  安全余量取 `max(1 GiB, 当前码率估算的 2 分钟输出体积)`，最终数值由 Phase 0 的
  码率边界校准。
- 录制时低频检查剩余空间；接近安全底线就主动 Stop 并走正常 finalize。录制时长
  不可预知，所以开始前检查不能承诺“绝不会磁盘满”；真实写入失败仍必须进入
  partial recovery，不能把验收写成空头保证。
- writer 永远写临时 URL，不直接写用户最终 URL。
- 正常完成且验证成功后，主文件用原子 replace / move 提交；已有目标在提交失败时
  保持原状。
- mic 文件随后独立提交。跨两个文件不存在真正的文件系统事务，因此主文件是主要
  成果：mic 提交失败不回滚已成功的主录屏，但必须明确告知并保留有效 mic 临时文件
  供用户恢复。
- 只有已提交、重新验证可读的最终 URL 才能写入工程。
- 正常成功后删除属于该 session 的临时文件；失败只清理确定无效的临时文件，有效
  partial 由恢复提示处理。
- 绝不使用宽泛 glob 清理，不删除用户原文件。

### 9.3 App 崩溃后的精确恢复

stream 中断还能执行 partial finalize，但进程崩溃 / 强制结束来不及运行任何清理。
为避免隐藏临时文件永久残留：

1. 【Phase 2 实测订正】创建 writer 前，把唯一 active session manifest 写入
   **`ScreenRecordingManifestStore`（单 JSON 文件 + 原子写），不是 UserDefaults**
   —— `UserDefaults.set` 内存立即生效、磁盘**异步**写入（Apple 文档明说），
   拿它当 journal 栅栏时「set 返回 → rename → 崩溃」意向可能根本没落盘。
   至少记录 session UUID、开始时间、主 / mic 临时 URL 和最终目标 URL；
   只登记本 session 精确路径，不登记目录或匹配模式。
2. 提交按 **journal 协议**推进（每次 rename **之前**先 `persist()` 意向、
   成功返回才允许 rename），见 `ScreenRecordingManifest.CommitStage`。
   **删除记录的唯一判据是 `ScreenRecordingRecoveryLedger.canClearManifest`**
   —— 要求每一路都既「现场有结论」又「处置已了结」；只看文件现场不够
   （writing 崩溃留下的 partial 现场正常，但用户还没决定怎么处理它）。
3. App 下次启动先读取这一条 manifest：不存在的路径直接清账；存在的主临时文件用
   `AVURLAsset` 验证，可读 partial 提示恢复 / 保存，无有效 video track 的精确删除；
   mic 只有在能与有效主文件建立对应关系时才提示恢复。
4. 不扫描用户目录、不使用 glob，也不触碰 manifest 没点名的文件。若恢复 UI 暂时
   无法完成，至少把精确路径展示给用户，不能反复静默遗留。

## 10. 成功导入时间线

新增 `VideoEditProject+ScreenRecording.swift`，提供一个专用的异步准备 + 单事务写入
入口，不能串联现有 `addVideos` 和 `addAudios` 两次独立 mutation。

### 10.1 导入前

1. 对最终 `.mov` 和可选 `.m4a` 做 `MediaProbe`，拿到真实 duration / dimensions /
   audio metadata。
2. 用 `VideoEditProject.isCurrentGeneration(...)` 校验发起时保存的
   `documentGeneration` 仍对应当前工程；虽然 UI 已阻止切工程，这里仍是最后一道
   stale-result guard。
3. 直到 probe 和 identity 都通过前，不改变 timeline、canvas、selection 或 dirty。

### 10.2 一次 `perform` 内完成

1. 读取 request 的视觉内容 / 画布 / canvas edit generation 快照，并读取导入时的
   当前状态；不再只凭“这一刻没有视觉 clip”决定画布。
2. 创建主视频 clip，目标位置为当前主轨末尾。
3. 若磁吸开启，走现有主轨 pack / transition 规则；pack 后重新读取该视频的实际
   `timelineStart`，不能继续使用 pack 前的估算值。
4. 若有麦克风，始终为这次录制新建一条 audio lane，不与普通导入音频复用轨道；
   `timelineStart` 精确等于视频的实际起点。
5. 视频与麦克风使用同一个新 `linkGroup`；以后移动 / 裁切遵守既有链接语义。
6. 仅在第 6.3 节的四个条件（开始时空、结束时仍空、画布值未变、canvas edit
   generation 未变）全部成立时设置画布；否则保持用户当前值。
7. 选中新导入片段，并把播放头移到录制片段起点，方便立即检查。
8. 一次 dirty、一次 undo 记录；Undo 只撤销 timeline / canvas 变化，不删除文件。

如果用户在录制期间编辑当前工程，追加位置以“完成导入时”的主轨末尾为准，这符合
“追加到主轨末尾”的可观察语义；录制期间禁止换工程，但不冻结正常编辑。

## 11. UI 与完整交互流程

### 11.1 入口

- Edit Video 顶部主工具栏在 Subtitles / Export 前增加醒目的 `Record Screen`。
- 空工程起始页也提供同一入口。
- 录制设置或录制进行中，重复点击入口只激活现有设置 / 控制窗，不创建第二个会话。

### 11.2 开始流程

1. 点击 Record Screen，coordinator 取得 App 级录制 reservation 和当前工程
   generation。
2. 显示轻量设置页：来源类型、区域比例（仅区域时）、电脑声音、麦克风 / 设备、
   指针、点击效果；显示“跟随工程 24/30/60 fps”。
3. 按来源做选择前准备：单窗口和整个显示器都不在 picker 前做广域屏幕 preflight；
   自定义区域因必须自行取得 `SCDisplay`，先取得广域屏幕权限。麦克风关闭时不触发
   麦克风提示。
4. 显示系统 picker 或自定义区域 overlay，用户选择来源。整个显示器只有在用户完成
   picker 选择后，才为后续重建 excluding filter 取得所需的广域权限；用户先取消
   picker 时不应收到额外权限提示。
5. 计算并展示最终尺寸，验证 encoder 设置。
6. 弹 Save Panel 选择主文件位置，并执行目录可写 / 最低安全空间检查。
7. 创建并显示持久 Stop panel，取得 CGWindowID；整屏 / 区域路径解析对应
   `SCWindow` 后构造最终 excluding filter，单窗口继续使用 picker 原 filter。
8. 先持久化 active session manifest，再创建临时文件和 writer。
9. 显示 3、2、1 倒计时；倒计时窗不是最终排除集的一部分，而是在 capture 前销毁。
10. 倒计时消失，最后确认 Stop panel 已进入整屏 / 区域 filter 的排除集，再启动
    capture。

倒计时期间 Escape / Cancel 必须完整撤销：停止尚未开始的 stream、关闭 Stop panel、
清理本 session 空临时文件和 active manifest、释放工程 reservation，不导入、不
dirty。

### 11.3 录制中

- 使用一个小型浮动 `NSPanel` 显示红点、已录时长和 Stop。
- panel 可移动、跨 Space，并可作为 full-screen auxiliary；只排除这个 panel，不排除
  SrtFlow 主窗口。
- macOS 自己的屏幕录制隐私指示属于系统安全 UI，不尝试隐藏或绕过。
- SrtFlow 其他页面和编辑器仍能使用，便于录制产品演示。
- New、Open、Open Recent、Finder 外部打开和任何切换当前文档的实际执行入口被拒绝，
  提示“请先停止录制”；仅 disabled 菜单不算完整实现。
- 工程帧率在 request 生成后冻结，录制结束前其菜单和 mutation 入口都拒绝修改；
  其他正常时间线编辑继续开放。
- 关闭当前工程 / 窗口按 Quit 同类生命周期处理：先停止并完成录制，或取消关闭。
- 不提供 pause，也不注册全局快捷键。

### 11.4 停止、部分恢复和结果反馈

- 正常 Stop：显示 Finalizing，完成文件校验和导入后聚焦 Edit Video 并选中新片段。
- ScreenCaptureKit 意外停止、显示器拔出、锁屏 / 睡眠、磁盘写入失败：尝试按相同顺序
  finalize。若临时主文件可读，显示时长和路径，让用户选择“保留并导入部分录制”或
  “仅保留文件 / 丢弃无效临时文件”。
- 少于一个可用视频帧的文件视为无效，不导入。
- 用户拒绝导入 partial 时，若文件已经提交到其选择的位置，默认保留文件，不擅自
  删除；只有明确选择删除才执行。

## 12. 状态机与并发约束

建议显式状态：

```text
idle
 └─ configuring → choosingSource → choosingDestination → countingDown
       └─ starting → recording → stopping → finalizing → importing → idle
                         └──────────── failure / partialRecovery ─────────┘
```

### 12.1 必须满足的状态机规则

- 同一时间 App 只能有一个录制 session；reservation 从进入 configuring 到导入 /
  清理终态才释放。
- 每个异步 callback 携带 session UUID；旧 session 回调不得改变新 session 状态。
- Stop、capture error、窗口关闭、Quit 都汇入同一个终止动作；只能有一个调用者拥有
  finalize 责任，其余等待结果。
- 每个 `await` 前后检查 session identity / cancellation；工程写回前再检查
  document generation。
- coordinator 是 `@MainActor ObservableObject`；sample buffer 和 writer 状态绝不
  放在主 actor 上。
- “保存成功”表示最终文件已提交；“导入成功”表示工程事务已完成。两者是两个明确
  阶段，导入失败时也不能谎称文件丢失。

### 12.2 App 退出

存在 configuring / recording / finalizing 会话时，`applicationShouldTerminate` 返回
`.terminateLater`：

1. 若尚未真正开始，确认取消录制并清理。
2. 若正在录制，询问“停止录制并退出 / 取消退出”。
3. 选择退出后调用同一个幂等 Stop，等待 drain、finish、validation 和导入决策。
4. 再调用现有工程 `prepareToCloseDocument` / 写盘流程。
5. 全部完成后只调用一次 `NSApp.reply(toApplicationShouldTerminate:)`。

反复按 Quit、Stop 与 Quit 同时发生、writer 失败都必须有测试。不能对尚处于
`.unknown`、从未开始 export / writer 的对象盲目 cancel；现有预渲染 bug 案例已经
证明这种竞争可以让 App 崩溃。

## 13. 权限和 Info.plist

最低系统迁移时补齐并本地化：

- `NSScreenCaptureUsageDescription`：说明用于把所选屏幕 / 窗口 / 区域录入视频工程。
- `NSAudioCaptureUsageDescription`：说明用于录入电脑正在播放的声音。
- `NSMicrophoneUsageDescription`：说明可选麦克风会成为独立音频轨。

权限不能套一个统一前置门槛，必须按来源分层：

| 来源 / 条件 | 行为 |
| --- | --- |
| 单窗口 | 不调用广域 screen preflight、不先枚举 `SCShareableContent`；直接呈现系统 picker，使用其返回 filter。失败 / 取消按 picker callback 收尾 |
| 整个显示器 | 先让用户通过 picker 选屏，不在 picker 前做广域 preflight；选定后为排除 Stop panel，基线方案再取得广域权限并重建 display filter。Phase 0 若证明可在 picker scope 内用公开 API 稳定排除，再移除后一步 |
| 自定义区域 | 自建 `SCDisplay` + `sourceRect` + excluding filter，必须先做广域屏幕权限 preflight；拒绝时显示系统设置入口和重试，不循环弹窗 |
| picker 不可用 / 启动失败 | 显示系统错误并回到 idle，不把它一概伪装成 TCC 拒绝 |
| 电脑音频被单独报告为不可用 | 不静默；允许用户改为仅画面或取消 |
| 麦克风关闭 | 不请求麦克风权限 |
| 麦克风开启但拒绝 | 提示后继续画面 + 电脑声音 |
| 麦克风设备消失 | 开始前解析真实默认设备并显式传 ID；仍无设备则关闭 mic 并提示。录制中消失则主录屏继续、mic 标记 partial |
| Save Panel 取消 | 释放 reservation，不建工程记录 |

这里的“单窗口不做广域 preflight”不等于删除用途说明或假设所有 macOS 15.x 行为
完全相同。系统 picker 自身就是所选内容的同意界面；`NSScreenCaptureUsageDescription`
仍保留，真实 `.app` 在干净 TCC 环境逐版本验证。整屏路径的权限成本来自“只排除
SrtFlow 控制窗但保留其他 SrtFlow 窗口”的产品要求，而不是 picker 选屏本身。

当前 App 没有 sandbox entitlement，本方案不新增 sandbox、system extension 或驱动。
若未来启用 sandbox，sidecar sibling 的授权范围必须另行验证，不能假设今天的保存
行为仍自动成立。当前打包还是 ad-hoc 且没有 hardened runtime；Phase 0 必须用真正
的 `.app` 验证麦克风授权。只有签名模式确实要求时才增加最窄的 audio-input
entitlement，不顺手开启整套 App Sandbox。

## 14. 最低系统升级的影响面

实现录屏前先完成一个可独立验证的 macOS 15 baseline 变更：

1. `Package.swift`：保留 tools 5.9，平台改 `.macOS("15.0")`。
2. `packaging/Info.plist`：最低系统 15.0，并加入三项用途说明。
3. 打包脚本内的中英文 README / 安装说明同步为 15。
4. `README.md`、`SrtFlow-Requirements.md`、`docs/build/` 当前事实同步更新。
5. `checks/ProjectFile`、`checks/PreviewComposition` 等硬编码
   `arm64-apple-macosx14.0` 的 target triple 升为 15.0。
6. 审计 `#available(macOS 15, *)`：最低系统已保证的分支可简化；macOS 26 的字幕
   能力保护继续保留。
7. 原生字幕旧计划保留历史内容，只在顶部 / 索引注明其“构建基线 v14”已被本计划
   的全局 macOS 15 决策取代，不改写过去的设计记录。
8. `docs/architecture/keyframe-animation.md` 中固定 30 fps / 1/60 的长期说明在帧率实现
   落地时同步更新。

`VideoEditPrerender` 当前有意保留旧的 callback 导出 API，以规避“启动和取消竞态”
导致的崩溃。提升最低系统后会更显眼地出现 deprecated warning，但不能为了消警告
草率改成另一条有竞争的路径。Phase 0 先验证新 async export + status-gated cancel；
只有能证明 cancel 永远不会打到 `.unknown` session 才迁移，否则第一版保留这一个
受控旧调用并记录原因，正确性优先于零 warning。

## 15. 建议的新文件与现有文件改动

### 15.1 新文件

- `VideoEditFrameRate.swift`：工程帧率枚举和时间换算。
- `ScreenRecordingModels.swift`：request、source、result、error、state 和精确临时文件
  manifest 等值类型。
- `ScreenRecordingCoordinator.swift`：App 级状态机、权限、生命周期、最终导入。
- `ScreenCaptureEngine.swift`：ScreenCaptureKit stream 和 delegate bridge。
- `ScreenRecordingWriter.swift`：双 writer、时间戳、背压、finalize、validation。
- `ScreenRecordingSourcePicker.swift`：系统 picker adapter。
- `ScreenRecordingCoordinateMapper.swift`：多屏 / Retina 坐标纯函数。
- `ScreenRecordingSetupView.swift`：录制设置。
- `ScreenRecordingRegionPanel.swift`：自定义区域 AppKit overlay。
- `ScreenRecordingControlPanel.swift`：倒计时 / 计时器 / Stop 浮窗。
- `VideoEditProject+ScreenRecording.swift`：单事务入轨。

若任一 UI 文件接近 800 行，再按 setup / region / control 的真实职责拆分；不提前造
泛型框架。

### 15.2 现有文件只做薄接线

- `SrtFlowApp.swift`：创建全局 coordinator，接入异步 Quit，并在启动时按 manifest
  精确恢复或清理上次崩溃遗留的录制文件。
- `VideoEditView.swift`：入口、状态展示和 environment 注入。
- `VideoEditProjectDocument.swift` / `VideoEditProjectBar.swift`：工程切换 guard。
- `VideoEditProject.swift`：只增加瞬态 `canvasEditGeneration`，所有画布比例写入入口统一
  递增；实际录屏入轨仍放 extension，避免继续养大该文件。
- `VideoEditModels.swift`：只添加 `TimelineState.frameRate` 的字段 / Codable 接线；主要
  类型放新文件。
- `VideoEditFormatVersion.swift` / `VideoEditProjectFile.swift`：v5。
- `VideoEditCompositionBuilder.swift`、`VideoEditExporter.swift`、
  `VideoEditPrerender.swift`、`VideoEditAnimation.swift`、
  `VideoEditProject+Keyframes.swift`：消费工程帧率。
- `EncodeSettingsView.swift`：支持 Video Edit 隐藏无效规格控件并显示固定规格；通用
  压缩 / 烧录调用方保持原行为。

## 16. 错误与恢复矩阵

| 阶段 | 失败例子 | 必须结果 |
| --- | --- | --- |
| 选择来源 | picker 用户取消 | 返回 idle，不创建文件、不 dirty；不能把取消误报成 TCC 拒绝 |
| 选择来源 | picker 返回失败 / 来源消失 | 保留原始错误；只有明确权限错误才引导系统设置 |
| 构造来源 | 单窗口 picker 成功 | 直接使用 picker filter，不预先要求宽泛屏幕权限 |
| 构造来源 | 整屏排除控制窗或自定义区域所需宽泛权限拒绝 | 不创建文件，说明该来源为何需要权限并提供系统设置入口，释放 reservation |
| 选择目标 | Save Panel 取消、目录不可写、低于最小空间阈值 | 不倒计时，不创建最终文件 |
| starting | encoder 不支持尺寸、stream 启动失败 | 停止并清理空临时；保留原目标 |
| recording | stream 中断 | 尝试 partial finalize，主工程仍可用 |
| recording | mic 设备断开 | 主录屏继续，mic 失败显式报告 |
| recording | writer backlog 溢出 | 不静默丢音频；停止并走 partial |
| recording | 可用空间跌破安全线 / 实际写入返回 ENOSPC | 主动 Stop 或进入 partial；不能承诺仅靠开录前检查避免磁盘满 |
| finalizing | 主 writer 失败 | 不替换目标，不导入损坏文件 |
| finalizing | mic writer / commit 失败 | 保留并导入有效主录屏，报告 mic 状态 |
| validation | 无 video track / 零帧 | 判无效，不导入 |
| importing | document generation 不符 | 保留文件，不写错误工程 |
| importing | 工程事务失败 | 文件保留，工程回滚；提供稍后手动导入路径 |
| quitting | Stop / Quit 竞争 | 只 finalize 一次，最终只 reply terminate 一次 |
| 下次启动 | `ScreenRecordingManifestStore` 中存在活跃 session manifest（**不是 UserDefaults**） | 只检查其中点名的路径；裁决 = stage × 目录观察（区分「缺失」与「卷不可达」）；有效 partial 提示恢复，无效临时文件精确删除，绝不 glob 扫目录；清账须过 `canClearManifest` |

## 17. 测试与验证计划

### 17.1 Phase 0 技术尖峰（进入产品实现前必须全绿）

做一个不接产品 UI / 工程模型的最小临时 `.app` harness；它只保留验证 TCC、picker、
Stop panel 和 writer 所必需的界面，验证：

1. 在干净 TCC 状态分别走三条来源：单窗口 picker 直接使用返回 filter；整屏 picker
   选源后为排除 Stop 窗重建 display filter；自定义区域读取 display 并重建 filter。
   记录每一步真正触发的授权、拒绝错误和系统设置恢复行为，不能把 picker 取消、来源
   消失或一般失败一律解释成屏幕权限拒绝。屏幕 / 电脑音频是否联合授权也以实测为准。
2. macOS 15 的 `.screen`、`.audio`、`.microphone` 三类 stream output 的真实 format、
   PTS epoch 和 `SCStream.synchronizationClock` 关系；麦克风启用时必须传入已解析的
   `AVCaptureDevice.uniqueID`，同时覆盖默认设备不存在的情况。
3. 同一 `T0` 写两个 writer 后，`.mov` 与 `.m4a` 的开头空隙、时长和末端是否保留。
   同时检查 AAC priming 的 edit list / sample group 表达，并把两文件解码成 PCM，以
   click / 拍手峰值验首帧对齐；不能只比较容器 PTS，也不能无条件减 2112 samples。
4. 10 分钟和 30 分钟 click-track + 拍手测试没有累计漂移，末端 PCM 峰值差不超过
   1 个工程帧。
5. 44.1 / 48 kHz、mono / stereo 麦克风和明确 device ID 都能生成可导入 AAC
   sidecar；设备断开或无默认设备时，主录屏继续且状态不伪装为已录麦克风。
6. 1080p、4K、5K / 超宽屏 H.264 `canApply`、实际编码尺寸和文字清晰度。
7. BGRA、鼠标指针以及系统 `showMouseClicks` 的实际输出；点击效果以系统 API 的结果
   为边界，不引入事件监听或自绘兜底。
8. SrtFlow 自己播放的声音在 `excludesCurrentProcessAudio = false` 时确实被捕获。
9. 整屏和区域 filter 都按 window ID 排除 Stop 控制窗，SrtFlow 其他窗口仍完整出现；
   单窗口来源保留 picker 原 filter，不为排除无关控制窗擅自重建。
10. 主屏 / 负原点副屏 / 混合 Retina 的区域坐标像素网格。
11. 完全静止画面只产生 idle frame 时，正常 Stop 后文件时长仍覆盖到 `T1`；若
    `endSession` 不足以延长最后一帧，验证补一份尾帧的最小做法。
12. Stop、stream error、启动后立即 Stop、低空间主动停止和真实 ENOSPC 的 writer
    状态；开录前空间检查只验证阈值，不把估算当成容量保证。
13. 写入活跃 session manifest 后强杀进程，重启时只能处理 manifest 精确点名的文件；
    可播放 partial 可恢复，无效临时文件可清理，目录中其他相似文件不受影响。
14. 新 async `AVAssetExportSession` 取消路径是否满足现有预渲染原子启动约束。

任何一项不通过，先把实测结论写回本计划对应章节和第 22 节，再改正式代码；不能把
未知行为藏进产品分支。

### 17.2 自动化纯逻辑检查

- `ProjectFrameRate` 24 / 30 / 60 的 frameDuration 和半帧换算。
- project v5 round-trip；v1–v4 缺失字段回退 24；未来版本拒绝。
- `selectionForExport`、临时 prerender timeline 保留帧率。
- 关键帧在不同 fps 和 clip speed 下的容差分空间验证：set / replace / remove /
  `allKeyTimes` / `merged` 在 source time 使用“工程半帧 × `abs(speed)`”；next /
  previous 映射到 timeline time 后只使用工程半帧，不再乘 speed。
- 区域比例、反向拖动、屏幕 clamp、负原点和偶数像素取整。
- 文件 basename / `-Mic` / 临时 sibling / 冲突处理。
- 状态机合法迁移、重复 Stop、stale session callback 和 Quit 竞争。
- 音视频 PTS 减零、早期 buffer 裁切、倒退 sample 拒绝、共同 T1。
- 最小空间阈值公式、运行期空间警戒和 ENOSPC 到 partial 的状态映射。
- 活跃 session manifest 的全值覆盖、精确路径校验、成功提交后清除，以及崩溃重启
  恢复；测试同目录相似文件永远不会被误删。
- 一次导入事务：主轨末尾、磁吸 / 转场后实际起点、独立 audio lane、linkGroup、
  Undo 不删文件。
- 画布自动采用录制比例只在开始和结束都没有视觉素材、比例值未变且
  `canvasEditGeneration` 未变时发生；覆盖录制期间改比例后又改回原值的用例。

### 17.3 现有自检扩展

- `swift run SrtFlowCoreChecks`：帧率参数构造和相关纯逻辑。
- `scripts/check-project-file.sh`：v5、24 fps 默认、selection export、录屏 linked pair
  持久化。
- `scripts/check-preview-composition.sh`：24 / 30 / 60 下 frameDuration 与合成结果。
- 导出检查新增 2 秒合成素材：24 / 30 / 60 分别验 48 / 60 / 120 个输出帧，并扫描
  Video Edit 导出滤镜不再残留固定 `fps=30` / `r=30`。
- `scripts/check-export-alpha-compositing.sh` 在脚本头明确标注“手工复制的独立 alpha
  fixture，不构成生产 `VideoEditExporter` 滤镜回归”，并把 fixture 的 `FPS` 参数化，
  至少跑 24 / 30 / 60 三档，防止 alpha 数学本身继续夹带 30 fps 假设。
- 上一条 2 秒生产导出检查独立负责真实 `VideoEditExporter` 接线和输出帧数；不能用
  alpha fixture 通过来替代生产路径回归。

### 17.4 真实 GUI / TCC 冒烟矩阵

按 `docs/testing/gui-smoke-testing.md` 的真实窗口方法执行，至少覆盖：

- 整屏、单窗口、自由区域、五种固定比例。
- 主屏 / 副屏 / 负原点 / Retina 混合。
- SrtFlow 自身窗口和自身正在播放的视频 / 音频。
- 录制控制窗、倒计时、区域 overlay 均不入画。
- 指针开、点击效果开 / 关。
- 电脑声音开 / 关；麦克风开 / 关；扬声器与耳机提示。
- 干净 TCC 下分别验证单窗口 picker、整屏 picker + 控制窗排除、自定义区域三条来源；
  再覆盖电脑音频 / 麦克风首次允许、拒绝和从系统设置恢复，确认 picker 取消不会被
  显示成权限拒绝。
- 24 / 30 / 60 fps 录制和导出，确认工程规格一致。
- 空工程自动画布、已有工程画布不变；录制期间手动修改画布以及“改后又改回”都不被
  导入逻辑覆盖。
- Save 取消、同名、只读目录、外置盘拔出、开录前低于阈值、录制期空间耗尽。
- 正常 Stop、启动后立即 Stop、意外中断、睡眠 / 锁屏。
- 写入数秒后强杀 App 再启动，验证 manifest 只恢复 / 清理本 session 精确点名的文件。
- 录制时尝试 New / Open / Open Recent / Finder 打开工程。
- 录制时切换 SrtFlow 页面后仍能 Stop；录制中 Quit。
- 导入后的链接移动 / 裁切、Undo / Redo、保存重开和媒体 relink。

### 17.5 构建与包体验收

```bash
swift build --arch arm64
swift run SrtFlowCoreChecks
scripts/check-project-file.sh
scripts/check-preview-composition.sh
scripts/check-export-alpha-compositing.sh
scripts/build-app.sh
```

验收打包产物的 `Info.plist` 最低系统和三项用途说明，确认 Apple Silicon 二进制，并在
干净 TCC 环境做首次授权流程。测试期间生成的录音录像只能放临时目录或明确 fixture
目录，不能提交用户内容。

## 18. 分阶段实施顺序

### Phase 0：权限 / API / 时钟 / 编码尖峰

- 完成第 17.1 节所有硬门槛。
- 把各来源实际权限边界、控制窗排除方式、最终 PTS / AAC priming 对齐策略、H.264
  尺寸 / 码率边界和 mic gap 方案写回本计划。
- 不接工程 UI，不改 formatVersion。

退出条件：三条来源的权限和排除策略可重复、双 writer 文件可重复生成、解码后 PCM
同步指标达标、Stop / ENOSPC / 崩溃后的 partial 可恢复。

### Phase 1：macOS 15 基线 + 工程帧率

- 提升最低系统、补 Info.plist、本地化和文档 / target triple。
- 加 `ProjectFrameRate`、工程 v5、24/30/60 UI。
- 贯通 preview / export / prerender / keyframe。
- 扩展 project、preview、export 自检。

退出条件：无录屏功能时，三档工程的预览和导出已经共享一个帧率事实来源。

### Phase 2：来源选择和 UI 骨架

- App 级 coordinator / reservation / state machine。
- setup、系统 picker、自定义区域、Save Panel、倒计时和控制 panel。
- 工程 New / Open / 外部打开 guard。
- 接 mock engine 验完整取消、stale callback 和 Stop / Quit / Close 竞争；本阶段即把
  `applicationShouldTerminate` 改成 `.terminateLater` 并验证只 reply 一次，不等真
  writer 接入后才改退出协议。
- 建立活跃 session manifest 的全值写入 / 清除 / 启动恢复骨架，用 mock 临时文件证明
  只处理精确点名路径。

退出条件：所有 UI 状态可逆，控制窗 exclusion 和多屏区域几何实测通过，mock 录制中
Quit 不会同步杀进程，manifest 恢复不会波及其他文件。

### Phase 3：正式 capture + 主文件

- 接 `SCStream` 的 screen + system audio。
- 主 writer、背压、共同 T0 / T1、validation、临时到最终原子提交。
- 接通真实 manifest 生命周期、运行期空间监测、正常 Stop、ENOSPC 和 partial recovery。

退出条件：整屏 / 窗口 / 区域录屏可稳定生成 H.264 SDR MOV，含 SrtFlow 自身声音。

### Phase 4：麦克风、入轨和真实退出回归

- 麦克风设备 / 权限 / 独立 writer 和同步。
- 专用单事务导入、独立音频 lane、linkGroup、画布规则。
- 用双 writer 重跑 Phase 2 已建立的 `.terminateLater` / Close / Stop 异常矩阵，验证
  真实 drain、finalize、导入和工程落盘完成后才 reply terminate；不在本阶段首次设计
  退出协议。

退出条件：麦克风失败不拖垮主录屏，正常录制自动入轨，Quit 不丢文件 / 工程。

### Phase 5：全量验证、文档和收尾

- 跑自动化、真实 GUI / TCC、长时、磁盘和多屏矩阵。
- 更新 README、Requirements、build / architecture 文档和 AGENTS 索引状态。
- 新发现的 bug 按仓库规则在 `docs/bugfixes/` 记录；沉淀出的长期约束进
  `docs/architecture/`。
- 清理临时 harness 或把有长期价值的部分移入 checks。

退出条件：第 19 节全部满足，且打包 App 在干净 macOS 15+ 环境完成端到端录制。

## 19. 完成定义

只有同时满足以下条件，功能才算完成：

1. 三种来源和所有区域比例可用，跨屏被明确阻止；单窗口 picker 不被不必要的宽泛
   权限预检拦住，整屏 / 区域因控制窗排除而需要的权限有准确提示和恢复路径。
2. SrtFlow 主窗口和自身播放声音可录，整屏 / 区域的录制控制 UI 不入画，picker 取消
   或一般失败不会被误报成权限拒绝。
3. 电脑声音默认开启；麦克风默认关闭、可选、使用明确设备 ID、独立入轨且长时无
   累计漂移；AAC priming 由容器时间结构表达并通过解码后 PCM 峰值验收。
4. 24 / 30 / 60 fps 从项目文件到预览、录屏、导出、预渲染和关键帧全链路一致。
5. 正常 Stop 后文件先校验再入轨，视频位于主轨末尾，麦克风与它链接并同起点。
6. New / Open / 外部工程切换和 Quit 的所有竞争路径都不会写错工程或丢录制。
7. 失败不覆盖既有用户文件；有效 partial 可恢复；崩溃重启只按精确 manifest 处理
   孤儿文件；Undo 不删除磁盘录制。
8. 工程格式 v5、自检、真实 GUI / TCC、长时同步、arm64 构建和打包验收全部通过。
9. 开录前空间检查不被当作容量保证；运行期低空间和真实 ENOSPC 都能安全停止或保住
   可恢复 partial。
10. 没有第三方依赖、虚拟声卡、系统扩展、旧 macOS 分支、点击效果自绘路径或未说明
    的 30 fps 常量。

## 20. 技术风险清单与硬门槛

| 风险 | 影响 | 门槛 / 缓解 |
| --- | --- | --- |
| 把 picker 授权和宽泛屏幕 TCC 当成同一路径 | 单窗口被无谓拦截，或整屏 / 区域排除控制窗失败 | 按来源分层；单窗口保留 picker filter，整屏 / 区域在 Phase 0 实测重建 filter 的权限与错误 |
| picker filter 无法同时满足整屏来源和动态控制窗排除 | 要么录入 Stop 窗，要么需要更宽权限 | 先建 Stop 窗再构造最终 filter；Phase 0 寻找稳定公开的 picker-scoped 路径，找不到则以不录入控制窗为优先并准确提示权限 |
| mic 与 screen PTS epoch 不同 | 独立轨开头错位 | 【Phase 0 已销】实测三路同时基，无需 offset；仅 timescale 不同（mic 48000）需换算。**不固化任何 offset 常量** |
| m4a 折叠首尾空隙 | sidecar 看似同起点但内容提前 | writer / composition 实测，必要时只补缺失静音 |
| AAC encoder priming 约 2112 samples | 24 fps 下仅编码延迟就可能超过一帧同步预算 | 用 edit list / sample group 表达；验收比较解码 PCM 峰值，不硬减固定样本数 |
| 5K H.264 尺寸不受支持 | 静默掉进软件编码器（CPU 飙升/掉帧），**不是失败** | 【Phase 0 已销】`canApply` 已证伪（对 8K 也 true）；按**单边 ≤4096** 等比缩（`fitToHardwareEncoder`），与总像素无关 |
| 多屏坐标系翻转 / 偏移 | 录错区域 | 纯函数测试 + 像素网格实录 |
| 控制窗 exclusion 失效 | 控制 UI 入画 | 开始前取得 window ID、重建 filter、端到端实录 |
| 音频背压 | 缺音 / 漂移 | 有界 backlog，超限显式 partial，不静默 drop |
| Stop / Quit / stream error 竞争 | 双 finalize、崩溃、坏文件 | session UUID + 单一终止所有权 + 幂等状态机 |
| 导入时工程已变化 | 素材进入错误工程 | UI guard + document generation 双层校验 |
| 用户录制期间修改画布后又改回 | 空工程导入误覆盖用户选择 | request 保存比例快照和 `canvasEditGeneration`，值与 generation 都未变才自动设置 |
| 开录前估算低估或录制期磁盘耗尽 | writer 失败、partial 丢失 | 阈值预检 + 低频运行期监测 + ENOSPC partial；不承诺事前算出最终体积 |
| App 崩溃遗留隐藏临时文件 | 文件永不回收或宽泛清理误删用户文件 | 【Phase 2 订正】`ScreenRecordingManifestStore`（原子写单文件，**非 UserDefaults**）保存精确 session manifest；下次启动只验证 / 处理点名路径，禁止 glob；清账须过 `canClearManifest`（现场有结论 **且** 处置已了结）|
| 最低系统升级牵动字幕路径 | 回归现有功能 | 独立 baseline phase，保留 macOS 26 capability guards |
| AEC 期望膨胀 | 工期和质量不可控 | 明确非目标，独立轨 + 耳机提示 |

## 21. 参考资料

- [Apple — ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)
- [Apple — Capturing screen content in macOS](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)
- [WWDC24 — Capture HDR content with ScreenCaptureKit](https://developer.apple.com/videos/play/wwdc2024/10088/)
- [Apple — SCContentSharingPicker](https://developer.apple.com/documentation/screencapturekit/sccontentsharingpicker)
- [Apple — SCContentSharingPickerConfiguration.excludedWindowIDs](https://developer.apple.com/documentation/screencapturekit/sccontentsharingpickerconfiguration-swift.struct/excludedwindowids)
- [Apple — SCContentFilter.init(display:excludingWindows:)](https://developer.apple.com/documentation/screencapturekit/sccontentfilter/init(display:excludingwindows:))
- [Apple — NSScreenCaptureUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nsscreencaptureusagedescription)
- [Apple — NSMicrophoneUsageDescription](https://developer.apple.com/documentation/BundleResources/Information-Property-List/NSMicrophoneUsageDescription)
- [Apple — NSAudioCaptureUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nsaudiocaptureusagedescription)
- [Apple — Background AAC encoding](https://developer.apple.com/documentation/quicktime-file-format/background_aac_encoding)
- [Apple — Using track structures to represent encode delay explicitly](https://developer.apple.com/documentation/quicktime-file-format/using_track_structures_to_represent_encode_delay_explictly)
- [WWDC19 — Advances in AVAudioEngine](https://developer.apple.com/videos/play/wwdc2019/510/)
- [WWDC23 — What’s new in voice processing](https://developer.apple.com/videos/play/wwdc2023/10235/)
- [工程文件架构](../architecture/video-edit-project-file.md)
- [预览自由变换架构](../architecture/preview-free-transform.md)
- [关键帧动画架构](../architecture/keyframe-animation.md)
- [构建与打包](../build/build-and-packaging.md)
- [GUI 冒烟测试](../testing/gui-smoke-testing.md)

## 22. 未决问题

产品问题：**无**。

Phase 0 要回答的是 API 和设备实测问题：三类来源各自的权限边界、整屏 picker 与动态
控制窗排除能否同时满足、三路 PTS epoch、AAC priming / m4a gap、5K 编码边界、坐标
映射、真实 ENOSPC，以及新异步导出的取消安全。其验收标准和失败处理已经写死；它们
不是需要用户重新选择产品方向的问题。若实测迫使范围或用户体验发生变化，再暂停
实现并单独确认。
