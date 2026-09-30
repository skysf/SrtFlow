#!/usr/bin/env python3
"""音效一路的规格化：**峰值归一到 -1 dBFS，不做响度归一** → 48kHz / 192kbps AAC，并量出每条的落点。

为什么不按响度归一：音效的动态就是它的全部（一声撞击前后差 40 dB 是设计），按 LUFS 拉平会把安静的铺底抬成噪声、
把撞击压扁；峰值归一只是让「最响的一下」一样响，相对关系不动。放上时间线的默认音量由 App 定。

量什么（都是算出来的，不靠听）：
| 量 | 怎么来 | 用在哪 |
|---|---|---|
| hit（秒） | 50 ms 均方根最大的那一刻（每 10 ms 一步，取窗中心） | AI 按落点把声音压在切点上（同合成音效的 hit_at） |
| loudness | 产物整段 LUFS（loudnorm 量一遍） | 卡片、强度 |
| peak | 产物解回来的采样峰值 | 验证真的到了 -1 dBFS（AAC 编码有过冲 / 欠冲，量产物补增益，最后要在 ±1 dB 内、不许高过 -0.2） |

用法：
  FFMPEG=vendor/ffmpeg scripts/audio-library/sfx_normalize.py sfx-catalog.tsv <素材根目录> <产物目录>
产物：<产物目录>/<id>.m4a + _sfx_normalize.json（按 id 记）。已有的产物跳过（可重复执行）。
"""
import sys, os, json, subprocess, argparse, csv, re, struct, math
from itertools import accumulate

CEILING_DB = -1.0
FFMPEG = os.environ.get("FFMPEG", "ffmpeg")
RATE = 48000


def run(cmd):
    return subprocess.run(cmd, capture_output=True)


def decode(path):
    """解成 48 kHz 双声道 float32（单声道的源两边一样），量峰值和落点用；产物本身保留源声道数。
    **峰值必须在真正的声道上量**：按单声道混下来量，两边相位不同时混出来的峰值偏低，增益就给多了
    （第一版 sfx_0031 产物顶到 +0.3 dBFS）。返回 (左, 右)。"""
    r = run([FFMPEG, "-hide_banner", "-nostdin", "-loglevel", "error", "-i", path,
             "-map", "0:a:0", "-ac", "2", "-ar", str(RATE), "-f", "f32le", "-"])
    if r.returncode != 0:
        return None
    n = len(r.stdout) // 8
    both = struct.unpack(f"<{n * 2}f", r.stdout[:n * 8])
    return both[0::2], both[1::2]


def peak_and_hit(channels):
    """采样峰值（线性，两声道取大）和落点（秒）：50 ms 窗、10 ms 步，两声道能量之和最大的窗的中心。"""
    left, right = channels
    if not left:
        return 0.0, 0.0
    peak = max(max(abs(x) for x in left), max(abs(x) for x in right))
    win, hop = int(0.05 * RATE), int(0.01 * RATE)
    prefix = [0.0] + list(accumulate(l * l + r * r for l, r in zip(left, right)))
    best, at = -1.0, 0
    last = max(0, len(left) - win)
    for start in range(0, last + 1, hop):
        energy = prefix[min(len(left), start + win)] - prefix[start]
        if energy > best:
            best, at = energy, start
    return peak, (at + min(win, len(left)) / 2) / RATE


def peak_db(channels):
    p, _ = peak_and_hit(channels) if channels and channels[0] else (0.0, 0.0)
    return 20 * math.log10(p) if p > 0 else -120.0


def loudness(path):
    r = run([FFMPEG, "-hide_banner", "-nostdin", "-i", path, "-af", "loudnorm=print_format=json", "-f", "null", "-"])
    m = re.search(rb"\{[^{}]*\"input_i\"[^{}]*\}", r.stderr, re.S)
    if not m:
        return None
    d = json.loads(m.group(0))
    return float(d["input_i"]), float(d["input_tp"])


