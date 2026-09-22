#!/usr/bin/env python3
"""响度规格化 → 48kHz / 192kbps AAC，并抽出内嵌封面。

两遍：**第一遍 loudnorm 只用来测量**，第二遍用 `volume` 做纯增益。
`loudnorm` 的第二遍**不能用** —— 理由写在 `normalize()` 里。

一条贯穿始终的口径：**宁可响度不统一，也绝不压动态。**
配乐的强弱对比就是它的价值，压平了就只剩背景音乐。所以到不了 -16 LUFS 的那些
保持原样，实际响度写进 manifest，由 App 侧按真值处理。

验证不看参数看产物：跑完再量回 I 和 LRA，纯增益下 LRA 数学上不变，
量回来对不上就是管线出了错（退出码 1）。
"""
import sys, os, json, subprocess, argparse, re

TARGET_I, TARGET_TP, TARGET_LRA = -16.0, -1.5, 11.0
CEILING = -1.0   # 升响度时真峰值的天花板，给 AAC 编码留余量


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def measure(src):
    """第一遍：量出这条流的响度指标。"""
    r = run(["ffmpeg", "-hide_banner", "-nostdin", "-i", src,
             "-af", f"loudnorm=I={TARGET_I}:TP={TARGET_TP}:LRA={TARGET_LRA}:print_format=json",
             "-f", "null", "-"])
    m = re.search(r"\{[^{}]*\"input_i\"[^{}]*\}", r.stderr, re.S)
    if not m:
        return None
    return json.loads(m.group(0))


def normalize(src, dst, meas):
    """第二遍：**纯增益**（`volume` 滤镜），不用 loudnorm 的第二遍。

    为什么不用 loudnorm：它的 `linear=true` 只是"尽量"线性 —— 一旦线性增益会让
    true peak 超过目标，它**自作主张退回 dynamic 压动态**，而且抬高目标 LRA 也拦不住
    （实测 1048289：源 LRA 18.4 → 产物 15.3）。配乐的强弱对比是它的全部价值。

    所以增益自己算，取两个约束的较小值：

        gain = min(目标响度 − 实测响度,  目标峰值 − 实测峰值)

    峰值那一项顶住时，这首就到不了 -16 LUFS —— **那是对的**，宁可响度偏低也不压动态。
    实际响度写进 manifest，卡片和播放都按真值走。`volume` 是纯乘法，LRA 数学上不变。
    """
    in_i, in_tp = float(meas["input_i"]), float(meas["input_tp"])
    want = TARGET_I - in_i                       # 要到 -16 LUFS 需要的增益
    if want <= 0:
        # 太响 → 降。降低永远不会削波，直接给到位。
        gain, limited = want, False
    else:
        # 太安静 → 升，但不能把真峰值顶过天花板。
        # 源峰值已经贴顶时 headroom 为 0，**保持原样而不是往下降** —— 高动态的
        # 氛围曲本来就安静（安静段落 + 几个强音），再降一次是在惩罚它。
        headroom = max(CEILING - in_tp, 0.0)
        gain = min(want, headroom)
        limited = gain < want - 0.05
    r = run(["ffmpeg", "-hide_banner", "-nostdin", "-y", "-i", src,
             "-map", "0:a:0", "-af", f"volume={gain:.2f}dB", "-ar", "48000",
             "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", dst])
    if r.returncode != 0:
        return None, r.stderr[-400:]
    return dict(gain_db=round(gain, 2), peak_limited=limited,
                shortfall=round(want - gain, 2), in_tp=in_tp), None


def extract_cover(src, dst):
    r = run(["ffmpeg", "-hide_banner", "-nostdin", "-y", "-i", src,
             "-an", "-frames:v", "1", "-vf", "scale=400:400:force_original_aspect_ratio=increase,crop=400:400",
             "-q:v", "4", dst])
    return r.returncode == 0 and os.path.exists(dst) and os.path.getsize(dst) > 1000


