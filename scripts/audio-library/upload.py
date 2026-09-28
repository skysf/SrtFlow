#!/usr/bin/env python3
"""把规格化好的素材 + manifest 传到 R2。纯标准库 SigV4，不装依赖。

约定的落点（和 manifest 里的 url 必须一致）：

    Audio/Music/mus_<id>.m4a
    Audio/Music/covers/mus_<id>.jpg
    Audio/Music/manifest.json

**Cache-Control 分两种**：素材按 id 命名且内容永不变，给 immutable 长缓存；
manifest 会随扩库更新，只给 5 分钟 —— 给长了用户看不到新素材，而它才 50KB。

发布前会剥掉 `_why`（那是给人工复核看 tag 依据的，不该进生产数据）。
"""
import sys, os, json, argparse
from concurrent.futures import ThreadPoolExecutor

# 签名上传只有 scripts/r2.py 那一份（本机配音模型也用它）。
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from r2 import put, bucket, IMMUTABLE, SHORT  # noqa: E402

BUCKET = bucket()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("normdir")
    ap.add_argument("manifest")
    ap.add_argument("--prefix", default="Audio/Music")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    man = json.load(open(args.manifest, encoding="utf-8"))
    jobs = []
    for item in man["items"]:
        tid = item["id"].removeprefix("mus_")
        audio = os.path.join(args.normdir, f"{tid}.m4a")
        cover = os.path.join(args.normdir, "covers", f"{tid}.jpg")
        if not os.path.exists(audio):
            print(f"  ✗ {item['id']}: 找不到 {audio}", file=sys.stderr)
            continue
        jobs.append((f"{args.prefix}/{item['id']}.m4a", audio, "audio/mp4", IMMUTABLE))
        if item.get("cover") and os.path.exists(cover):
            jobs.append((f"{args.prefix}/covers/{item['id']}.jpg", cover, "image/jpeg", IMMUTABLE))

    total = sum(os.path.getsize(p) for _, p, _, _ in jobs)
    print(f"{len(jobs)} 个对象，{total/1e6:.0f} MB → s3://{BUCKET}/{args.prefix}/", file=sys.stderr)
    if args.dry_run:
        for k, p, ct, _ in jobs[:5]:
            print(f"  {k}  ({ct}, {os.path.getsize(p)/1e3:.0f}KB)", file=sys.stderr)
        print(f"  … 共 {len(jobs)} 个（dry-run，什么都没传）", file=sys.stderr)
        return 0

    fails = []

    def one(job):
        key, path, ct, cc = job
        with open(path, "rb") as f:
            status, err = put(key, f.read(), ct, cc)
        return key, status, err

    done = 0
    with ThreadPoolExecutor(max_workers=4) as ex:
        for key, status, err in ex.map(one, jobs):
            done += 1
            if status not in (200, 201):
                fails.append((key, status, err))
                print(f"  ✗ {key}: HTTP {status} {err}", file=sys.stderr)
            elif done % 20 == 0:
                print(f"  … {done}/{len(jobs)}", file=sys.stderr)

    # manifest 最后传：素材没齐就先上清单的话，用户会看到点了下不动的条目。
    # 同时剥掉 `_why`（人工复核用的 tag 依据，不进生产数据）。
    clean = dict(man)
    clean["items"] = [{k: v for k, v in it.items() if k != "_why"} for it in man["items"]]
    body = json.dumps(clean, ensure_ascii=False, separators=(",", ":")).encode()
    status, err = put(f"{args.prefix}/manifest.json", body, "application/json", SHORT)
    print(f"manifest.json: HTTP {status} ({len(body)/1e3:.0f}KB) {err or ''}", file=sys.stderr)

    print(f"\n传完 {len(jobs) - len(fails)}/{len(jobs)} 个对象，失败 {len(fails)}", file=sys.stderr)
    return 1 if fails or status not in (200, 201) else 0


if __name__ == "__main__":
    sys.exit(main())
