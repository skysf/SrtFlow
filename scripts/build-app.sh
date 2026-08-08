#!/usr/bin/env bash
# SrtFlow 打包脚本（仅依赖 Command Line Tools，无需完整 Xcode）
#
# 用法：
#   VERSION=1.0.0 scripts/build-app.sh   # 正式发版：显式指定版本号
#   scripts/build-app.sh                 # 开发版：版本号取最近的 git tag
#
# 产物：
#   dist/SrtFlow.app
#   dist/SrtFlow-<VERSION>-arm64.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME=SrtFlow
DIST=dist

# 版本号不写死默认值：以前是 VERSION="${VERSION:-0.3.0}"，发到 0.4.1 了那行还留在
# 0.3.0，不传 VERSION 就会打出贴着旧版本号的包（dist/ 里真出现过这种产物）。
# 改成兜底取最近的 tag —— 它跟着发布自动走，不会腐烂；HEAD 领先 tag 时明确警告。
#
# 注意下面凡是紧跟中文的变量都写成 ${VAR} 而不是裸 $VAR：bash 展开裸变量名时会把
# 多字节字符的首字节也算进名字里（"v$VERSION，" 去找的是 VERSION\xef），配上
# set -u 就是 unbound variable 当场挂掉。与 bash 版本、locale 都无关，5.3 照样中。
# 本仓库的 .sh 全是中文提示，加变量时先想一下这条。详见
# docs/bugfixes/2026-08-06-build-version-and-shell-traps.md
if [ -z "${VERSION:-}" ]; then
  # pipefail 下 git 失败会让整条赋值以 128 退出、走不到下面的报错，所以兜 || true
  VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
  if [ -z "${VERSION}" ]; then
    echo "✗ 未传 VERSION，也取不到 git tag（不在 git 仓库？）。" >&2
    echo "  请显式指定：VERSION=x.y.z $0" >&2
    exit 1
  fi
  AHEAD="$(git rev-list --count "v${VERSION}..HEAD" 2>/dev/null || echo 0)"
  if [ "${AHEAD}" -gt 0 ]; then
    echo "⚠️  未传 VERSION，回退到最近的 tag v${VERSION}，但 HEAD 已领先 ${AHEAD} 个提交。"
    echo "    这是开发版产物；正式发版请显式指定：VERSION=x.y.z $0"
  fi
fi

echo "==> swift build -c release (arm64, -O)"
swift build -c release --arch arm64
BUILD_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

APP="$DIST/$APP_NAME.app"
echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 二进制：strip 掉符号，保持体积最小
cp "$BUILD_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
strip -xS "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true

# SwiftPM 资源包（en / zh-Hans 本地化）
RES_BUNDLE="$BUILD_DIR/SrtFlow_SrtFlow.bundle"
if [ -d "$RES_BUNDLE/Contents/Resources" ]; then
    ditto "$RES_BUNDLE/Contents/Resources" "$APP/Contents/Resources"
elif [ -d "$RES_BUNDLE" ]; then
    ditto "$RES_BUNDLE" "$APP/Contents/Resources"
fi
# 资源包里可能带一个它自己的 Info.plist，避免与 App 的冲突
rm -f "$APP/Contents/Resources/Info.plist"

cp packaging/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"

# 随包的 ffmpeg：视频压缩与烧制字幕都靠它。放 Contents/Helpers（Apple 约定的
# 附属可执行文件位置），App 以独立进程调用。
echo "==> 内置 ffmpeg"
if [ ! -x vendor/ffmpeg ]; then
    echo "   vendor/ffmpeg 不存在，先获取"
    scripts/vendor-ffmpeg.sh
fi
mkdir -p "$APP/Contents/Helpers"
cp vendor/ffmpeg "$APP/Contents/Helpers/ffmpeg"
chmod +x "$APP/Contents/Helpers/ffmpeg"
# GPL 合规：许可说明随包，方便使用者查到 ffmpeg 的授权与源码途径。
# 每次打包都重新生成再拷：vendor/ 不入库，这份文案原本只在重新获取 ffmpeg 时
# 写一次，仓库换了授权它不会跟着变 —— 0.5.0 打包实测撞过（LICENSE 已经是
# AGPL-3.0，包里这份仍写着 MIT）。这是给用户看的授权声明，不能拷陈的。
scripts/vendor-ffmpeg.sh --readme-only
cp vendor/README.md "$APP/Contents/Resources/ffmpeg-LICENSE.md"

