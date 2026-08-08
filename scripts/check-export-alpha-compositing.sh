#!/usr/bin/env bash
# 画中画关键帧动画的 fill+matte 合成自检：真的跑一遍 ffmpeg，量输出像素。
#
# 背景（详见 docs/bugfixes/2026-08-05-export-prerender-review.md）：
# VideoEditExportGraph.plan() 里，动画画中画的 fill 是压在黑底上合成出来的，
# 边缘抗锯齿处的 RGB 已经是「真实色 x coverage x opacity」（预乘）；直接
# alphamerge 接 matte 的 alpha 再喂给 overlay 默认的 straight 混合，边缘
# alpha 会被多乘一次（50% 覆盖处只有该有亮度的一半）。修法是先按 matte 把
# fill 除回真实色再 alphamerge。这条链子踩过两个隐蔽坑：matte 的 rgb24
# 版本从 gray 版本派生（而不是独立从原始输入转）会让 alphamerge 拿到的
# alpha 整段跑偏（128 变成 76，原因不明）；fill 不带 opacity（matte 带）
# 会让除法商里残留 1/opacity，把不透明度设置抵消掉。三组自检（共 4 条
# 断言：正确链路 x2 + 两个坑各留一个必须跑偏的反例）都在这个脚本里，
# 改动 VideoEditExportGraph.plan() 里这段 filter 图之前必读。
#
# ⚠️ 本脚本用的是**手工复制的独立 alpha fixture**，并**不调用生产的
# `VideoEditExporter`**。它守的是 alpha 合成数学本身，**不构成生产导出滤镜图的回归**。
# 生产滤镜的帧率接线由 `checks/no-hardcoded-fps.sh`（扫描守卫）与
# `scripts/check-preview-composition.sh`（真导出数帧）负责。
#
# fixture 的 FPS 已参数化并真的跑 24/30/60 三档（计划 §17.3）。
#
# **这三档能证明什么、不能证明什么，说清楚**：
# - 能证明：滤镜串里不再写死 30；alpha 合成数学**与帧率无关**（三档结果一致且正确）。
# - **不能**证明：帧率被写错时会失败。fixture 只取第一帧（`-frames:v 1`），
#   而 alpha 是逐帧数学 —— 实测把 FPS 换成非法的 999 三档照样全过。
# 因此「滤镜里不许写死帧率」这条由 `checks/no-hardcoded-fps.sh` 扫描守卫兜底
#（它同时扫本脚本），不要指望这里的断言能替它把关。
#
# 用法：
#   scripts/check-export-alpha-compositing.sh
#
# 注：本脚本变量插值一律用 ${var} 带花括号——系统自带的 bash 3.2 在变量名
# 后紧跟中文全角标点时会把标点的字节误认成变量名的一部分，报
# 「xxx：unbound variable」，花括号能明确切开边界。
set -euo pipefail
cd "$(dirname "$0")/.."

FFMPEG="${SRTFLOW_FFMPEG:-$(pwd)/vendor/ffmpeg}"
if [ ! -x "${FFMPEG}" ]; then
    echo "找不到 ffmpeg：${FFMPEG}（跑一次 scripts/vendor-ffmpeg.sh，或设 SRTFLOW_FFMPEG）" >&2
    exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

failures=0

# 读一帧输出的第一个像素（RGB24，3 字节）。
read_pixel() {
    od -An -tu1 -N3 "$1" | tr -s ' '
}

# 断言第一个像素的 R/G/B 分别落在期望值 ±tolerance 内。
assert_pixel() {
    local label="$1" file="$2" want_r="$3" want_g="$4" want_b="$5" tolerance="$6"
    local r g b
    read -r r g b <<< "$(read_pixel "${file}")"
    local ok=1
    for pair in "${r}:${want_r}" "${g}:${want_g}" "${b}:${want_b}"; do
        local got="${pair%%:*}" want="${pair##*:}"
        local diff=$(( got - want ))
        [ "${diff}" -lt 0 ] && diff=$(( -diff ))
        [ "${diff}" -le "${tolerance}" ] || ok=0
    done
    if [ "${ok}" -eq 1 ]; then
        echo "PASS ${label}: (${r},${g},${b}) ~= (${want_r},${want_g},${want_b})"
    else
        echo "FAIL ${label}: got (${r},${g},${b}), want (${want_r},${want_g},${want_b}) +-${tolerance}"
        failures=$((failures + 1))
    fi
}