def verify(path):
    """产物真的量回来，别只断言参数拼对了。

    同时量 LRA：`normalization_type` 只说 ffmpeg 打算怎么做，**源与产物的 LRA 之差
    才是动态有没有被压的硬证据**。
    """
    r = run(["ffmpeg", "-hide_banner", "-nostdin", "-i", path,
             "-af", "loudnorm=print_format=json", "-f", "null", "-"])
    m = re.search(r"\{[^{}]*\"input_i\"[^{}]*\}", r.stderr, re.S)
    if not m:
        return None, None
    d = json.loads(m.group(0))
    return float(d["input_i"]), float(d["input_lra"])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("indir")
    ap.add_argument("outdir")
    args = ap.parse_args()
    os.makedirs(args.outdir, exist_ok=True)
    os.makedirs(os.path.join(args.outdir, "covers"), exist_ok=True)

    srcs = sorted(f for f in os.listdir(args.indir) if f.endswith(".mp3"))
    results = []
    for n, name in enumerate(srcs, 1):
        tid = name[:-4]
        src = os.path.join(args.indir, name)
        dst = os.path.join(args.outdir, f"{tid}.m4a")
        cov = os.path.join(args.outdir, "covers", f"{tid}.jpg")

        meas = measure(src)
        if not meas:
            print(f"  ✗ {tid}: 第一遍量不出响度", file=sys.stderr)
            continue
        out, err = normalize(src, dst, meas)
        if err:
            print(f"  ✗ {tid}: {err}", file=sys.stderr)
            continue
        got_i, got_lra = verify(dst)
        has_cover = extract_cover(src, cov)
        lra_in = float(meas["input_lra"])
        results.append(dict(track_id=tid, measured_in=float(meas["input_i"]),
                            measured_out=got_i, lra_in=lra_in, lra_out=got_lra,
                            gain_db=out["gain_db"], peak_limited=out["peak_limited"],
                            shortfall=out["shortfall"],
                            size=os.path.getsize(dst), cover=has_cover))
        flag = f" ⚠峰值顶住,差{out['shortfall']}dB" if out["peak_limited"] else ""
        print(f"  [{n}/{len(srcs)}] {tid}: {meas['input_i']} → {got_i} LUFS "
              f"(gain {out['gain_db']:+.1f}dB, LRA {lra_in}→{got_lra}{flag}, "
              f"{os.path.getsize(dst)/1e6:.1f}MB, cover={'y' if has_cover else 'n'})", file=sys.stderr)

    with open(os.path.join(args.outdir, "_normalize.json"), "w") as f:
        json.dump(results, f, indent=1)

    # 动态有没有被压：纯增益下 LRA 数学上不变，量回来差 2dB 以上就是管线出了错
    squashed = [r for r in results if r["lra_out"] is not None and abs(r["lra_in"] - r["lra_out"]) > 2.0]
    limited = [r for r in results if r["peak_limited"]]
    off = [r for r in results if r["measured_out"] is not None
           and abs(r["measured_out"] - TARGET_I) > 1.0 and not r["peak_limited"]]

    print(f"\n规格化 {len(results)} 首", file=sys.stderr)
    print(f"  动态被压（管线错误）      {len(squashed)}", file=sys.stderr)
    print(f"  峰值顶住、响度到不了 -16  {len(limited)}   ← 正常，保动态的代价", file=sys.stderr)
    print(f"  没顶住却也没到 -16        {len(off)}   ← 不正常", file=sys.stderr)
    for r in squashed:
        print(f"  ✗ {r['track_id']} LRA {r['lra_in']} → {r['lra_out']}", file=sys.stderr)
    for r in off:
        print(f"  ✗ {r['track_id']} 响度 {r['measured_out']}，增益 {r['gain_db']}dB", file=sys.stderr)
    sys.exit(1 if squashed or off else 0)


if __name__ == "__main__":
    main()
