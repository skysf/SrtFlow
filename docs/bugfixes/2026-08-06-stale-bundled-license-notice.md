# 2026-08-06 打出来的包里，授权声明还写着 MIT

## 症状

仓库授权已经从 MIT 换成 AGPL-3.0（`LICENSE`、README、需求书、脚本注释全改完，
GitHub 也识别成 AGPL-3.0）。但打 0.5.0 的包、按 `docs/build/` 的验收清单逐条
检查时发现：

```console
$ grep -c "AGPL-3.0" dist/SrtFlow.app/Contents/Resources/ffmpeg-LICENSE.md
0
$ grep "MIT" dist/SrtFlow.app/Contents/Resources/ffmpeg-LICENSE.md
SrtFlow 本体以 MIT 授权，通过**独立进程**调用 ffmpeg，不与其链接，因此两者
```

**分发给用户的 App 里，那份授权声明仍然写着 MIT** —— 和同一个包里的 LICENSE
自相矛盾。这是要发出去给别人的东西，不是内部文档。

## 根因

`Contents/Resources/ffmpeg-LICENSE.md` 是 `build-app.sh` 从 `vendor/README.md`
拷进去的：

```bash
[ -f vendor/README.md ] && cp vendor/README.md "$APP/Contents/Resources/ffmpeg-LICENSE.md"
```

而 `vendor/README.md` 由 `scripts/vendor-ffmpeg.sh` 生成 —— **只在重新获取
ffmpeg 时生成**，而且 `vendor/` 不纳入版本控制。于是形成了一条谁都不会注意的
陈旧链路：

1. 2026-07-30：跑 `vendor-ffmpeg.sh` 下载 ffmpeg，顺手写下 `vendor/README.md`，
   里面那句是当时正确的「SrtFlow 本体以 MIT 授权」。
2. 2026-08-06：换 AGPL-3.0，改了 `vendor-ffmpeg.sh` 里生成这段文案的 heredoc。
   **但没有人会因为改授权就去重新下载一次 ffmpeg**，磁盘上那份 7-30 写的
   README 原封不动。
3. 打包时照拷不误 —— 脚本源码是对的，产物是错的。

关键在于：**改了「生成器」不等于改了「产物」**，而这里的产物既不在版本控制里
（`git grep MIT` 查不到）、又只在一个跟授权毫不相干的动作（下载 ffmpeg）里才
被刷新。两个条件凑一起，静默腐烂就是必然。

## 修复

把生成许可说明的那段抽成 `write_readme()` 函数，并给 `vendor-ffmpeg.sh` 加一个
`--readme-only` 模式：只重写文案，不碰二进制、不下载、不校验。

```bash
if [ "${1:-}" = "--readme-only" ]; then
    mkdir -p "$VENDOR_DIR"
    write_readme
    echo "已刷新 $VENDOR_DIR/README.md"
    exit 0
fi
```

`build-app.sh` 改成**每次打包都先重新生成再拷**，而不是拷磁盘上碰巧存着的那份：

```bash
scripts/vendor-ffmpeg.sh --readme-only
cp vendor/README.md "$APP/Contents/Resources/ffmpeg-LICENSE.md"
```

顺带去掉了原来的 `[ -f vendor/README.md ] &&` 前置判断：这是给用户看的授权
声明，生成不出来就该让打包**失败**，而不是安静地少放一个文件。

## 验证

- `./scripts/vendor-ffmpeg.sh --readme-only` 前后对 `vendor/ffmpeg` 做 md5
  比对，二进制未被改动；不联网、不重新校验。
- 重新打 0.5.0：包内 `ffmpeg-LICENSE.md` 命中 AGPL-3.0，`grep -c MIT` 归零。
- 把 DMG 里的 `.app` 装出来改名启动（`docs/testing/gui-smoke-testing.md` 流程），
  **不设** `SRTFLOW_FFMPEG` 也显示「Engine ready · ffmpeg 8.1」，说明包内
  ffmpeg 正常；字幕面板功能正常。
- 完整验收清单：arm64 / `CFBundleShortVersionString` = 0.5.0 / 随包 ffmpeg
  arm64 / `codesign --verify --deep --strict` 通过 / DMG 内含 .app +
  Applications 软链 + 首次打开说明。

## 教训 / 防回归

1. **改生成器不等于改产物。** 凡是「脚本生成、又不入版本控制」的文件，改了模板
   一定要问一句：磁盘上那份什么时候才会被重新生成？如果答案是「某个不相干的
   动作发生时」，那它一定会腐烂。
2. **对外分发物里的声明，要在打包时现生成，不要拷缓存。** 打包脚本是最后一道
   关口，它拷什么用户就看到什么。
3. **`git grep` 查不到的东西不等于不存在。** 换授权那次我扫的是版本控制里的
   文件，`vendor/` 被 .gitignore 排除，所以四处 MIT 全改完了，第五处却在
   .gitignore 后面躲着 —— 涉及全仓文案替换时，要**额外单独查一遍 gitignore
   覆盖的产物目录**。
4. **验收清单要包含「产物里的授权声明」这一条。** 这次是逐条走
   `docs/build/build-and-packaging.md` 才撞出来的；只跑编译和自检查不到。
