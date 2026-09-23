# GUI 冒烟测试流程（真实窗口，非仅编译）

> 适用场景：改了 SrtFlow 的界面/交互后，在这台 Mac 上用真实窗口验证。
> 2026-08-03 实战总结，每一条都是踩过的坑。

## 一、构建与组装

1. **必须 `swift build --arch arm64`**。终端可能跑在 Rosetta 下，裸 `swift build`
   会编成 x86_64，`.build/arm64-apple-macosx/debug/` 里还是旧二进制——详见
   `docs/build/build-and-packaging.md`。
2. 用 `strings <二进制> | grep <本次新增的字符串>` 验明产物真含新代码再往下走。
3. **改名启动，避开同名进程**：用户常年开着 /Applications/SrtFlow.app，同名进程
   会让 System Events 匹配错乱（连 `whose unix id is` 都不可靠）。把调试二进制
   装成独立的 `SrtFlowDev.app`（临时目录）：
   - `Contents/MacOS/SrtFlowDev` ← 调试二进制改名
   - `SrtFlow_SrtFlow.bundle` 拷到 `Contents/Resources/` 和 `Contents/MacOS/`
     各一份（Bundle.module 两条查找路径都命中）
   - Info.plist 里 CFBundleExecutable/CFBundleName/CFBundleIdentifier 一并改掉
   - `codesign --force --sign -` ad-hoc 签一下

## 二、环境变量钩子（不设即完全不生效，正式包可安全保留）

从 shell 直接跑 `SrtFlowDev.app/Contents/MacOS/SrtFlowDev` 才能继承环境变量
（`open` 不传 env）：

- `SRTFLOW_FFMPEG=<repo>/vendor/ffmpeg` —— 临时目录的拷贝找不到随包 ffmpeg，
  会报"视频引擎有问题/无 libass"，用它指回去。
- `SRTFLOW_SMOKE_VIDEO=<路径>[:<路径>...]` —— 进入 Edit Video 时项目为空则自动
  导入这些文件，按 `:` 分隔（PATH 惯例），`addMedia` 按类型分流。**要验字幕相关
  的界面就再挂一个 `.srt`**（`smoke.mp4:smoke.srt`），否则拿不到「有字幕」的
  状态，字幕面板里大半控件都不出现。NSOpenPanel 自动化（⌘⇧G 输路径）不可靠，
  别再试；文件对话框类交互一律靠这个钩子或留给用户手测。
- `SRTFLOW_SMOKE_PROJECT=<路径>` —— 进入 Edit Video 时项目为空则打开这份
  **已存在的工程**（2026-09-22 加）。
  **调试拷贝打不开文档，三条路实测全灭**：命令行参数、`open -a <临时 app> <文件>`、
  AppleScript 的 `tell app to open POSIX file` —— 临时目录里 ad-hoc 签名的拷贝
  没在 LaunchServices 注册文档类型。没有这个钩子，凡是只在「打开工程」这条路径上
  跑的东西（素材重链接、格式版本迁移、音频库的 `remoteKey` 恢复）都只能人手点。
  工程文件可以手写，但 **`savedAt` 必须是 ISO8601 字符串**（reader 设了
  `dateDecodingStrategy = .iso8601`），给数字会被判成「不是 SrtFlow 的工程文件」。
- 测试视频用 vendor/ffmpeg 现造：`-f lavfi -i testsrc2=... -c:v h264_videotoolbox`。

## 三、驱动与截图

- **点菜单，别发快捷键**：`keystroke` 会被终端(cmux)抢焦点漏进别的应用。
  `click menu item "Edit Video" of menu "File" of menu bar item "File"` 可靠。
- **按窗口 ID 截图，别依赖 frontmost**：CGWindowListCopyWindowInfo 按 pid 找
  kCGWindowNumber，`screencapture -l <id> -x` 可无视遮挡；加 `-o` 去阴影后
  图像与窗口坐标是干净的 2x 映射，方便换算注入坐标。
- **别用 `screencapture -R` 截屏幕区域**（2026-09-21 踩坑）：窗口左边缘常在屏幕
  外（`x = -6` 这种），`-R -6,525,300,24` 会被参数解析当成选项，screencapture
  于是**退回交互式截图**并抢走前台 —— 后续注入全落到别处，拍回来的图是另一个
  应用的界面，看起来像是「产品行为莫名其妙」。要局部就 `-l` 截整窗口再
  `sips -c <h> <w> --cropOffset <top> <left>` 裁，坐标也更稳（窗口内坐标 ×2）。