for FPS in 24 30 60; do
    echo
    echo "######## fixture 帧率 ${FPS} fps ########"
    # 场景：橙色(255,128,0) 内容、50% 覆盖边缘（matte=128），叠在灰底(50,50,50)
    # 上。期望值按标准 straight-alpha over 公式手算：
    #   out = true_rgb * a + bg * (1-a)，a = 128/255 约 0.502
    #   R: 255*0.502+50*0.498 约 153  G: 128*0.502+50*0.498 约 89  B: 50*0.498 约 25

    echo "== 1. 生产实际使用的链路（fill/matte 独立转码，除回真实色再 alphamerge） =="
    "${FFMPEG}" -hide_banner -loglevel error \
        -f lavfi -i color=0x804000:s=8x8:d=1:r=10 \
        -f lavfi -i color=0x808080:s=8x8:d=1:r=10 \
        -f lavfi -i color=0x323232:s=8x8:d=1:r=10 \
        -filter_complex "\
    [0:v]fps=${FPS},setsar=1,format=rgb24[kf1];\
    [1:v]fps=${FPS},setsar=1,format=gray[km1];\
    [1:v]fps=${FPS},setsar=1,format=rgb24[kmc1];\
    [kf1][kmc1]blend=all_expr='if(gt(B,0),min(255,255*A/B),0)'[ks1];\
    [ks1][km1]alphamerge,format=rgba,setpts=PTS+0/TB[ov1];\
    [2:v][ov1]overlay=x=0:y=0:eof_action=pass:enable='between(t,0,4)'[out]" \
        -map "[out]" -frames:v 1 -f rawvideo -pix_fmt rgb24 -y "${WORKDIR}/fixed.raw" 2>&1
    assert_pixel "straight-alpha 混合结果" "${WORKDIR}/fixed.raw" 152 88 25 4

    echo ""
    echo "== 2. 回归：matte 的 rgb24 版本从 gray 版本派生（诱发 alpha 跑偏的写法），必须明显偏离 =="
    "${FFMPEG}" -hide_banner -loglevel error \
        -f lavfi -i color=0x804000:s=8x8:d=1:r=10 \
        -f lavfi -i color=0x808080:s=8x8:d=1:r=10 \
        -f lavfi -i color=0x323232:s=8x8:d=1:r=10 \
        -filter_complex "\
    [0:v]fps=${FPS},setsar=1,format=rgb24[kf1];\
    [1:v]fps=${FPS},setsar=1,format=gray[km1];\
    [km1]format=rgb24[kmc1];\
    [kf1][kmc1]blend=all_expr='if(gt(B,0),min(255,255*A/B),0)'[ks1];\
    [ks1][km1]alphamerge,format=rgba,setpts=PTS+0/TB[ov1];\
    [2:v][ov1]overlay=x=0:y=0:eof_action=pass:enable='between(t,0,4)'[out]" \
        -map "[out]" -frames:v 1 -f rawvideo -pix_fmt rgb24 -y "${WORKDIR}/diamond.raw" 2>&1
    dr=0
    read -r dr _ _ <<< "$(read_pixel "${WORKDIR}/diamond.raw")"
    diamond_diff=$(( dr - 152 ))
    [ "${diamond_diff}" -lt 0 ] && diamond_diff=$(( -diamond_diff ))
    if [ "${diamond_diff}" -ge 15 ]; then
        echo "PASS 省一次解码的写法确实会跑偏（R=${dr}，偏离期望 ${diamond_diff}）——留着当反例"
    else
        echo "FAIL 省一次解码的写法这次居然没跑偏（R=${dr}）——ffmpeg 行为可能变了，去重新核实这条坑还在不在"
        failures=$((failures + 1))
    fi

    echo ""
    echo "== 3. 回归：全覆盖 + 50% opacity（fill 必须跟 matte 带同一份 opacity 权重）=="
    # 场景：真实色 T=200（灰）、coverage=1（不测边缘，纯测 opacity 这一维）、
    # opacity=0.5，黑底。正确 fill = T*c*o = 200*1*0.5 = 100（VideoEditPrerender
    # 里 fill 现在必须保留 opacity，不能像早先版本那样强制 opacity=1）；
    # matte = c*o*255 = 128（matte 一直都带 opacity，没变过）。
    # 期望 = T*(c*o) + bg*(1-c*o) = 200*0.5 + 0 = 100。
    echo "-- 3a. fill 带 opacity（正确）：T=200,o=0.5 --"
    "${FFMPEG}" -hide_banner -loglevel error \
        -f lavfi -i color=0x646464:s=8x8:d=1:r=10 \
        -f lavfi -i color=0x808080:s=8x8:d=1:r=10 \
        -f lavfi -i color=black:s=8x8:d=1:r=10 \
        -filter_complex "\
    [0:v]fps=${FPS},setsar=1,format=rgb24[kf1];\
    [1:v]fps=${FPS},setsar=1,format=gray[km1];\
    [1:v]fps=${FPS},setsar=1,format=rgb24[kmc1];\
    [kf1][kmc1]blend=all_expr='if(gt(B,0),min(255,255*A/B),0)'[ks1];\
    [ks1][km1]alphamerge,format=rgba,setpts=PTS+0/TB[ov1];\
    [2:v][ov1]overlay=x=0:y=0:eof_action=pass:enable='between(t,0,4)'[out]" \
        -map "[out]" -frames:v 1 -f rawvideo -pix_fmt rgb24 -y "${WORKDIR}/opacity_ok.raw" 2>&1
    assert_pixel "fill 带 opacity 时的合成结果" "${WORKDIR}/opacity_ok.raw" 100 100 100 4

    echo ""
    echo "-- 3b. fill 不带 opacity（早先版本的写法，诱发 opacity 被抵消），必须明显偏离 --"
    "${FFMPEG}" -hide_banner -loglevel error \
        -f lavfi -i color=0xc8c8c8:s=8x8:d=1:r=10 \
        -f lavfi -i color=0x808080:s=8x8:d=1:r=10 \
        -f lavfi -i color=black:s=8x8:d=1:r=10 \
        -filter_complex "\
    [0:v]fps=${FPS},setsar=1,format=rgb24[kf1];\
    [1:v]fps=${FPS},setsar=1,format=gray[km1];\
    [1:v]fps=${FPS},setsar=1,format=rgb24[kmc1];\
    [kf1][kmc1]blend=all_expr='if(gt(B,0),min(255,255*A/B),0)'[ks1];\
    [ks1][km1]alphamerge,format=rgba,setpts=PTS+0/TB[ov1];\
    [2:v][ov1]overlay=x=0:y=0:eof_action=pass:enable='between(t,0,4)'[out]" \
        -map "[out]" -frames:v 1 -f rawvideo -pix_fmt rgb24 -y "${WORKDIR}/opacity_bad.raw" 2>&1
    ob=0
    read -r ob _ _ <<< "$(read_pixel "${WORKDIR}/opacity_bad.raw")"
    opacity_diff=$(( ob - 100 ))
    [ "${opacity_diff}" -lt 0 ] && opacity_diff=$(( -opacity_diff ))
    if [ "${opacity_diff}" -ge 15 ]; then
        echo "PASS fill 不带 opacity 确实会跑偏（R=${ob}，偏离期望 ${opacity_diff}）——留着当反例"
    else
        echo "FAIL fill 不带 opacity 这次居然没跑偏（R=${ob}）——去重新核实这条坑还在不在"
        failures=$((failures + 1))
    fi

done

echo ""
echo "${failures} 处失败"
[ "${failures}" -eq 0 ] && echo "All checks passed"
exit "${failures}"
