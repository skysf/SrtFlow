# 2026-10-03 check-mcp 的撤销分组扫描被 bash 3.2 花括号展开拆开，在 CI 上从来没生效

## 症状

没有用户看得见的症状 —— 是一条守卫**假绿**：`scripts/check-mcp.sh` 里「`cut_speech` / `cut_to_beat` / `add_voiceover` 的提交各包在
`AIUndoGrouping.step` 里」那一条（不包的话 AI 的改动会和别的步并成一步撤销，[AI 的改动撤一步全空了](2026-09-27-ai-edits-share-one-undo-group.md)），
在 CI 上一次都没真正检查过：把路由里那一层包装拆掉，CI 照样绿。

做 `record_screen`（PR #155）时在本机用 CI 同款的 `/bin/bash` 单独跑 `check-mcp.sh` 前面那段扫描，stderr 里冒出三行
`[: too many arguments`，才追到这里。

## 根因

那一条写成：

```bash
for tool in AISpeechCutTool AIBeatCutTool AIVoiceoverTool; do
  if [ "$(grep -cE "return try AIUndoGrouping\\.step\\(undo\\) \\{ try ${tool}\\.apply\\(plan, project\\) \\}" "${ROUTER}" || true)" -ne 1 ]; then
```

**macOS 自带的 `/bin/bash` 3.2 会对 `"$( … )"` 里那段双引号字符串做花括号展开**，`set -x` 看得一清二楚：

```
++ grep -cE 'return try AIUndoGrouping\.step\(undo\) \ try AISpeechCutTool\.apply\(plan' Sources/SrtFlow/AIToolRouter.swift
++ grep -cE 'return try AIUndoGrouping\.step\(undo\) \ project\) \' Sources/SrtFlow/AIToolRouter.swift
grep: trailing backslash (\)
+ '[' 0 '' -ne 1 ']'
[: too many arguments
```

`{ try X.apply(plan, project) }` 按逗号拆成两段、grep 跑了两遍，`[` 收到 `0` 和空串两个词，报错返回 2；`if` 只认 0，于是走 else ——
**不管路由里包没包，这一条都「通过」**。本机 PATH 上的 bash 5.3 不做这个展开，同一行算出 `1`、拆掉包装就红，所以在本机跑永远看不出来。

为什么 [陷阱 5](2026-08-06-build-version-and-shell-traps.md) 的防线（`run_check` 把 `.sh` 一律交给 `/bin/bash`）没挡住：陷阱 5 那次 3.2 是报错退出
（`set -u` 的 unbound variable），一眼就红；这次 `[` 的错误在 `if` 的条件里，`set -e` 不管，只在 stderr 打一行，脚本照常往下走、最后照常打勾。

## 修复

- `scripts/check-mcp.sh`：先赋给变量（赋值的右边不做花括号展开）再比较：
  `wrapped="$(grep -cE "…" "${ROUTER}" || true)"`、`if [ "${wrapped}" -ne 1 ]`。
- 新的扫描守卫 `checks/shell-brace-in-nested-quotes.sh`（`scripts/check-all.sh` 第 1 组）：全部 `.sh` 里，不是注释、也不是「变量=」开头的行，
  `"$(` 后面出现带 `{…,…}` 的双引号字符串就红。全仓只有这一处（2026-10-03 grep 过）。
- [构建版本与 shell 陷阱](2026-08-06-build-version-and-shell-traps.md) 补了「陷阱 6」。

## 验证

用 `/bin/bash`（3.2.57）跑 `check-mcp.sh` 编译之前的那段扫描：

| 情形 | 修之前 | 修之后 |
| --- | --- | --- |
| 路由原样 | 通过，stderr 三行 `too many arguments` | 通过，没有报错 |
| 拆掉 `AISpeechCutTool` 那一层 `AIUndoGrouping.step` | **通过**（假绿） | 红：「AISpeechCutTool 的提交没包在 AIUndoGrouping.step 里」 |
| 拆掉 `AIBeatCutTool` / `AIVoiceoverTool` 的 | 通过（假绿） | 各自红 |

新守卫的反向验证：把 `check-mcp.sh` 换回 main 上那一版 → 红，点名 `scripts/check-mcp.sh:114`；换回修好的 → 绿（扫了 92 个 `.sh`）。

## 教训 / 防回归

- **`[ "$(…)" … ]` 写错了不一定红**：`[` 自己报错时返回 2，`if` 只把它当「不成立」。守卫里的比较先把命令替换赋给变量，
  `[` 只比变量 —— 3.2 和 5 的解析差别、命令跑两遍这类事都挡在外面。
- 写完 shell 守卫，**反向验证要用 `/bin/bash` 跑**（CI 用的就是它）；看一眼 stderr，有 `too many arguments`、`integer expression expected`
  这类就是 `[` 没在比你以为的东西。
- 长期约束在陷阱文档第 6 条，`checks/shell-brace-in-nested-quotes.sh` 钉着。