- **每次注入前重新激活目标进程**：终端一有输出就可能把前台抢回去，而鼠标事件
  只对最前的窗口可靠。`tell application "System Events" to tell process
  "SrtFlowDev" to set frontmost to true` 穿插在每一步之间。

## 四、事件注入的边界

- **可注入**：滚轮（含 Ctrl+滚轮缩放）、点击、拖动——公开 CGEvent API。
  注入滚轮前先 CGWarpMouseCursorPosition 到目标点。
- **要看「拖动**过程**中」的样子：按下后别松手，原地持续发 mouseDragged 当心跳，
  外面同时 `screencapture`**（2026-08-12 验框选时用的）。一次性拖完再截图只能
  看到落地结果，看不到拖框/对齐线/插入指示线这些只在手势期间存在的东西。注意
  换算：注入是分步走的，截图那一刻指针可能只走到中途，别拿终点坐标去核对画面。
- **合成点击会滞留到下一批事件才生效**（2026-08-08 实测）：click 的效果经常
  等到**再来一次注入**才显现 —— 连环盲点会把「上一击的效果」误判成「这一击
  没效果」，然后点开完全无关的控件。对策：每次 click 后补发一个无害的
  mouseMoved 当 flush，**并截图核实状态后再做下一步**；事件构造用
  `CGEventSource(stateID: .hidSystemState)` + `mach_absolute_time()` 时间戳 +
  `mouseEventClickState=1`。副屏负坐标不是问题；键盘 `postToPid` 一直可靠
  （修饰键设 `event.flags = .maskCommand`，Esc=53、⌫=51、Z=6 可发 ⌘Z）。
  System Events 的 `click at {x,y}` 走 AX 动作，是备用点击路径（SwiftUI 的
  剪辑块会被解析成 AX button）。
- **注入带修饰键的按键必须先单独发一拍 flagsChanged，且每拍之间留 ~30ms**
  （2026-09-21 实测）：只发 `keyDown`/`keyUp` 且背靠背时，**每 5 次丢 1 次** ——
  App 那边的本地监听根本没收到那一下。丢事件会被误判成「功能没生效」，我在滤镜
  复制粘贴那一刀上就是这么查了半天产品代码，最后发现是注入的问题。
  改成「⌘ 按下 → 键按下 → 键抬起 → ⌘ 抬起」四拍、每拍后 `usleep(30_000)`，
  实测 8/8 全中。**任何一次「按了没反应」的结论，先把同一个键连发几次数一数**，
  再去怀疑产品。
- **录制控制窗（`sharingType = .none`）自动化够不着**（2026-08-11 实测）：
  `screencapture -l <id>` 拍出来是空白，`CGWindowListCopyWindowInfo` 里
  `kCGWindowIsOnscreen = false`，AX 树和 System Events 的 windows 里也没有它，
  合成点击落到它的位置上不产生任何效果。**录制中的 Stop 只能人手点**。
  自动化要跑「录一段再检查」的流程，请让用户按 Stop，或者干脆绕开 GUI：
  把 `ScreenCaptureEngine` + `ScreenRecordingWriter` 编进独立二进制直接驱动
  （终端进程自己有录屏权限，`CGPreflightScreenCaptureAccess()` 可先确认；
  CLI 里建 `SCContentFilter` 前要先 `_ = NSApplication.shared`，
  否则踩 `CGS_REQUIRE_INIT` 断言直接崩）。
- **不可注入**：真实 magnify 捏合事件公开 API 造不出来（type 29 私有字段的
  hack 不可靠）。捏合的最终验证只能：用户按一次，或
  `log stream --predicate 'category == "timeline-zoom"'` 实时确认。
  **`log show` 事后查 ad-hoc 调试拷贝查不到任何日志**，别浪费时间。
