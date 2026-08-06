#!/usr/bin/env bash
# 获取随 App 一起分发的原生 arm64 ffmpeg（含 libass），放到 vendor/ffmpeg。
#
# 为什么要自带：
#   1. 烧制字幕需要 libass（subtitles 滤镜）。Homebrew 的默认构建并不保证带，
#      系统上常见的 /usr/local/bin/ffmpeg 往往是 x86_64 版，在 M 系列上走
#      Rosetta 转译，libx264 编码要慢一倍以上。
#   2. 自带一份可以保证「打开就能用」，分享 DMG 给别人不用让对方装任何东西。
#
# 用法：
#   scripts/vendor-ffmpeg.sh                    # 下载 + 校验 + 安装到 vendor/
#   scripts/vendor-ffmpeg.sh --force            # 忽略已有文件，重新获取
#   FFMPEG_LOCAL=/path/to/ffmpeg scripts/vendor-ffmpeg.sh
#                                               # 用本地自建的 ffmpeg，跳过下载
#   FFMPEG_SHA256=<hash> scripts/vendor-ffmpeg.sh
#                                               # 上游更新构建后覆盖校验值
#
# ffmpeg 采用 GPLv2+ 授权，本项目采用 AGPL-3.0：App 以独立进程调用 ffmpeg，
# 不做链接。分发时需同时提供 ffmpeg 的许可与源码获取途径，见 vendor/README.md。
set -euo pipefail
cd "$(dirname "$0")/.."

VENDOR_DIR="vendor"
DEST="$VENDOR_DIR/ffmpeg"

# 上游：OSXExperts 提供的 macOS arm64 静态构建（只依赖系统框架）。
FFMPEG_URL="${FFMPEG_URL:-https://www.osxexperts.net/ffmpeg81arm.zip}"
FFMPEG_VERSION_LABEL="${FFMPEG_VERSION_LABEL:-8.1 (arm64, OSXExperts static build)}"
FFMPEG_SHA256="${FFMPEG_SHA256:-ebb82529562b71170807bbc6b0e7eb4f0b13af8cbb0e085bb9e8f6fe709598ad}"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

# 校验一个 ffmpeg 二进制是否满足要求：arm64 + libass + libx264 + videotoolbox。
verify_binary() {
    local bin="$1"
    [ -x "$bin" ] || { echo "   ✗ 不可执行"; return 1; }

    local arch
    arch="$(lipo -archs "$bin" 2>/dev/null || echo unknown)"
    case "$arch" in
        *arm64*) ;;
        *) echo "   ✗ 架构是 ${arch}，需要 arm64（x86_64 版在 M 系列上走 Rosetta，慢一倍以上）"; return 1 ;;
    esac

    # 按实际能力检测，而不是解析 configure 参数：videotoolbox 在 macOS 上默认
    # 开启，并不会出现在 configuration 行里。
    if ! "$bin" -hide_banner -h filter=subtitles >/dev/null 2>&1; then
        echo "   ✗ 没有 subtitles 滤镜（缺 libass），无法烧制字幕"; return 1
    fi
    local encoders
    encoders="$("$bin" -hide_banner -encoders 2>/dev/null || true)"
    for encoder in libx264 h264_videotoolbox; do
        case "$encoders" in
            *"$encoder"*) ;;
            *) echo "   ✗ 缺少 $encoder 编码器"; return 1 ;;
        esac
    done

    # 静态构建才能随 App 走：不能依赖 /opt/homebrew 或 /usr/local 里的 dylib。
    if otool -L "$bin" | tail -n +2 | awk '{print $1}' | grep -qE '^/(opt/homebrew|usr/local)'; then
        echo "   ✗ 依赖 Homebrew 动态库，无法随 App 分发"
        otool -L "$bin" | tail -n +2 | awk '{print $1}' | grep -E '^/(opt/homebrew|usr/local)' | sed 's/^/      /'
        return 1
    fi

    echo "   ✓ ${arch}，libass / libx264 / videotoolbox 齐备，静态链接"
    return 0
}

if [ "$FORCE" -eq 0 ] && [ -x "$DEST" ]; then
    echo "==> 检查已有的 $DEST"
    if verify_binary "$DEST"; then
        echo "已就绪，跳过下载（要重新获取请加 --force）"
        exit 0
    fi
    echo "   已有文件不合格，重新获取"
fi

mkdir -p "$VENDOR_DIR"

if [ -n "${FFMPEG_LOCAL:-}" ]; then
    echo "==> 使用本地 ffmpeg：$FFMPEG_LOCAL"
    cp "$FFMPEG_LOCAL" "$DEST"
else
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT

    echo "==> 下载 $FFMPEG_URL"
    curl -fL --progress-bar --retry 3 --connect-timeout 20 "$FFMPEG_URL" -o "$TMP/ffmpeg.zip"

    echo "==> 校验 SHA-256"
    ACTUAL="$(shasum -a 256 "$TMP/ffmpeg.zip" | awk '{print $1}')"
    if [ "$ACTUAL" != "$FFMPEG_SHA256" ]; then
        cat >&2 <<EOF
   ✗ SHA-256 不匹配
        期望：$FFMPEG_SHA256
        实际：$ACTUAL

     上游重新构建后哈希会变。请先自行确认来源可信，再用新哈希重跑：
        FFMPEG_SHA256=$ACTUAL scripts/vendor-ffmpeg.sh
     并把新值写回本脚本的 FFMPEG_SHA256。
EOF
        exit 1
    fi
    echo "   ✓ $ACTUAL"

    echo "==> 解压"
    unzip -q -o "$TMP/ffmpeg.zip" -d "$TMP/unpacked"
    SRC="$(find "$TMP/unpacked" -type f -name ffmpeg -not -path '*__MACOSX*' | head -1)"
    [ -n "$SRC" ] || { echo "压缩包里没找到 ffmpeg" >&2; exit 1; }
    cp "$SRC" "$DEST"
fi

chmod +x "$DEST"
# 去掉下载来源的隔离属性，否则 App 调用时会被 Gatekeeper 拦下。
xattr -c "$DEST" 2>/dev/null || true

echo "==> 校验产物"
verify_binary "$DEST" || exit 1

# 随包的许可说明（GPL 合规：注明版本、许可与源码获取途径）。
cat > "$VENDOR_DIR/README.md" <<EOF
# vendor/

此目录存放随 SrtFlow 一起分发的第三方可执行文件，**不纳入版本控制**
（见 .gitignore）。用 \`scripts/vendor-ffmpeg.sh\` 重新获取。

## ffmpeg

- 版本：$FFMPEG_VERSION_LABEL
- 来源：$FFMPEG_URL
- 许可：GNU General Public License v2 或更高版本（GPLv2+）
- 源码：https://ffmpeg.org/download.html ，对应版本源码见
  https://github.com/FFmpeg/FFmpeg

SrtFlow 本体以 AGPL-3.0 授权，通过**独立进程**调用 ffmpeg，不与其链接。
分发包含 ffmpeg 的构建版本时，需一并提供上述许可与源码途径。
运行 \`ffmpeg -L\` 可查看完整许可文本。
EOF

echo
echo "完成：$DEST"
du -h "$DEST" | awk '{print "   体积：" $1}'
"$DEST" -hide_banner -version | head -1 | sed 's/^/   /'
