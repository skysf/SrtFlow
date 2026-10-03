# 2026-10-03 record_screen 真机首测：四处小毛病

## 症状

`record_screen`（PR #155）合并后，用户让出一个测试版、在这台 Mac 上真录。测试版 0.18.23（固定签名、`com.srtflow.SrtFlow.beta`，
之前没有录屏授权），用 `scripts/gui-smoke/mcp-client/client.py` 扮成 AI 客户端一步步调：

| 测了什么 | 结果 |
| --- | --- |
| 没授权时开录 | ✓ 第一次请求了一次授权（系统里新建了测试版的记录、开关关着），回「去系统设置打开、退出重开」；紧接着第二次**没有再弹**，只说还没权限 |
| 用户打开开关、退出重开之后 | ✓ `get_status` 显示 granted |
| 录 SrtFlow Beta 自己的窗口（倒数 0、4 秒自停） | ✓ 2.7 秒回「recording」、到点自停、进 V1、空工程的画布套上录屏尺寸（2848×1738 = 窗口 1424×869 点 × 2）；`look` 看帧是那个窗口 |
| 整屏（主屏，不设时长、AI 叫停） | ✓ 0.7 秒回、AI 叫停 0.6 秒拿到结局，2880×1800 = 主屏原生像素；再叫一次停回刚才那段的结局 |
| 屏幕上一块（rect 0.3 × 0.25） | ✓ 432×225 点 → 864×450 像素 |
| 录制中改帧率、换工程 | ✓ 都被挡、工程没换 |
| 同名录两次 | ✓ 第二个成了 `dup-test 2.mov`，不覆盖 |
| 撤销一步 | ✓ 只退掉最后那一段录制 |
| 录制中 `kill -9` 测试版、重开 | ✓ `get_status` 马上报出残留（add / keep / discard、时长、原因）；开录被挡；discard 先问（令牌）、隐藏的 .partial 进了废纸篓、共用的账本删掉、马上能再录 |
| 每个文件逐轨看 | ✓ 画面轨都盖到结尾（产物合同） |

撞出来的四处：

1. **有残留等决定时，换工程 / 改帧率回的是「有一段录屏正在进行，先 record_screen action=stop」**：其实没在录，是在等决定，照做 stop 也只会再被挡一次。
   AI 的 `open_project` 因此失败，后面录的那段落进了重开后的未命名工程（又照规矩被自动存成 `after-crash.srtflowproj`）。
2. **duration 不准**：要 3 秒录成 3.36–3.67 秒，进程里第一次要 4 秒录成 5.25 秒。
3. **没授权时 `get_status screen=true` 只列出 SrtFlow Beta 自己一个窗口**；授权后同一时刻列出 8 个（6 个 App）。AI 会以为只有它能录。
4. **残留报的是隐藏的临时文件名**（`.crash-test.<UUID>.partial.mov`），丢弃时问用户的也是它 —— 对人没有意义。

另外改了一个说法：结局里不完整的原因原来放在 `cut_short` 下，可第一次录窗口时那条原因是「电脑声音比画面晚 1 秒开始」，不是被截短。

## 根因

1. `AIScreenRecordingTool` 的锁提示只写了「在录」一种。`.partialRecovery`（崩溃留下的残留、手动录制的残缺结果等用户决定）**按设计也锁工程切换**
   （[录屏生命周期](../architecture/screen-recording-lifecycle.md)：素材会进错工程），要的却是 resolve。
2. 按时长停的计时从 `recordingStarted` 起算，那是 `startCapture()` 返回、状态切到 `.recording` 之后；可画面在那之前就流进写入器了（T0 = 第一份采样）。
   中间这一截 0.3–1.2 秒就多出来了。
3. 没授权时系统给的窗口表里，别的 App 的窗口都不算「能录」，只剩 SrtFlow 自己的（授权前后同一时刻 1 个 vs 8 个是实测；系统内部怎么判的没追）。
4. 崩溃留下的录制，`PendingRecovery.result.mainURL` 就是那个临时文件（要拿它探测、提交），报给 AI 时直接用了它。