- **hover 可以注入，前提是 event source 不能是 nil**（2026-09-21 更正）。
  这一条以前写的是「SwiftUI 的 hover 对合成 mouseMoved 不响应」，那个结论是
  **错的** —— 真正的原因是事件的 source 传了 `nil`：

  ```swift
  let src = CGEventSource(stateID: .hidSystemState)   // ← 少了它，全程静默无效
  let e = CGEvent(mouseEventSource: src, mouseType: .mouseMoved,
                  mouseCursorPosition: p, mouseButton: .left)
  e?.setIntegerValueField(.mouseEventDeltaX, value: 1)   // delta 也要给
  e?.post(tap: .cghidEventTap)
  ```

  先 `CGWarpMouseCursorPosition` 到位，再连发几拍位置**略有变化**的
  `mouseMoved`（同一个点重复发不算移动）。实测 2026-09-21：扫帧 peek 在剪辑块
  本体、轨道空白、标尺、音频轨四处都被这样驱动起来了，读数取自预览画面里
  testsrc2 烧进去的时间码，与 transport 的播放头读数交叉对照。
  同一个坑连着 `scrollWheelEvent2Source:` —— **nil source 的滚轮事件同样静默
  无效**，`CGWarpMouseCursorPosition` 之后什么也不会发生。
- **`CGWarpMouseCursorPosition` 自己不产生事件**：它只是把指针挪过去。在同一个
  tracking area **内部**挪动，不补一拍真正的移动事件的话，SwiftUI 记的还是旧
  位置 —— 表现就是「hover 回调不再触发」，很容易误判成产品 bug。
- **横向滚动可注入**（2026-08-16 实测）：`CGEvent(scrollWheelEvent2Source:
  units: .pixel, wheelCount: 2, wheel2: dx)`，光标先 warp 进滚动区**内**（点在
  工具栏上整批静默无效）。**水平那一路（`wheel2`）实测驱不动 SwiftUI 的
  `ScrollView`**（2026-09-21：内容宽于视口、窗口在最前，连滚 1/10/120px 窗口
  截图 md5 一字不变）；垂直（`wheel1`）正常。要横向滚动就改用别的手段。
- **带修饰键的注入会把修饰键留在系统状态里**（2026-08-16 踩坑）：Ctrl+滚轮
  缩放注入（`event.flags = .maskControl`）之后，后续**无 flags** 的注入照样
  继承住 Ctrl —— 左键点击全变成 Ctrl+点击（弹右键菜单）、普通滚动全变成缩放，
  而且症状看起来就是「点击失效 / 滚不动」，极像业务 bug。修饰键注入收尾必须
  补一个对应键的 keyUp（Ctrl=59）+ `flags = []` 走 HID 发出去，再继续别的注入。
- **SRTFLOW_SMOKE_VIDEO 挂图片有竞态**：钩子在 Edit Video 的 onAppear 同步
  触发，而 `addImages` 在 ffmpeg toolchain 未解析完时直接放弃（只留一条
  notice）——首次进入必输，图片静默不上轨。绕法：把已导入的块删光让工程变空，
  切去别的栏目再切回来，钩子会带着就绪的 toolchain 重跑。
- **合成点击偶发整次丢失**（~1/10，与滞留是两回事）：关键判定别单点定生死，
  同一点复测一次再下结论 —— 一次失败可能只是丢击，两次全失败才是真死区。
- **「这块区域归谁」用右键探**（2026-08-16 定位标尺死区的关键）：在可疑位置
  注入右键，看弹出的是谁的 contextMenu，无损且一击定位命中区归属；比对照
  截图猜 z 序快得多。探完 Esc（keyCode 53 `postToPid`）收掉菜单。
- **注入前查窗口叠放**：按坐标遍历 CGWindowList 确认目标点没被别的窗口盖住
  ——cmux 终端自己就常盖在上面，事件会全进错窗口，且截图（按窗口 ID）看不出
  任何异常，极易误判"注入无效"。
- **`postToPid` 只对键盘可靠，鼠标事件会静默丢**：点击/拖动要走全局 HID
  （`CGEvent.post(tap: .cghidEventTap)`，先 `CGWarpMouseCursorPosition`），
  前提是上一条已确认目标窗口在最前。
- **窗口坐标每次注入前现查**：窗口会被挪动（激活时也可能自己移），拿会话
  开头缓存的 bounds 换算，点击会整体偏移到别的控件上——按窗口 ID 截的图里
  一切正常，唯独行为"莫名其妙"，就是这个原因。

- **Finder 的拖放注入不了**：CGEvent 驱动 Finder 不会起 `NSDraggingSession`
  （2026-09-22 实测，光标动了、`AXIsProcessTrusted` 也为真，就是不起会话）。
  「从别的 App 拖文件进来」这条路要用下面那套自带拖源的装置。
