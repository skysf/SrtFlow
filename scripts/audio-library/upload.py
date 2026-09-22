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
import sys, os, json, hashlib, hmac, datetime, argparse, mimetypes
import urllib.request, urllib.error
from concurrent.futures import ThreadPoolExecutor

AK = os.environ["R2_ACCESS_KEY_ID"]
SK = os.environ["R2_SECRET_ACCESS_KEY"]
EP = os.environ["R2_ENDPOINT"]
BUCKET = os.environ.get("R2_BUCKET", "skylu-downloads")
HOST = EP.split("://", 1)[1]


def put(key, body, content_type, cache_control):
    t = datetime.datetime.now(datetime.timezone.utc)
    amzdate, datestamp = t.strftime("%Y%m%dT%H%M%SZ"), t.strftime("%Y%m%d")
    ph = hashlib.sha256(body).hexdigest()
    uri = "/" + BUCKET + "/" + key
    headers = {
        "cache-control": cache_control,
        "content-type": content_type,
        "host": HOST,
        "x-amz-content-sha256": ph,
        "x-amz-date": amzdate,
    }
    signed = ";".join(sorted(headers))
    canon_headers = "".join(f"{k}:{headers[k]}\n" for k in sorted(headers))
    creq = f"PUT\n{uri}\n\n{canon_headers}\n{signed}\n{ph}"
    scope = f"{datestamp}/auto/s3/aws4_request"
    to_sign = f"AWS4-HMAC-SHA256\n{amzdate}\n{scope}\n{hashlib.sha256(creq.encode()).hexdigest()}"

    def s(k, m): return hmac.new(k, m.encode(), hashlib.sha256).digest()
    key4 = s(s(s(s(("AWS4" + SK).encode(), datestamp), "auto"), "s3"), "aws4_request")
    sig = hmac.new(key4, to_sign.encode(), hashlib.sha256).hexdigest()

    req = urllib.request.Request(EP + uri, data=body, method="PUT", headers={
        **{k.title(): v for k, v in headers.items() if k != "host"},
        "Host": HOST,
        "Authorization": f"AWS4-HMAC-SHA256 Credential={AK}/{scope}, "
                         f"SignedHeaders={signed}, Signature={sig}",
    })
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return r.status, None
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:200]


IMMUTABLE = "public, max-age=31536000, immutable"
SHORT = "public, max-age=300"


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
