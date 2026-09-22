#!/usr/bin/env python3
"""按候选清单从 Jamendo 公开端点下载音频。

对源站友好：最多 3 个并发、每次请求之间有间隔、失败重试 2 次。
已存在且大小合理的文件跳过（可反复跑）。
"""
import sys, os, time, csv, argparse, urllib.request, urllib.error
from concurrent.futures import ThreadPoolExecutor

URL = "https://mp3d.jamendo.com/download/track/{}/mp32/"
UA = "SrtFlow-audio-library/0.1 (+https://skylu.ai) personal music library build"


def fetch(row, outdir, retries=2):
    tid = row["track_id"]
    dest = os.path.join(outdir, f"{tid}.mp3")
    if os.path.exists(dest) and os.path.getsize(dest) > 200_000:
        return tid, "skip", os.path.getsize(dest)
    for attempt in range(retries + 1):
        try:
            req = urllib.request.Request(URL.format(tid), headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=120) as r:
                data = r.read()
            if len(data) < 200_000:
                return tid, f"too-small({len(data)})", 0
            tmp = dest + ".part"
            with open(tmp, "wb") as f:
                f.write(data)
            os.replace(tmp, dest)
            time.sleep(0.4)          # 对源站客气一点
            return tid, "ok", len(data)
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            if attempt == retries:
                return tid, f"fail: {type(e).__name__}", 0
            time.sleep(2 * (attempt + 1))
    return tid, "fail", 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("candidates")
    ap.add_argument("outdir")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--mood-only", action="store_true", help="只下有 mood 标注的")
    args = ap.parse_args()
    os.makedirs(args.outdir, exist_ok=True)

    with open(args.candidates, encoding="utf-8") as f:
        rows = list(csv.DictReader(f, delimiter="\t"))
    if args.mood_only:
        rows = [r for r in rows if r["moods"]]
    if args.limit:
        rows = rows[:args.limit]

    print(f"准备下载 {len(rows)} 首 → {args.outdir}", file=sys.stderr)
    ok = skip = fail = 0
    total = 0
    with ThreadPoolExecutor(max_workers=3) as ex:
        for tid, status, size in ex.map(lambda r: fetch(r, args.outdir), rows):
            total += size
            if status == "ok":
                ok += 1
            elif status == "skip":
                skip += 1
            else:
                fail += 1
                print(f"  ✗ {tid}: {status}", file=sys.stderr)
    print(f"完成：新下 {ok}、已有 {skip}、失败 {fail}，共 {total/1e6:.0f} MB", file=sys.stderr)
    sys.exit(1 if fail and not ok else 0)


if __name__ == "__main__":
    main()