# 图标：脚本生成 iconset → iconutil 合成 icns（仓库中不放二进制图标文件）
echo "==> 生成图标"
ICONSET="$(mktemp -d)/SrtFlow.iconset"
swift scripts/make-icon.swift "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/SrtFlow.icns"
rm -rf "$(dirname "$ICONSET")"

# ad-hoc 签名（Apple Silicon 上必须有签名才能运行；分发给别人建议换 Developer ID）
# 嵌套的可执行文件要先签，再签外层 bundle，否则外层签名会立即失效。
echo "==> codesign (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP/Contents/Helpers/ffmpeg"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP" && echo "   签名校验通过"

# DMG：App + /Applications 快捷方式 + 首次打开说明
echo "==> 生成 DMG"
DMG_ROOT="$DIST/dmg-root"
rm -rf "$DMG_ROOT"
mkdir -p "$DMG_ROOT"
cp -R "$APP" "$DMG_ROOT/"
ln -s /Applications "$DMG_ROOT/Applications"

# 这个 App 只做 ad-hoc 签名、没有 Apple 公证。DMG 一经网络或 AirDrop 传输，
# 整个 .app 会被打上下载隔离标记，App 第一次打开会被 macOS 拦下。
# 走「系统设置 → 隐私与安全性 → 仍要打开」放行即可，不用碰终端：放行之后 App
# 启动时会自己清掉包上的隔离标记（Quarantine.repairOwnBundleIfNeeded），
# 包内的 ffmpeg 就不会再被系统 SIGKILL。终端那行留作兜底。
cat > "$DMG_ROOT/首次打开必读 - Read Me First.txt" <<'READMEEOF'
SrtFlow — 首次打开必读 / Read Me First
======================================

【中文】

1. 把 SrtFlow.app 拖到左边的「应用程序」文件夹。
   （一定要拖进去再打开，别直接在这个磁盘映像里双击运行。）

2. 双击 SrtFlow。这个 App 没有做 Apple 公证（自用小工具，公证要每年 99 美元），
   所以第一次打开会被 macOS 拦下，提示「无法打开」。点「完成」/「好」。

3. 打开「系统设置」→「隐私与安全性」，往下翻到「安全性」那一段，
   会看到一行关于 SrtFlow 被阻止的提示，点右边的「仍要打开」，
   再按提示输入你的密码 / 用触控 ID 确认。

4. 回到「应用程序」里再双击 SrtFlow，这次就正常打开了。
   压缩视频、烧制字幕全部功能都能用。

以上只需要做一次。

万一第 4 步打开后，一点「开始压缩」或「烧制字幕」就失败，说明系统仍然
拦着包内的 ffmpeg。这时打开「终端」，粘贴下面这一行、回车，然后重开 SrtFlow：

    xattr -dr com.apple.quarantine /Applications/SrtFlow.app

软件里也会把这一行显示给你，旁边还有直接打开系统设置的按钮。

运行要求：Apple 芯片（M 系列）Mac，macOS 15 Sequoia 或更新版本。
不需要额外安装 ffmpeg 或任何其他依赖，全部功能都在包内。


【English】

1. Drag SrtFlow.app into the Applications folder on the left.
   Open it from there — do not run it straight out of this disk image.

2. Double-click SrtFlow. This app is not notarised by Apple (it is a personal
   tool, and notarisation costs $99/year), so macOS blocks the first launch and
   says it cannot be opened. Dismiss that dialog.

3. Open System Settings → Privacy & Security, scroll down to the Security
   section. There is a line saying SrtFlow was blocked — click "Open Anyway"
   next to it and confirm with your password or Touch ID.

4. Double-click SrtFlow again. It opens normally now, with compression and
   subtitle burn-in fully working.

That is a one-time step.

If it does open but compression or burn-in fails the instant you start it, macOS
is still blocking the ffmpeg inside the bundle. Open Terminal, paste this line,
press Return, and reopen SrtFlow:

    xattr -dr com.apple.quarantine /Applications/SrtFlow.app

The app shows you the same line, next to a button that opens System Settings.

Requirements: an Apple silicon (M-series) Mac running macOS 15 Sequoia or later.
No need to install ffmpeg or anything else — everything is inside the app.
READMEEOF
DMG="$DIST/$APP_NAME-$VERSION-arm64.dmg"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$DMG_ROOT"

echo
echo "完成："
du -sh "$APP" "$DMG"
