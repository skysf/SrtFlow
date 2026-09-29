#!/usr/bin/env bash
# fal.ai 生成的端到端冒烟：真的 App + 真的 srtflow-mcp + 本机的假 fal（fakefal.py）。
# 用法：
#   swift build --arch arm64                # 先编好
#   scripts/gui-smoke/fal/run.sh [每日上限]   # 组装独立的测试 App、起假 fal、后台启动 App
#   python3 scripts/gui-smoke/fal/generate.py     # 场景一（默认每日上限 10）
#   scripts/gui-smoke/fal/run.sh 0.30 && python3 scripts/gui-smoke/fal/approval.py   # 场景二
#   scripts/gui-smoke/fal/run.sh stop       # 收尾：退 App、杀假 fal、删钥匙串项 / 设置 / 小文件
# 测试 App 的 bundle id 是 com.srtflow.SrtFlow.falsmoke：socket、设置、钥匙串项都和正式版 / 用户的测试版分开。
# Key 不用 `security -T` 预置（别的签名建的项 App 读要弹授权框，2026-09-29 试过、把框弹到了用户屏幕上）：
# 用 SRTFLOW_SMOKE_FAL_KEY 让 App 自己启动时存一份（只在队列地址指到本机假 fal 时才生效）。
set -uo pipefail
cd "$(dirname "$0")/../../.."
REPO="$PWD"
HERE="$REPO/scripts/gui-smoke/fal"
export FALSMOKE_DIR="${FALSMOKE_DIR:-${TMPDIR:-/tmp}/srtflow-fal-smoke}"
D="$FALSMOKE_DIR"
APP="$D/SrtFlowFalSmoke.app"
BUNDLE=com.srtflow.SrtFlow.falsmoke
PORT=18765
KEY="smoke-id-1234-abcd:smoke-secret-0123456789abcdef"
SUPPORT="$HOME/Library/Application Support/$BUNDLE"

stop() {
  osascript -e "tell application id \"$BUNDLE\" to quit" >/dev/null 2>&1 || true
  sleep 1
  pkill -f "SrtFlowFalSmoke.app/Contents/MacOS/SrtFlowFalSmoke" 2>/dev/null || true
  [ -f "$D/server.pid" ] && kill "$(cat "$D/server.pid")" 2>/dev/null || true
  pkill -f "fakefal.py $PORT" 2>/dev/null || true
  security delete-generic-password -a api-key -s "$BUNDLE.fal" >/dev/null 2>&1 || true
  defaults delete "$BUNDLE" >/dev/null 2>&1 || true
  rm -f "$SUPPORT/mcp-providers.json" "$SUPPORT/mcp.sock"; rmdir "$SUPPORT" 2>/dev/null || true
}
if [ "${1:-}" = "stop" ]; then stop; echo stopped; exit 0; fi
LIMIT="${1:-}"
stop
mkdir -p "$D/assets" "$D/work"

# ---- 组装测试 App（调试版，独立 bundle id）
BUILD="$(swift build --arch arm64 --show-bin-path)"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BUILD/SrtFlow" "$APP/Contents/MacOS/SrtFlowFalSmoke"
RES="$BUILD/SrtFlow_SrtFlow.bundle"
if [ -d "$RES/Contents/Resources" ]; then ditto "$RES/Contents/Resources" "$APP/Contents/Resources"; else ditto "$RES" "$APP/Contents/Resources"; fi
cp -R "$RES" "$APP/Contents/Resources/"; cp -R "$RES" "$APP/Contents/MacOS/"
cp packaging/Info.plist "$APP/Contents/Info.plist"
P="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable SrtFlowFalSmoke" "$P"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE" "$P"
/usr/libexec/PlistBuddy -c "Set :CFBundleName SrtFlowFalSmoke" "$P" || true
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName SrtFlowFalSmoke" "$P" || true
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 0.0.0-falsmoke" "$P" || true
cp "$BUILD/srtflow-mcp" "$APP/Contents/Helpers/srtflow-mcp"
cp vendor/ffmpeg "$APP/Contents/Helpers/ffmpeg"
codesign --force --sign - --timestamp=none "$APP/Contents/Helpers/ffmpeg" >/dev/null 2>&1
codesign --force --sign - --timestamp=none "$APP/Contents/Helpers/srtflow-mcp" >/dev/null 2>&1
codesign --force --deep --sign - "$APP" >/dev/null 2>&1

# ---- 假 fal 要回的文件（用仓库的 vendor/ffmpeg 现做：这是测试夹具）
FF="$REPO/vendor/ffmpeg"; A="$D/assets"
[ -f "$A/pic.png" ] || "$FF" -y -loglevel error -f lavfi -i testsrc2=size=1536x864 -frames:v 1 "$A/pic.png"
[ -f "$A/clip.mp4" ] || "$FF" -y -loglevel error -f lavfi -i testsrc2=size=1280x720:rate=30 -f lavfi -i "sine=frequency=330:duration=5" -t 5 -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$A/clip.mp4"
[ -f "$A/say.mp3" ] || "$FF" -y -loglevel error -f lavfi -i "sine=frequency=180:duration=4" -c:a libmp3lame -q:a 4 "$A/say.mp3"
[ -f "$A/song.mp3" ] || "$FF" -y -loglevel error -f lavfi -i "sine=frequency=262:duration=10" -c:a libmp3lame -q:a 4 "$A/song.mp3"
[ -f "$A/door.wav" ] || "$FF" -y -loglevel error -f lavfi -i "sine=frequency=880:duration=2" "$A/door.wav"
cp "$A/pic.png" "$D/work/pic.png"; cp "$A/say.mp3" "$D/work/voice-sample.mp3"

# ---- 起假 fal、种设置、后台启动 App
python3 "$HERE/fakefal.py" "$PORT" "$A" "$KEY" >"$D/server.log" 2>&1 &
echo $! > "$D/server.pid"
if [ -n "$LIMIT" ]; then
  defaults write "$BUNDLE" "SrtFlow.fal.settings.v1" -data "$(printf '{"dailyLimit":%s,"overrides":{}}' "$LIMIT" | xxd -p | tr -d '\n')"
fi
defaults write "$BUNDLE" appLanguage en
open -g -n --env "SRTFLOW_FAL_QUEUE_BASE=http://127.0.0.1:$PORT" --env "SRTFLOW_FFMPEG=$FF" --env "SRTFLOW_SMOKE_MUTE=1" \
  --env "SRTFLOW_SMOKE_FAL_KEY=$KEY" "$APP"
for _ in $(seq 1 60); do [ -S "$SUPPORT/mcp.sock" ] && break; sleep 0.5; done
[ -S "$SUPPORT/mcp.sock" ] && echo "测试 App 在听：${SUPPORT}/mcp.sock（FALSMOKE_DIR=${D}）" || { echo "App 没起来" >&2; exit 1; }
