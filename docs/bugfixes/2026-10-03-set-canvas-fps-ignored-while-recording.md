# 2026-10-03 录屏中 AI 改帧率：静默不改，还回成功

## 症状

一段屏幕录制正在进行（手动开的，或 2026-10-03 起 AI 用 `record_screen` 开的）时，AI 调 `set_canvas fps=30`：
结果照常回来（`changed: true`），只是里面的 `fps` 还是原来的 24；SrtFlow 的提示条上亮一句「The frame rate is locked while recording.」，
AI 看不见。AI 以为帧率已经改了，接着按 30 fps 去想后面的事。

做 `record_screen`（[方案](../plans/2026-10-03-screen-recording-mcp.md)）时逐个检查「录制中被锁住的操作」才发现：
以前 AI 碰不到录屏，只有用户手动录的那几分钟里撞得上，所以没人注意。

## 根因

录屏期间帧率冻结（捕获配置在开录前按工程帧率定死，录屏方案 §11.3），挡在执行入口 `VideoEditProject.setFrameRate` 里：
不改、写一句 `notice` 就返回。界面上那句提示是给人看的；`AIOverlayTools.setCanvas` 调完 `setFrameRate` 不看它改没改，
照样回成功 —— 「执行入口的二道闸」对人有提示条兜着，对 AI 就是一次静默的失败。

同一类的还有换工程：`open_project` / `new_project` 在录制中被 `prepareToCloseDocument` 挡住，AI 拿到的是界面那句
「Stop the screen recording first.」—— 以前 AI 停不了录屏，这句话它照做不了（[叫 AI 去面板里选语言](2026-09-29-ai-told-to-pick-language-in-panel.md)
那一类：界面的报错叫人去点哪儿的，AI 那一路要换成它能照做的话）。

## 修复

- `set_canvas`：给了 fps、和现在的不一样、又在录屏中，**先报错、一样都不改**（比例也不改，免得半截生效）：
  「The frame rate is locked while the screen is being recorded. Stop it first with record_screen action=stop, or wait until it finishes」
  （`AIOverlayTools.setCanvas`，那句建议是 `AIScreenRecordingTool.lockAdvice`）。
- 换工程：`AIProjectTools.keepUnsavedEdits`（`open_project` / `new_project` 换之前都经过它）先查 `locksProjectSwitching`，
  回「A screen recording is running in SrtFlow, so the project cannot be switched now. …」，不再走到界面那句。

## 验证

- 扫描守卫 `checks/screen-recording-ai-wiring.sh` 第 10 条：`set_canvas` 里录屏的锁在 `setCanvasRatio` / `setFrameRate` 之前、
  换工程的锁在存未命名工程之前。**反向验证**：临时删掉 `set_canvas` 那三行 → 守卫红「录屏中 set_canvas 改帧率要先报错」；
  删掉换工程那一行 → 红「录屏中换工程要先挡」；恢复后绿。
- 真录屏中调用要真屏幕和授权，写进 [AI 接口（MCP）](../architecture/ai-control-mcp.md) 第八节的人工回归清单。

## 教训 / 防回归

- **执行入口的「二道闸」只亮提示、不报错时，AI 那一路要自己先挡**：给人看的 `notice` 不会出现在工具结果里。
  以后再给 AI 开一个碰得到被锁操作的工具，先问「锁住的时候它拿到的是什么」。
- 长期约束写在 [AI 接口（MCP）](../architecture/ai-control-mcp.md) 第四节第 45 条（录制中的锁）。