- **SwiftUI 的 `.onDrag`（App 内拖动）也注入不了**：合成事件能让它起手
  （`.onDrag` 闭包会被调到，拖动图像也跟着指针走），但落不下去，目标那边的落点
  一个回调都收不到（2026-09-23 在探针上重测，同进程的空白探针 App 也一样）。
  外部拖源改拖自定义类型来模拟，在探针上连只有一个落点的对照格都是 op=0 —— 但那是
  因为探针的类型**没在 Info.plist 里声明**（系统认不出没声明的类型，见
  [案例](../bugfixes/2026-09-23-custom-drag-types-not-declared.md)），不是「外部来的
  自定义类型一概不认」。声明之后能不能用外部拖源模拟卡片拖放，还没测。
  **滤镜 / 音频库 / 转场三套拖放目前只能人工验**。
  **也别拿合成拖动做 A/B**：改前改后都落不下去，「结果一样」什么都证明不了 ——
  2026-09-23 就是拿这样一个 A/B 当了「垫层不影响 App 内拖放」的证据，结果三套卡片
  全被垫层吞了（[案例](../bugfixes/2026-09-23-in-app-drops-swallowed-by-file-underlay.md)）。

## 四之二、跨 App 文件拖放的重放装置

`scripts/gui-smoke/external-file-drag/replay.sh <文件> <落点x> <落点y>`

自带一个最小的 AppKit 拖源 App（Finder 不吃合成事件，所以得自己造一个），起的是
真正的跨进程拖放会话，被测 App 那边分不出区别。判据看拖源的
`draggingSession(_:endedAt:operation:)`：

- `op=1` —— 落点被接受；
- `op=0` —— **没人要**：那个位置没有活的文件落点区，或者被某个落点区认领了又扔掉。

`op` 比被测 App 自己的日志更硬：它是拖放会话的最终结果，不依赖被测 App 记账。
坐标是全局屏幕坐标、左上为原点，和 System Events 报的窗口 position 同一套。

这套装置是
[2026-09-23 时间线文件拖放](../bugfixes/2026-09-23-timeline-file-drop-claimed-by-inner-drop-region.md)
那个 bug 定性的唯一手段 —— 在它之前，三轮修复每一轮都要用户实拖一次，而实拖
只能回答「还是不行」。够不着的交互，值得自己造一个源。

拖源窗口摆在**主屏**右上角。多显示器时别用 Finder 的 desktop bounds 算位置（那是
所有屏幕的并集）：2026-09-23 实测算出来的位置不在任何一块屏上，AppKit 把拖源挪到了
被测窗口正上方，盖住落点，重放得到一个假的 op=0。**任何一次 op=0，先看拖源窗口
在哪**（`osascript -e 'tell application "System Events" to get position of window 1 of process "DragSource"'`）。

## 四之三、落点路由探针

`scripts/gui-smoke/drop-routing-probe/probe.sh`

一个独立的 SwiftUI 小 App，每格只放一种落点组合（代理式 / 闭包式 / 空类型、同一
视图叠两个 / 跨视图嵌套），所有回调写日志，启动时打印每格的中心点。配合上面的
`replay.sh` 往格子里拖文件，看 op 和日志里是哪一格收到了回调；顶上两张卡片是
`.onDrag` 拖源，App 内拖动那一半人手拖。

**改时间线的 `.onDrop` 结构之前，先在这儿把想法测一遍。** 在 SrtFlow 里二分，
被测的落点常常被别的落点盖着 —— 「代理式收不到外部拖入」这条错误结论就是这么测
出来的（每次代理都被滤镜 / 音频库的落点挡在外面）。各格的实测结果见
[案例](../bugfixes/2026-09-23-in-app-drops-swallowed-by-file-underlay.md)。

## 五、要真实窗口、但已经自动化了的检查

有些检查**不需要人来操作**，只是需要一个图形会话（会建真实的 `NSWindow` /
`NSPanel`）。它们**故意不进 `scripts/check-all.sh`** —— 那条是本地与 CI 的统一入口，
无图形会话的环境（SSH、别的 runner）跑起来会假红。改到对应模块时在本机跑一遍：

- `scripts/check-instant-tooltip-panel.sh` —— 提示面板的真实落点：摆好之后跑一轮
  排版再量一次，面板不许自己改尺寸或挪位置。改 `InstantTooltip.swift` 必跑。
  用 `.accessory` 策略，不抢焦点、不进 Dock，跑完即退。

## 六、收尾

- 杀掉 SrtFlowDev 进程，删临时 .app。
- 正式交付走 `scripts/build-app.sh`，并对 dist 产物重复第一步的
  arch + strings 验证。
