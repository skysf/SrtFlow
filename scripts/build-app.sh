#!/usr/bin/env bash
# SrtFlow 打包脚本（仅依赖 Command Line Tools，无需完整 Xcode）
#
# 用法：
#   scripts/build-app.sh            # 构建 release、组装 SrtFlow.app、生成 DMG
#   VERSION=1.0.0 scripts/build-app.sh
#
# 产物：
#   dist/SrtFlow.app
#   dist/SrtFlow-<VERSION>-arm64.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME=SrtFlow
VERSION="${VERSION:-0.3.0}"
DIST=dist

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
[ -f vendor/README.md ] && cp vendor/README.md "$APP/Contents/Resources/ffmpeg-LICENSE.md"

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

运行要求：Apple 芯片（M 系列）Mac，macOS 14 Sonoma 或更新版本。
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

Requirements: an Apple silicon (M-series) Mac running macOS 14 Sonoma or later.
No need to install ffmpeg or anything else — everything is inside the app.
READMEEOF
DMG="$DIST/$APP_NAME-$VERSION-arm64.dmg"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$DMG_ROOT"

echo
echo "完成："
du -sh "$APP" "$DMG"
