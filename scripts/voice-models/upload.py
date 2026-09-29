#!/usr/bin/env python3
"""把 prepare-kokoro.py 整理好的模型传到 R2，清单最后传。

用法（凭证见 scripts/r2.py 开头）：
  set -a; source ~/.config/srtflow/r2.env; set +a
  scripts/voice-models/upload.py <整理好的目录> [--prefix Models/Kokoro-82M-CoreML/v1] [--dry-run]

落点：s3://skylu-downloads/<prefix>/<相对路径> → https://downloads.skylu.ai/<prefix>/<相对路径>
（App 里写死的是 Sources/SrtFlow/KokoroVoicePack.swift 的 baseURL，两边必须一致）。
文件按版本号放、内容永不变，给长缓存；清单给 5 分钟。清单最后传：文件没齐就先上清单，用户会下到一半找不到文件。
传完从公开地址读回清单，逐个核对大小（下载时 App 还会逐个核 SHA-256）。长期约束见 docs/build/voice-model-pipeline.md。
"""
import argparse
import json
import os
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from r2 import put, bucket, IMMUTABLE, SHORT  # noqa: E402

PUBLIC = "https://downloads.skylu.ai"
# 公开域名前面有 Cloudflare：Python 默认的 User-Agent（Python-urllib）会被拦成 403，核对时带一个自己的。
USER_AGENT = "SrtFlow-voice-model-upload/1"


def content_type(path):
    if path.endswith(".json"):
        return "application/json"
    if path.endswith(".md"):
        return "text/markdown; charset=utf-8"
    return "application/octet-stream"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("folder")
    ap.add_argument("--prefix", default="Models/Kokoro-82M-CoreML/v1")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--verify-only", action="store_true", help="不传，只从公开地址核对")
    args = ap.parse_args()

    manifest_path = os.path.join(args.folder, "manifest.json")
    manifest = json.load(open(manifest_path, encoding="utf-8"))
    files = manifest["files"]
    total = sum(f["size"] for f in files)
    print(f"{len(files)} 个文件，{total / 1e6:.0f} MB → s3://{bucket()}/{args.prefix}/", file=sys.stderr)
    if args.verify_only:
        return verify(args.prefix, manifest)
    if args.dry_run:
        for f in files[:5]:
            print(f"  {f['path']}  ({f['size'] / 1e3:.0f} KB)", file=sys.stderr)
        print(f"  … 共 {len(files)} 个（dry-run，什么都没传）", file=sys.stderr)
        return 0

    def one(entry):
        with open(os.path.join(args.folder, entry["path"]), "rb") as f:
            status, err = put(f"{args.prefix}/{entry['path']}", f.read(), content_type(entry["path"]), IMMUTABLE)
        return entry["path"], status, err

    fails = []
    done = 0
    with ThreadPoolExecutor(max_workers=4) as ex:
        for path, status, err in ex.map(one, files):
            done += 1
            if status not in (200, 201):
                fails.append(path)
                print(f"  ✗ {path}: HTTP {status} {err}", file=sys.stderr)
            elif done % 10 == 0 or done == len(files):
                print(f"  … {done}/{len(files)}", file=sys.stderr)
    if fails:
        print(f"✗ {len(fails)} 个没传上，清单不传", file=sys.stderr)
        return 1

    body = open(manifest_path, "rb").read()
    status, err = put(f"{args.prefix}/manifest.json", body, "application/json", SHORT)
    if status not in (200, 201):
        print(f"✗ manifest.json: HTTP {status} {err}", file=sys.stderr)
        return 1

    return verify(args.prefix, manifest)


def verify(prefix, manifest):
    """从公开地址读回来核对（R2 的公开域名和 S3 接口是两条路，传上去不等于用户下得到）。"""
    base = f"{PUBLIC}/{prefix}/"
    headers = {"User-Agent": USER_AGENT}
    request = urllib.request.Request(base + "manifest.json", headers=headers)
    remote = json.load(urllib.request.urlopen(request, timeout=60))
    if remote != manifest:
        print("✗ 公开地址读回来的清单和本地的不一样", file=sys.stderr)
        return 1
    bad = []
    for entry in manifest["files"]:
        req = urllib.request.Request(base + entry["path"], method="HEAD", headers=headers)
        with urllib.request.urlopen(req, timeout=60) as r:
            if int(r.headers.get("Content-Length", -1)) != entry["size"]:
                bad.append(entry["path"])
    if bad:
        print(f"✗ 这些文件公开地址上的大小不对：{bad[:5]}", file=sys.stderr)
        return 1
    print(f"✓ 核对过：{len(manifest['files'])} 个文件、清单都在 {base}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
