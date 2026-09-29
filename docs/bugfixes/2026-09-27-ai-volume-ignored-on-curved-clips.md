# 2026-09-27 段上画了音量曲线时，AI 调 volume_db 听不出变化

## 症状

AI 给一段画过音量曲线的声音（比如配乐开头淡进、中间压低）调 `edit_clip volume_db`，结果照样回「改好了」，
`get_timeline` 里的 `volume_db` 也变了，可播放、导出听起来一点没变。第一块（PR #81）就有，只在测试版里。

## 根因

段的音量有两种存法：没曲线时是 `volume`，**有曲线时曲线取代 `volume`**（docs/architecture/audio-volume-curve.md）。
`AIClipEdit` 不管有没有曲线，一律写 `volume` —— 写进去的是一个被盖住、不参与发声的值。检查器那边早就处理了：
有曲线时滑杆整条平移曲线（`shiftWholeVolume`）。AI 这条路是照着「改音量 = 改 volume」写的，没去看检查器怎么做。
`get_timeline` 只报 `volume`，也不报曲线，AI 看不出自己改的值没用上。

## 修复

- `edit_clip volume_db` 在有曲线的段上改成整条曲线平移，让「段开头那一点」等于给的 dB（检查器的滑杆在播放头不在段里时
  也以段开头为准）；没有曲线时照旧写 `volume`。上限用 `AudioGain.clampedDecibels`（+6.02 dB，和检查器一样，原来写死 6）。
- `get_timeline` / `edit_clip` 的结果里带上 `volume_curve`（时间线秒 + dB），AI 看得见曲线。
- 同一次顺手给了 AI `volume_curve` 参数（整条换掉、空列表去掉），和 `volume_db` 同时给报错。

## 验证

- `checks/MCP/ClipDetailChecks.swift`：有曲线的段 `volume_db -10`，两个点从 (−6, 0) 平移成 (−10, −4)，`volume` 不动。
- 反向验证：把 `AIClipEdit` 里的判断撤掉、一律写 `volume`，这两条当场红（曲线没动、`volume` 被写成 0.316）；恢复后全过。

## 教训 / 防回归

- **给 AI 开一个参数之前，先看检查器改同一个值时做了什么**：同一个量在模型里可能有两种存法（这里是 `volume` 和曲线），
  检查器早就分了情况。架构文档第四节第 2 条「能复用手动操作的全复用」说的就是这个。
- 回给 AI 的状态要包含决定结果的那个量（曲线），不然 AI 自己核对不出来。