## 修复

1. `AIScreenRecordingTool.lockMessage(_:)` 按状态说：在录 / 在收尾 → 「stop 或等它完」；在等决定 → 「先问用户、record_screen action=resolve」
   （`AIScreenRecordingLeftovers.waiting` 拆成主语和建议两半，开录 / 停止被挡时拼整句）。换工程、`set_canvas` 改帧率都经它。
2. `ScreenRecordingObserver.recordingStarted(session:alreadyRecorded:)`：协调者带上写入器此刻的已录时长（`writer.elapsed`），任务只等 `duration - alreadyRecorded`。
3. 没授权时 `windows` 换成一句「授权后才列得出（record_screen 会去要）」。
4. 残留报**保存之后叫什么**（`plannedFile`：还在临时文件里的取 manifest 里的最终路径），加 `saved: false`；丢弃时问的是「the unfinished screen recording crash-test.mov（隐藏文件名）」。
5. 结局里的 `cut_short` 改名 `incomplete`（和手动那个框的「Recording is incomplete」同一个口径），落地的下一步只有真有麦克风那一段时才提麦克风。

## 验证

- 扫描守卫 `checks/screen-recording-ai-wiring.sh` 第 10–13 条：锁提示按状态分两支、按时长停扣掉已录的、没授权不列窗口、残留报保存后的名字。
  **反向验证**：四处各撤回一次（等决定时也叫 stop、时长不扣、没授权也列、残留报临时文件名），守卫各红一条；恢复后绿。
- 真机复测（测试版 0.18.24）见下一节。

### 真机复测（0.18.24，同一台 Mac）

| 测了什么 | 修之前（0.18.23） | 修之后（0.18.24） |
| --- | --- | --- |
| 窗口 duration=3 | 3.36–3.67 秒（第一次要 4 秒录成 5.25） | 3.20 秒 |
| 区域 duration=2 | —— | 2.15 秒 |
| 倒数 3 秒 + duration=3 | —— | start 等了 3.7 秒才回（倒数完、真开录了），录 3.22 秒 |
| 崩溃留下的残留 | 报 `.crash-test.<UUID>.partial.mov` | 报 `crash-retest.mov`、`saved: false` |
| 有残留时 open_project / set_canvas fps | 「正在录，先 stop」 | 「在等决定（crash-retest.mov），先问用户、resolve」 |
| 丢弃时问的 | 「the unfinished screen recording (.crash-test….partial.mov)」 | 「the unfinished screen recording crash-retest.mov (.crash-retest….partial.mov)」 |

丢掉之后 open_project 正常、再录 2 秒得 2.19 秒、共用的账本删干净了。换成 0.18.24 时**没有再要录屏授权**：固定签名下测试版的授权也跨版本有效。
剩下 0.15–0.2 秒是叫停本身的延迟（任务醒来、`stopCapture`）。

## 教训 / 防回归

- **真机第一轮就撞出了纯值自检和扫描守卫都够不着的三类东西**：状态的组合（「等决定」也锁工程）、时序（`startCapture` 返回之前就开始写）、
  系统在没授权时给的是残缺的数据。新工具合并之后尽早上真机走一遍，别攒着。
- 「被锁住」的提示要说**为什么被锁**，按原因给下一步；只有一种说法时，另一种原因下 AI 照做只会再碰壁。
- 没改的一处：进程里第一次录（授权刚生效、重开之后），电脑声音比画面晚了 1.0 秒开始，被报成不完整；之后 6 段都在 0.05 秒以内
  （Phase 0 量整屏是 36 毫秒）。只有一个样本、而且那 1 秒确实没录到声音，0.5 秒的容差先不动，写进
  [AI 接口（MCP）](../architecture/ai-control-mcp.md) 第九节的已知不足。
