# 2026-10-03 剪到一半 SrtFlow 突然变回空的 Untitled：关掉主窗口就退出了 App

## 症状

2026-10-02 南极工程：AI 刚打开工程、听了几段配乐，下一次调用就全报错 ——「Music/… does not exist」「Nothing in the project has id …」。
`get_status` 一看：工程变成空的 Untitled，AI 打开过的文件夹也没了（`folders: []`）。用户「当时没有做任何编辑」，原因不明。
那天晚上又来了一次（报告里写成「0.18.20 升级之后重启了」）。系统里没有任何崩溃报告。

## 根因

- **SrtFlow 只有一个 SwiftUI `Window` 场景（外加设置），而这种 App 关掉主窗口就退出。** 写了个最小的 SwiftUI App 实测：
  `Window` + `Settings`，关掉主窗口 → `applicationWillTerminate` 直接走到（2026-10-03，`scratchpad/winprobe`）。
  用户在 AI 剪的过程中关了 SrtFlow 的窗口（AI 每一轮开始时会把它摆到前面），App 就退出了 —— 走的是正常退出，所以没有崩溃报告。
- 小程序下一次调用连不上 socket，就 `open -g` 把 App 拉起来、照常转发：工程、AI 打开的文件夹都是这次运行里的状态，全没了；
  AI 拿到的只是一串「不存在」，自己去猜发生了什么。
- 有意思的是 `AIEditorPresenter` 早就写了「主窗口被关了就开回来」那条路 —— 写的人以为关了窗口 App 还在，这条路从来没机会走到。

## 修复

- `AppDelegate.applicationShouldTerminateAfterLastWindowClosed` 返回 **false**（用户 2026-10-03 定：关窗口不退出、从 Dock 再点开）。
  关了窗口 App 留在 Dock 里、工程还开着、自动保存照旧；点 Dock 图标 SwiftUI 把窗口开回来（同一个最小 App 实测：reopen 事件进来，主窗口回来）；
  AI 的一轮开始时 `AIEditorPresenter` 用存下来的 `openWindow` 开回来。⌘Q 才是退出，没存过的工程照旧问。
- 小程序这一侧：`connectOrLaunch` 报告这次是不是自己拉起来的，是的话在结果最前面加一句 `MCPBridge.relaunchNote`
  （「SrtFlow 刚被重新启动，之前打开的都不在了，重新 open_folder / open_project」），别的内容和 `isError` 原样（`MCPBridge.addingNote`）。
  App 也可能是被用户 ⌘Q 掉的、被装新版本替换掉的，这一句都用得上。

## 验证

- `scripts/check-mcp.sh`：`ProtocolChecks` 里 `addingNote` 的用例（那一句在最前面、原来的文字和图原样跟在后面、出错的照样是出错、提到了
  open_folder / open_project）；扫描：App 代理返回 false、小程序只在拉起来的那一次加这句。**反向验证**：删掉代理方法 → 扫描红
  （「关掉主窗口会退出 App」）；`addingNote` 改成加在最后 → 3 条红（那一句不在最前面、原来的结果和图不在原位）；恢复后 1640 项全过。
- 两个最小 App 实测（`scratchpad/winprobe`）：返回 false 之前关窗即退出；之后关窗不退出、reopen 事件把主窗口开回来。
- 人工回归加进 [AI 接口](../architecture/ai-control-mcp.md) 第八节：关主窗口 App 不退出、点 Dock 回来、AI 改一处窗口被摆回来；没开时让 AI 调用，结果带那一句。

## 教训 / 防回归

- **SwiftUI 的默认生命周期不等于 Mac App 的习惯**：单 `Window` 场景关窗即退出，是框架替我们做的决定；写「窗口被关了怎么办」的代码之前，
  先确认 App 那时候还活着。
- **自动把进程拉起来的那一层，要说出它做了什么**：小程序默默 `open -g` 再转发，AI 只看到一串「不存在」。替别人兜底时，把兜底这件事告诉对方。