def encode(src, dst, gain_db):
    r = run([FFMPEG, "-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-i", src, "-map", "0:a:0",
             "-af", f"volume={gain_db:.2f}dB", "-ar", str(RATE), "-c:a", "aac", "-b:a", "192k",
             "-movflags", "+faststart", dst])
    return r.returncode == 0, r.stderr.decode(errors="replace")[-400:]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("catalog")
    ap.add_argument("srcdir")
    ap.add_argument("outdir")
    args = ap.parse_args()
    os.makedirs(args.outdir, exist_ok=True)
    record_path = os.path.join(args.outdir, "_sfx_normalize.json")
    records = json.load(open(record_path)) if os.path.exists(record_path) else {}

    rows = list(csv.DictReader(open(args.catalog, encoding="utf-8"), delimiter="\t"))
    failed = []
    for n, row in enumerate(rows, 1):
        sid, src = row["id"], os.path.join(args.srcdir, row["source"])
        dst = os.path.join(args.outdir, f"{sid}.m4a")
        if sid in records and os.path.exists(dst):
            continue
        channels = decode(src)
        if not channels or not channels[0]:
            failed.append((sid, "解不出来")); print(f"  ✗ {sid}: 解不出来 {src}", file=sys.stderr); continue
        peak_in, hit = peak_and_hit(channels)
        if peak_in <= 0:
            failed.append((sid, "全是静音")); print(f"  ✗ {sid}: 全是静音", file=sys.stderr); continue
        gain = CEILING_DB - 20 * math.log10(peak_in)
        # AAC 解回来的峰值和给的增益差得可能不止 0.3 dB（编码器的过冲 / 欠冲），量一遍产物、补一次增益。
        peak_out_db, err = None, None
        for _ in range(3):
            ok, err = encode(src, dst, gain)
            if not ok:
                break
            out = decode(dst)
            peak_out_db = peak_db(out)
            if abs(peak_out_db - CEILING_DB) <= 0.3:
                break
            gain += CEILING_DB - peak_out_db
        if err or peak_out_db is None:
            failed.append((sid, err or "解不回来")); print(f"  ✗ {sid}: {err}", file=sys.stderr); continue
        lufs, tp = loudness(dst) or (None, None)
        duration = len(out[0]) / RATE
        records[sid] = dict(source=row["source"], duration=round(duration, 3), size=os.path.getsize(dst),
                            gain_db=round(gain, 2), peak_in_db=round(20 * math.log10(peak_in), 2),
                            peak_out_db=round(peak_out_db, 2), loudness=lufs, true_peak=tp, hit=round(hit, 3))
        print(f"  [{n}/{len(rows)}] {sid}: {duration:5.1f}s 增益 {gain:+5.1f}dB 峰值 {peak_out_db:5.1f}dBFS "
              f"响度 {lufs} LUFS 落点 {hit:.2f}s {os.path.getsize(dst)/1e3:.0f}KB", file=sys.stderr)
        json.dump(records, open(record_path, "w"), indent=1, ensure_ascii=False)

    # 验证看产物：补过增益之后峰值还离 -1 dBFS 超过 1 dB、或者顶到 -0.2 dBFS 以上，就是管线错了
    # （AAC 有损编码的采样峰值控不到 0.3 dB 以内：同一条换个增益重编，峰值能跳 0.7 dB）。
    off = [sid for sid, r in records.items() if abs(r["peak_out_db"] - CEILING_DB) > 1.0 or r["peak_out_db"] > -0.2]
    print(f"\n规格化 {len(records)}/{len(rows)} 条，失败 {len(failed)}，峰值不对 {len(off)}", file=sys.stderr)
    for sid in off:
        print(f"  ✗ {sid}: 峰值 {records[sid]['peak_out_db']} dBFS", file=sys.stderr)
    sys.exit(1 if failed or off or len(records) < len(rows) else 0)


if __name__ == "__main__":
    main()
