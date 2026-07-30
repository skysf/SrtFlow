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
VERSION="${VERSION:-0.2.0}"
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
# 整个 .app 会被打上下载隔离标记，后果有两个：App 可能打不开；即使打开了，
# 包内的 ffmpeg 也会被系统直接 SIGKILL，表现为一点「开始压缩」就失败、
# 且没有任何错误信息。解隔离一次即可，这里把办法直接放进 DMG。
cat > "$DMG_ROOT/首次打开必读 - Read Me First.txt" <<'READMEEOF'
SrtFlow — 首次打开必读 / Read Me First
======================================

【中文】

1. 把 SrtFlow.app 拖到左边的「应用程序」文件夹。

2. 这个 App 没有做 Apple 公证（自用小工具，公证要每年 99 美元），
   所以 macOS 会拦一下。打开「终端」，粘贴下面这一行，回车：

       xattr -dr com.apple.quarantine /Applications/SrtFlow.app

3. 然后正常双击打开就行，压缩视频和烧制字幕都能用。

第 2 步只需要做一次。如果跳过它，可能出现两种情况：App 打不开；
或者能打开但一点「开始压缩」「烧制字幕」就失败 —— 那是 macOS 拦掉了
App 里自带的 ffmpeg。软件里也会把这行命令提示给你。

运行要求：Apple 芯片（M 系列）Mac，macOS 14 Sonoma 或更新版本。
不需要额外安装 ffmpeg 或任何其他依赖，全部功能都在包内。


【English】

1. Drag SrtFlow.app into the Applications folder on the left.

2. This app is not notarised by Apple (it is a personal tool, and notarisation
   costs $99/year), so macOS blocks it. Open Terminal, paste this line and
   press Return:

       xattr -dr com.apple.quarantine /Applications/SrtFlow.app

3. Then just double-click the app. Compression and subtitle burn-in will work.

Step 2 is needed only once. Skip it and one of two things happens: the app
refuses to open, or it opens but compression and burn-in fail instantly —
because macOS blocks the ffmpeg bundled inside the app. The app shows you the
same command when it detects this.

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
