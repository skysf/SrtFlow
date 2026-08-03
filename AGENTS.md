# AGENTS.md — 文档索引与协作规则

给 AI 代理与新贡献者的导航页。**本文件只做目录和规则，不写细节**；细节按分类
放在 `docs/` 下。

## 规则（所有 AI / 贡献者必须遵守）

1. **修复任何 bug 后，必须在 `docs/bugfixes/` 写一份案例**（按
   [TEMPLATE.md](docs/bugfixes/TEMPLATE.md)：症状 → 根因 → 修复 → 验证 → 教训），
   文件名 `YYYY-MM-DD-<slug>.md`，并在下方索引里补一行。
2. 案例中沉淀出的**长期约束**（"这里只能这样做"）单独落到 `docs/architecture/`，
   案例里链接过去，避免只存在于一次性记录中。
3. 新增其他文档归入 `docs/` 对应分类目录，并回本文件补一行索引。

## 构建（docs/build/）

- [build-and-packaging.md](docs/build/build-and-packaging.md) —
  ⚠️ Rosetta 终端必须 `swift build --arch arm64`、常用命令、打包脚本、产物验收清单

## 测试（docs/testing/）

- [gui-smoke-testing.md](docs/testing/gui-smoke-testing.md) —
  真实窗口冒烟测试全流程：改名启动避同名进程、按窗口 ID 截图、事件注入边界、
  `SRTFLOW_SMOKE_VIDEO` / `SRTFLOW_FFMPEG` 环境变量钩子

## 架构与实现决策（docs/architecture/）

- [timeline-pinch-zoom.md](docs/architecture/timeline-pinch-zoom.md) —
  时间线捏合缩放为什么只能用 local NSEvent monitor（含全部失败方案与回归清单）；
  **改时间线手势/滚动代码前必读**

## Bug 修复案例（docs/bugfixes/）

- [2026-08-03-trackpad-pinch-zoom.md](docs/bugfixes/2026-08-03-trackpad-pinch-zoom.md) —
  触控板捏合缩放反复"修好"又失败：事件序列锁定 + Rosetta 旧二进制两个根因

## 根目录既有文档

- [SrtFlow-Requirements.md](SrtFlow-Requirements.md) — 产品需求说明与技术结论总表
- [README.md](README.md) — 项目介绍（面向使用者）
