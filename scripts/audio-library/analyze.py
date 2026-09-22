#!/usr/bin/env python3
"""抽客观声学特征，供推 tags 用。重活全交给 ffmpeg，本机不装任何依赖。

抽这几样（都是能确定算出来的，不靠"听"）：

| 特征 | 怎么来 | 推什么 tag |
|---|---|---|
| 响度包络（每 100ms） | `ebur128` 的 momentary | 渐强 → epic/trailer；平稳 → background |
| 起伏幅度 p90−p10 | 同上 | 大 → drama；小 → ambient/calm |
| 前 15% vs 后 15% | 同上 | 正差大 → 建立感（buildup） |
| 频谱重心均值 | `aspectralstats` | 低 → dark/deep；高 → bright/airy |
| 首尾静音 | `silencedetect` | 有没有天然的淡入淡出余量 |

**不抽 BPM**：ffmpeg 没有可靠的节拍检测，而 ambient/score 大多没有明确节拍，
硬推出来的数字会误导筛选。宁可没有这一项。
"""
import sys, os, re, json, math, subprocess, argparse


def ffprobe_duration(path):
    r = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                        "-of", "default=nw=1:nk=1", path], capture_output=True, text=True)
    try:
        return float(r.stdout.strip())
    except ValueError:
        return None


def scan(path):
    """一次 ffmpeg 跑完包络 + 频谱重心，metadata 全打到 stderr 再解析。"""
    af = ("ebur128=metadata=1,"
          "aspectralstats=measure=centroid,"
          "ametadata=print:file=-")
    r = subprocess.run(["ffmpeg", "-hide_banner", "-nostdin", "-i", path,
                        "-af", af, "-f", "null", "-"],
                       capture_output=True, text=True)
    loud, centroid = [], []
    for line in r.stdout.splitlines():
        if (m := re.match(r"lavfi\.r128\.M=(-?[\d.]+)", line)):
            v = float(m.group(1))
            if v > -120:                      # -120 是静音哨兵，不进统计
                loud.append(v)
        elif (m := re.match(r"lavfi\.aspectralstats\.1\.centroid=([\d.]+)", line)):
            centroid.append(float(m.group(1)))
    return loud, centroid


def silence_edges(path, dur):
    """首尾静音长度（-45dB 以下算静音）。"""
    r = subprocess.run(["ffmpeg", "-hide_banner", "-nostdin", "-i", path,
                        "-af", "silencedetect=n=-45dB:d=0.3", "-f", "null", "-"],
                       capture_output=True, text=True)
    spans = []
    start = None
    for line in r.stderr.splitlines():
        if (m := re.search(r"silence_start: (-?[\d.]+)", line)):
            start = float(m.group(1))
        elif (m := re.search(r"silence_end: ([\d.]+)", line)) and start is not None:
            spans.append((max(start, 0.0), float(m.group(1))))
            start = None
    if start is not None and dur:
        spans.append((max(start, 0.0), dur))
    head = next((e - s for s, e in spans if s < 0.5), 0.0)
    tail = next((e - s for s, e in spans if dur and e >= dur - 0.5), 0.0)
    return round(head, 2), round(tail, 2)


def pct(xs, p):
    if not xs:
        return None
    s = sorted(xs)
    i = min(len(s) - 1, max(0, int(round(p / 100 * (len(s) - 1)))))
    return s[i]


def slope(xs):
    """对包络做最小二乘，返回"每分钟涨几 dB"。正值大 = 越来越响。"""
    n = len(xs)
    if n < 10:
        return 0.0
    mx, my = (n - 1) / 2, sum(xs) / n
    num = sum((i - mx) * (v - my) for i, v in enumerate(xs))
    den = sum((i - mx) ** 2 for i in range(n))
    per_frame = num / den if den else 0.0
    return per_frame * 600          # momentary 每 100ms 一帧 → 每分钟


def analyze(path):
    dur = ffprobe_duration(path)
    loud, centroid = scan(path)
    if not loud:
        return None
    head, tail = silence_edges(path, dur)
    n = len(loud)
    k = max(1, n // 7)                        # 前/后 ~15%
    return dict(
        duration=round(dur, 2) if dur else None,
        loud_p10=round(pct(loud, 10), 2),
        loud_p50=round(pct(loud, 50), 2),
        loud_p90=round(pct(loud, 90), 2),
        swing=round(pct(loud, 90) - pct(loud, 10), 2),
        slope_db_per_min=round(slope(loud), 2),
        head_vs_tail=round(sum(loud[-k:]) / k - sum(loud[:k]) / k, 2),
        centroid_hz=round(sum(centroid) / len(centroid)) if centroid else None,
        silence_head=head,
        silence_tail=tail,
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("indir")
    ap.add_argument("out")
    args = ap.parse_args()

    files = sorted(f for f in os.listdir(args.indir) if f.endswith(".m4a"))
    out = {}
    for n, name in enumerate(files, 1):
        tid = name[:-4]
        f = analyze(os.path.join(args.indir, name))
        if not f:
            print(f"  ✗ {tid}: 抽不出特征", file=sys.stderr)
            continue
        out[tid] = f
        print(f"  [{n}/{len(files)}] {tid}: {f['duration']}s "
              f"中位 {f['loud_p50']}LUFS 起伏 {f['swing']}dB "
              f"斜率 {f['slope_db_per_min']:+.1f}dB/min 重心 {f['centroid_hz']}Hz "
              f"首尾静音 {f['silence_head']}/{f['silence_tail']}s", file=sys.stderr)
    json.dump(out, open(args.out, "w"), indent=1)
    print(f"\n抽完 {len(out)}/{len(files)} 首 → {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
