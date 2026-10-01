# 2026-10-01 把插画面的代码搬出 builder 之后，一条转场守卫还在旧文件里找，CI 第 1 组红

## 症状

优化媒体 V2（PR #132）首跑 CI：第 1 组红在 `checks/transition-handles-wiring.sh` ——
「预览合成没用 clip.renderSourceStart / clip.renderSourceDuration / await CompositionHold.insert(：定格那一截会插成素材之外的画面或空段」。
本机推之前跑过十几条扫描守卫，全绿；其余四组 CI 也绿。

## 根因

为了给「按块换源」腾地方，把 builder 里插画面的 `insert(source:clip:into:cursor:at:)`（含首尾定格那几行）整段搬进了新文件
`Sources/SrtFlow/CompositionClipInsert.swift`。那条守卫按文件名找接线：它钉的是 `VideoEditCompositionBuilder.swift` 里必须出现
这三句，代码搬走之后它自然红。

真正的问题不是这条守卫，而是**本地跑守卫凭记忆挑**：我跑了 17 条自己觉得相关的扫描守卫，`transition-handles-wiring` 不在里面。
2026-09-25 PR #71（滤镜块接线守卫钉着旧名字）、2026-09-29 PR #84（调色代码搬进新文件，守卫还指旧文件）两次案例的教训都是
「改接线 / 搬代码之后把 `checks/*.sh` 全 grep / 全跑一遍」—— 写进了案例，没有变成机制，第三次又漏了。

## 修复

- `checks/transition-handles-wiring.sh`：定格那三句改在 `CompositionClipInsert.swift` 里找，另钉一条 builder 必须调
  `CompositionClipInsert.insert(`（搬走的文件没人调也要红）。
- **机制**：新加 `scripts/check-guards.sh`，一条命令跑全部 `checks/*.sh`（几十秒、不编译、不碰 `.build`，能和编自检的脚本并行）；
  AGENTS.md 的验证纪律写明**推之前必跑**。以后不许再「挑着跑」。

## 验证

- 本机 `scripts/check-guards.sh`：28 条全绿；推上去 CI 第 1 组绿。
- 反向：把 `INSERT` 改回指向 builder → 守卫红在同样三句（和 CI 一样）；把 builder 里的 `CompositionClipInsert.insert(` 临时改名 → 新加的那一条红。

## 教训

- **同一个教训撞第三次就别再补清单，改成机制**（AGENTS 全局规则第 5 条的精神；2026-09-30 本地化守卫那次已经这么说过）：
  「记得跑全部守卫」靠不住，做成一条命令、写进纪律。
- 搬代码也算改接线：按文件名找接线的守卫每一条都可能指着旧文件，只有全跑才知道。
