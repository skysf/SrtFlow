# 2026-10-02 AI 起的 upscale 换源之后，检查器里的扣费一直是「—」

## 症状

真实冒烟（Claude Code 调 `upscale_clip`，字节 standard 档，6 秒）做完片段换源成功，`get_job` 的结果里 `cost_usd` 是估价
（`cost_is_estimate: true`，这是预期），但过了几分钟检查器那一节仍写着「Upscaled with ByteDance upscaler · standard on Oct 2, 2026 · —」，
账单明细里早已有这一条的实收。面板起的 upscale 也有同样的窗口：做完立刻点 Replace，之后再也不会显示实收。

## 根因

两处叠在一起：

1. `UpscaleJob.lookUpCost` 做完之后每 30 秒问一次账单明细、最多六次，查到了只改 `job.outcome?.record.costUSD` 和 `actualCost`。
   换源那一步（AI 的 `land`、对比窗口的 Replace）把 **当时** 的 `outcome.record`（`costUSD` 还是 nil）写进了工程，之后查到的钱没人回写，
   工程里的记录永远是 nil，检查器就一直「—」。
2. 换源之后两边都调 `UpscaleActivity.remove(job)`，它先 `job.cancel()` 再从列表里拿掉；`cancel()` 无条件 `task?.cancel()`，
   而账单查询就跑在那个 Task 里：`try? await Task.sleep` 被取消后立刻返回，六次查询在一瞬间问完（账单还没出来）、放弃。
   所以 AI 起的那一路连「查到」都到不了，不只是没回写。

第四刀写对比窗口时账单查询和 Replace 是两条线，没把「Replace 之后记录已经进了工程、查到的钱要追着写」当成一件事。

## 修复

- `UpscaleJob.cancel()` 只对 `.running` 生效：做完之后的 remove / 丢弃 / AI 收尾都不再杀掉账单查询。
- 查到实收时 `onCostResolved?(self)`；换源的两边（`AIUpscaleTool.land`、`UpscaleCompareView.replace`）都接它，
  按文件把钱补进此刻用着这个 upscale 文件的段的记录：`TimelineState.recordUpscaleCost(file:costUSD:)`（纯值）→
  `VideoEditProject.recordUpscaleCost` → `applyDocumentRepair(annotation: true)`：**标脏存盘、不进撤销栈、不重建预览**
  （不是用户的一步操作，⌘Z 不该多一步；只是记录里多一个数，预览不用重建）。工程中途换了（`documentGeneration` 不同）就不补。

## 验证

- `scripts/check-project-file.sh` 第 41 组：换源之后记录里没钱 → `recordUpscaleCost` 给用着这个文件的四段都补上、别的素材不动、
  同一个数再记一次改零段、没人用的文件改不到任何段。反向验证：把 `recordUpscaleCost` 里的赋值去掉，三条红。
- `checks/fal-wiring.sh` 第 10 条：`cancel()` 开头 guard `.running`、查到实收叫 `onCostResolved`、AI 和对比窗口两边都接它经
  `recordUpscaleCost` 回写。反向验证：去掉 guard、去掉回调调用、去掉其中一边的回写，各红。
- 真机：等 Beta 0.18.20 再跑一次 AI upscale，几分钟后检查器那行从「—」变成实收（要 ADMIN 权限的 Key）。

## 教训 / 防回归

- **异步补账要追着已经落地的数据写**：一个结果先落进工程、钱后到，就得有「按文件找此刻用着它的段」这一步，不能指望改任务对象上的副本。
- **remove ≠ cancel**：收尾时调的清理函数里藏着 `cancel()`，会把做完之后还在跑的收尾工作（这里是账单查询）一起杀掉；
  `cancel()` 要按状态判断。长期约束写进 [视频 upscale](../architecture/video-upscale.md) 第一节「账」那一行。
