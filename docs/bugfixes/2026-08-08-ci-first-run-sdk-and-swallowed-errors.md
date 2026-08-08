# CI 首跑 6 项自检齐红，日志里却一行编译错误都没有

日期：2026-08-08（PR #21 的首次 Actions 运行）

## 症状

新挂的 GitHub Actions 首跑：9 项自检 3 绿 6 红。红的全是「挑源文件用
`xcrun swiftc` 独立编译」的脚本（project-file、preview-composition、
freeze-frame、player-clock、export-frame-rate、still-clip-encode）；
绿的是 SrtFlowCoreChecks、两条纯 shell 检查。**整份日志里找不到任何
编译错误** —— 每个红项只有「==> swift build」一行，然后就直接失败。

## 根因

两个，叠在一起让问题完全不可诊断：

1. **`swift build ${ARCH_FLAG} >/dev/null` 吞掉了全部诊断。**
   SwiftPM 的编译错误走 **stdout**（不是 stderr），六个脚本为了安静把
   stdout 重定向进 /dev/null，失败时就成了无字天书。本地从来没炸过，
   所以这个坑埋了很久才在 CI 上现形。
2. **runner 的 SDK 不够。** 字幕生成用了 macOS 26 的 SpeechAnalyzer API
   （`@available(macOS 26.0, *)`），编译需要 macOS 26 SDK；`macos-15`
   镜像默认 Xcode 16（SDK 15），完整 app target 编不过。
   SrtFlowCoreChecks 能绿是因为核心库不碰这些 API —— **部分绿比全红更
   有迷惑性**：一眼看去像「脚本坏了」而不是「工具链不够」。

## 修复

- workflow 换 `runs-on: macos-26`（默认 Xcode 26.6，查过
  actions/runner-images 的镜像清单），并加两步：Toolchain versions
  （sw_vers/xcodebuild/swift 版本，下次排查有据可查）和独立的
  Build 步骤（冷编译错误在自己的步骤里完整可见，顺带给 check-all
  暖构建缓存）。
- 六个自检脚本统一改成「静默成功、失败倾倒完整输出」：
  `BUILD_OUT="$(swift build ${ARCH_FLAG} 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }`
  （赋值 + `||` 的写法，绕开 pipefail 在赋值处杀脚本的陷阱，见
  [2026-08-06-build-version-and-shell-traps](2026-08-06-build-version-and-shell-traps.md)）。
- 新扫描守卫 `checks/no-swallowed-build-output.sh`：任何 `.sh` 里出现
  `swift build/run … >/dev/null` 就红（文件系统枚举，未跟踪脚本也盖住），
  已接入 `check-all.sh`。

## 验证

- 反向验证：造一个含 `swift build >/dev/null` 的临时脚本 → 扫描守卫红；
  删掉 → 绿。
- 改完的六个脚本本地全部重跑通过；`scripts/check-all.sh` 10 项全绿。
- CI 复跑绿（含 macos-26 上的完整编译）。

## 教训

- **SwiftPM 的诊断走 stdout**：`swift build >/dev/null` 等于把失败原因
  扔掉。要安静就先捕获、失败再倾倒，别裸吞。
- **部分绿会误导定位**：核心库过了、app target 没过，第一反应会怀疑脚本
  而不是 SDK。CI 里让「编译」自成一步，失败归属立刻清晰。
- **CI 环境的 SDK/工具链是隐式依赖**，要在 workflow 里显式声明并打印
  版本 —— 本地能编 ≠ runner 能编。
- 「本地全绿」验证不了 workflow 本身：**首个 PR 就是 CI 的验收测试**，
  留出一轮修它的预算。
