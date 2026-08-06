# 构建与打包

## 架构坑（重要）

这台机器的终端会话可能跑在 **Rosetta** 下，此时裸 `swift build` 默认编译
**x86_64**，产物落在 `.build/x86_64-apple-macosx/`，而
`.build/arm64-apple-macosx/debug/` 里躺着的还是上一次的旧二进制。

后果（真实发生过）：编译输出的警告行号都对得上新代码，但拷去测试的 arm64
二进制是旧的——"修复"在真机上毫无变化，浪费一整轮验证。

**规则：**

1. 一律显式 `swift build --arch arm64`（Release 同理：`-c release --arch arm64`）。
2. 测试/交付前用本次新增的字符串验明产物：
   `strings <二进制> | grep <新增字符串>`，配合 `lipo -archs` 确认 arm64。
   **挑长度 ≥16 字节的标记串**：Swift 的小字符串优化会把 ≤15 字节的字面量内联进
   代码、不落数据段，`strings` 在 Release 里根本查不到（`timeline-zoom` 这种 13
   字节的就查不到，`SRTFLOW_SMOKE_VIDEO` 能查到）——否则会误判成"新代码没进包"。

## 常用命令

```bash
swift build --arch arm64                      # 调试构建
swift run --arch arm64 SrtFlowCoreChecks      # 核心自检（184 项断言，CLT 无 XCTest）
./scripts/build-app.sh                        # Release + 组装 .app + 签名 + DMG
```

## 打包流程（scripts/build-app.sh）

Release 构建 → 手写 Info.plist 组装 `dist/SrtFlow.app` → 拷入 SwiftPM 资源包与
vendor/ffmpeg（`Contents/Helpers/`）→ 生成图标 → **先签嵌套二进制再签外层**
（顺序反了外层签名立即失效）→ `hdiutil` 生成 DMG。

产物：`dist/SrtFlow.app`（约 52 MB）、`dist/SrtFlow-<版本>-arm64.dmg`。

版本号：**正式发版必须显式传** `VERSION=x.y.z ./scripts/build-app.sh`。不传时
脚本兜底取最近的 git tag，并在 HEAD 领先该 tag 时警告「这是开发版产物」——
以前这里是写死的默认值，发到 0.4.1 了还停在 0.3.0，打出过贴错版本号的包，
见 [bugfixes/2026-08-06-build-version-and-shell-traps.md](../bugfixes/2026-08-06-build-version-and-shell-traps.md)。

## 产物验收清单

- `lipo -archs dist/SrtFlow.app/Contents/MacOS/SrtFlow` → `arm64`
- `strings ... | grep <新增字符串>` → 命中
- 脚本自带 `codesign --verify --deep --strict` → "签名校验通过"
- `swift run --arch arm64 SrtFlowCoreChecks` → "All 184 checks passed."
  （断言数会随功能增长，以当次输出为准）
- 涉及 UI 改动时按 `docs/testing/gui-smoke-testing.md` 做真实窗口验证
