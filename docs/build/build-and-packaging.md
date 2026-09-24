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

## CI（.github/workflows/checks.yml）

CI 跑的就是 `scripts/check-all.sh`，只是拆成几组、分到几台 runner 上并行跑。
**仓库是公开的，GitHub 托管的 macOS runner 免费**，免费档同时最多 5 台 macOS，所以拆成 5 组。

- **分组写在 check-all.sh 里**：`shard N` 一行，下面的 `run_check` 都归第 N 组。CI 用 matrix
  跑 `scripts/check-all.sh --shard N --of 5`；本地不带参数，照旧一口气全跑。
- **组数两边必须一致**：check-all.sh 读自己文件里的 `shard N` 声明，和 CI 传进来的 `--of`
  （`strategy.job-total`）对不上就直接红；分到的那组一项都没跑也红。不然多声明的那一组在
  CI 上永远不跑，而且是绿的。
- **汇总 job 叫 `check-all`**（ubuntu，几秒）：ruleset `protect-main` 要求的必需检查就是
  这个名字，所以改 CI 不用动 ruleset。它 `needs` 全部分组，而且必须带
  `if: ${{ !cancelled() }}`：不写的话，分组一红它就被跳过，**被跳过的必需检查会被 GitHub
  当成通过**，红的 PR 也能合进去。不用 `always()`，是免得被取消的那一轮再报一个假的失败。
- **只有第 1 组编完整 App**（单独一步，冷编 50–80 秒，编译错误在自己的步骤里看得清；
  check-all.sh 第 1 组也明写了一项「build（完整 App 编得过）」）。子脚本只
  `swift build --target SrtFlowCore`：它们要的只是核心库的模块和目标文件，别的组不必每台都
  花一分多钟编整个 App。
- **自检二进制用 `-wmo` 编**（整模块一次编完）。同一份 40 个文件，默认的逐文件编译要
  12.5 秒，`-wmo` 只要 4.9 秒（本机 arm64、模块缓存已热）：逐文件模式下每个文件都要把
  其余文件重新解析一遍。CI 上拆分前，各项检查里编译占了约 300 秒、运行约 160 秒。
  `-enable-batch-mode` 实测编不过，别换成它。
- **同一个 PR 又推了新提交，旧的一轮直接取消**（`concurrency`），不白占 runner；main 上的
  每一次都跑完。
- `.build` 缓存帮得有限：恢复之后第 1 组的完整编译仍要 50–80 秒（多半是因为 checkout 之后
  源文件的修改时间都是新的，SwiftPM 按修改时间判断要不要重编）。留着是因为恢复只要几秒。

**怎么分组**：按 CI 日志里每项的耗时（`✓ 名字（N s）`）装箱，最慢的先放，每次放进当前最空的
那一组。第 1 组还要背 50–80 秒的完整编译，所以只放纯值检查和扫描守卫。加了新检查就放进最空的
那组，改完看一眼 CI 上各组的时长。

**实测**：

- 拆分前一轮约 10 分钟（check-all 508 秒 + 冷编 81 秒 + 其余步骤 17 秒；最慢的几项是
  export-frame-rate 84 秒、audio-fade 54 秒、clip-animation 40 秒）。
- 拆成 5 组、加上 `-wmo` 之后（2026-09-24，PR #65 首跑）**整轮 2 分 18 秒**。5 台几乎同时
  开跑（间隔不到 10 秒），各组 1 分 24 秒到 2 分 4 秒。第 1 组冷编完整 App 用了 52 秒。
  另外 4 组各有一笔固定开销：第一项检查要先编核心库（13–20 秒），编译器的模块缓存也是冷的。
  export-frame-rate 从 84 秒降到 44 秒。
- 第一次分组第 4、5 组偏重（纯检查耗时 81、86 秒，第 2、3 组 57、61 秒），把 media-import、
  text-render 挪去第 2、3 组，按上面的数字估算四组约为 69 / 74 / 68 / 74 秒。
- 挪完之后的第二轮**整轮 2 分 55 秒**，各组 1 分 11 秒到 2 分 42 秒。同样的检查换一台 runner
  能差 1.5–2 倍：player-clock 21 → 42 秒、export-frame-rate 44 → 63 秒，screen-recording-writer
  反而 27 → 18 秒。runner 都是 3 核（`hw.ncpu` = 3）、同一个镜像，差别在宿主机当时的忙闲。
  **所以分组只求大致均衡，别拿一轮的数字精调**。一轮大约 2–3 分钟，拆分前是 10 分钟。
