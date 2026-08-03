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
- `SRTFLOW_SMOKE_VIDEO=<视频路径>` —— 进入 Edit Video 时项目为空则自动导入该
  视频上主轨。NSOpenPanel 自动化（⌘⇧G 输路径）不可靠，别再试；文件对话框类
  交互一律靠这个钩子或留给用户手测。
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
- **不可注入**：真实 magnify 捏合事件公开 API 造不出来（type 29 私有字段的
  hack 不可靠）。捏合的最终验证只能：用户按一次，或
  `log stream --predicate 'category == "timeline-zoom"'` 实时确认。
  **`log show` 事后查 ad-hoc 调试拷贝查不到任何日志**，别浪费时间。
- **注入前查窗口叠放**：按坐标遍历 CGWindowList 确认目标点没被别的窗口盖住
  ——cmux 终端自己就常盖在上面，事件会全进错窗口，且截图（按窗口 ID）看不出
  任何异常，极易误判"注入无效"。
- **`postToPid` 只对键盘可靠，鼠标事件会静默丢**：点击/拖动要走全局 HID
  （`CGEvent.post(tap: .cghidEventTap)`，先 `CGWarpMouseCursorPosition`），
  前提是上一条已确认目标窗口在最前。
- **窗口坐标每次注入前现查**：窗口会被挪动（激活时也可能自己移），拿会话
  开头缓存的 bounds 换算，点击会整体偏移到别的控件上——按窗口 ID 截的图里
  一切正常，唯独行为"莫名其妙"，就是这个原因。

## 五、收尾

- 杀掉 SrtFlowDev 进程，删临时 .app。
- 正式交付走 `scripts/build-app.sh`，并对 dist 产物重复第一步的
  arch + strings 验证。
