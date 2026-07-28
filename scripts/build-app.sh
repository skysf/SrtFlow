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
VERSION="${VERSION:-0.1.4}"
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

# 图标：脚本生成 iconset → iconutil 合成 icns（仓库中不放二进制图标文件）
echo "==> 生成图标"
ICONSET="$(mktemp -d)/SrtFlow.iconset"
swift scripts/make-icon.swift "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/SrtFlow.icns"
rm -rf "$(dirname "$ICONSET")"

# ad-hoc 签名（Apple Silicon 上必须有签名才能运行；分发给别人建议换 Developer ID）
echo "==> codesign (ad-hoc)"
codesign --force --sign - "$APP"

# DMG：App + /Applications 快捷方式
echo "==> 生成 DMG"
DMG_ROOT="$DIST/dmg-root"
rm -rf "$DMG_ROOT"
mkdir -p "$DMG_ROOT"
cp -R "$APP" "$DMG_ROOT/"
ln -s /Applications "$DMG_ROOT/Applications"
DMG="$DIST/$APP_NAME-$VERSION-arm64.dmg"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$DMG_ROOT"

echo
echo "完成："
du -sh "$APP" "$DMG"
