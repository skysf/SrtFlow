# 2026-09-29 婚礼工程那一轮 AI 剪辑之后的五处工具小毛病

> 来源：用户用 Claude Code 经 MCP 剪婚礼视频后写的报告（`~/Downloads/婚礼素材/SrtFlow/SrtFlow_MCP问题反馈报告_2026-09-29.md`），
> 这里收的是「AI 接口」这一区的五条（BUG-09、BUG-11、BUG-12 之二、ISSUE-21、BUG-05 之一、BUG-03 之一）。黑屏那两条
> 另有案例（[叠化 + 关键帧之后预览全黑](2026-09-29-preview-black-slice-boundaries-straddle-a-tick.md)）。
> 长期约束写进了 [AI 接口（MCP）](../architecture/ai-control-mcp.md) 第四节第 41 条。

## 症状

1. **`set_text` 传转义的 `\n`，画面上显示成两个字符**（BUG-09）。工具说明写着「`\n` starts a new line」，客户端照着把
   反斜杠和 n 两个字符传过来，标题变成「一桌文成好酒席\n见证一段好姻缘」。
2. **`new_project` 一声不吭地取消了正在跑的 `transcribe`**（BUG-11）。`transcribe file=…` 回了 `transcript-1`，紧接着
   `new_project`，`get_job` 就是 `cancelled`，两个调用的返回里都没提。
3. **`look` 把黑帧描述成「outdoor, night sky」**（BUG-12 之二）。预览合成被判无效那次，取帧器只给黑底，Vision 照样描述，
   AI 以为素材是黑的。
4. **`delete_items` 一批里有一个 id 不存在，整批不执行，报错只提那一个**（ISSUE-21）。AI 以为前两个删掉了。
5. **几个 AI 会话连着同一个 App 时，看不出谁刚换了工程**（BUG-05 之一）。`open_project` 报「已打开 B」、`get_timeline`
   却是 C —— 另一个窗口的 AI 在中间打开了 C（当时有 5 个 `srtflow-mcp` 连着同一个 App）。
6. **改入点之后关键帧跑到负时间，`edit_clip` 不吭声**（BUG-03 之一）。分割出来的右半段继承整条关键帧轨，再把入点改到
   37.9 秒，`get_timeline` 里关键帧变成 −17.275 秒。

## 根因

1. 文字照单全收：`AITextChange.init` 把 `text` 原样写进 `overlay.text`。屏幕上的字不会真要一个反斜杠加一个 n。
2. `VideoEditProject.invalidateDocumentGeneration()`（切工程时清运行时状态）无差别 `TranscriptionTask.shared.cancel()`。
   那个任务是生成字幕和 AI 的 `transcribe` 共用的串行槽：前者绑工程、后者只转文件（`transcribeOnly`），可 cancel 不分。
3. `AIFrameComposer.frames` 建了合成就取帧，不问合成有没有效；取帧失败时 `video = nil`，叠层照样合成一张黑底图交给 Vision。
4. `AITimelineTools.delete` 逐个 `resolve`，第一个认不出就 `throw`，剩下的没看；错误文字也没说「一个都没删」。
   整批不执行本身是对的（一个工具 = 一步撤销，删一半没法当一步退），错在没说清。
5. `get_timeline` 的结果里没有工程名；`get_status` 有，但 AI 不会每步都问。
6. 关键帧锚在源时间上是架构定的（变速、裁头尾、分割都自动对，见 keyframe-animation.md）；换了素材窗口它们留在原来的
   画面上，就落到段外面。这一条不改模型，先让工具说出来（要不要改成跟时间线走，等用户拍板）。

## 修复

1. `AITextChange.unescapingNewlines`：字面的 `\n` 换成换行；说明改成「a newline (or the two characters \n)」。
2. `TranscriptionTask.boundToProject`：`start(project:)` 记 true、`transcribeOnly` 记 false；新的 `cancelIfBoundToProject()`
   只取消绑工程的那一次，`invalidateDocumentGeneration` 改调它。用户按「停止」的 `cancelAll` 照旧取消全部。
3. `AIFrameComposer.frames` 改成 throws：建完合成先 `isValid`，无效就报「preview composition is invalid … This is a
   SrtFlow bug, not the footage」，`look` 原样交给 AI。
4. `AITimelineEdits.deletion(of:in:)`（纯值）：整批先全认一遍，认不出的一起列出来，末尾说明「Nothing was deleted (the
   batch is all-or-nothing)」；`delete` 工具改调它。
5. `AITimelineSummary.Context.project`：`get_timeline` 顶层带 `project`（工程文件名，没存过是 `unsaved`）。
6. `AIKeyframes.outsideWarning`：`edit_clip` 之后关键帧落在源窗口外面就在结果里加 `warning`，说清「关键帧钉在素材画面上，
   调 set_keyframes 重设」。

## 验证

- `scripts/check-mcp.sh`：`TextPartChecks`（字面 `\n` 变换行、真换行不动）、`TimelineChecks`（一批里两个不存在的 id 都
  被点名、文字里有「Nothing was deleted」、全认识的一批正常解析；`get_timeline` 没存过写 `unsaved`、开着的写文件名）、
  `TrackKeyframeChecks`（关键帧都在段内没有警告，入点改到 37.9 之后有、且提到 set_keyframes）。
- `checks/project-file-wiring.sh`：切工程只许调 `cancelIfBoundToProject()`，生成字幕记 `boundToProject = true`、只转文件记 false。
- 反向验证：四处修复一起撤掉（字面 `\n` 不换、只报第一个认不出的 id、结果不带 `project`、关键帧警告恒为 nil），
  `check-mcp` 正好红那六条（两个 id 只点名一个、没有「Nothing was deleted」、`project` 是 nil ×2、警告 nil、`\n` 原样）；
  `invalidateDocumentGeneration` 换回 `cancel()`，接线守卫红；恢复后 1182 项全绿。
- `look` 对无效合成报错这一条自动化够不着（自检里没有真素材、合成也修好了不会无效），写进 ai-control-mcp.md 第八节的
  人工回归清单。

## 教训 / 防回归

- **给 AI 的说明里写的转义，客户端会照字面传。** 说明里出现 `\n` 之类的记号，收的那头就得两种都认。
- **共用一个串行槽的两种任务，取消要分清谁的。** `cancel()` 只有一个，谁都能调；切工程该取消的是绑工程的那一种。
- **「看」到黑的先问是不是自己没画出来。** 合成无效、取帧失败都不是素材的事，报错比描述一张黑图有用。
- **整批工具拒绝执行时要说「一个都没做」并列全。** AI 只读文字，不会去查哪些做了。
- **几个会话连一个 App 是常态**（用户会开第二个窗口的 AI 去复现 bug）：每个读工程的结果都该带上工程是谁。
