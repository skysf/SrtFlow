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
- 测试视频用 vendor/ffmpeg 现造：`-f lavfi -i testsrc2=... -c:v h264_videotoolbox`。

## 三、驱动与截图

- **点菜单，别发快捷键**：`keystroke` 会被终端(cmux)抢焦点漏进别的应用。
  `click menu item "Edit Video" of menu "File" of menu bar item "File"` 可靠。
- **按窗口 ID 截图，别依赖 frontmost**：CGWindowListCopyWindowInfo 按 pid 找
  kCGWindowNumber，`screencapture -l <id> -x` 可无视遮挡；加 `-o` 去阴影后
  图像与窗口坐标是干净的 2x 映射，方便换算注入坐标。

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
  **SwiftUI 的 hover（`onContinuousHover`/`onHover`）对合成 mouseMoved 也不
  响应**（2026-08-08 实测：warp 到位 + 连发 move 均不触发 tracking area）——
  悬停类交互与捏合同级：状态机用自检钉住，手感留给用户真机过。
- **横向滚动可注入**（2026-08-16 实测）：`CGEvent(scrollWheelEvent2Source:
  units: .pixel, wheelCount: 2, wheel2: dx)`，光标先 warp 进滚动区**内**（点在
  工具栏上整批静默无效）。滚动事件顺带会刷新 hover tracking——光标停在块上时
  注入滚动，`onContinuousHover` 的 peek 会真的触发，可以借此驱动悬停类状态。
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
