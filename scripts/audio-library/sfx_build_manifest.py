#!/usr/bin/env python3
"""音效清单：手写的目录（sfx-catalog.tsv：id、来源、中英标题、来源方、tag）+ 规格化记录 → `Audio/SoundEffects/manifest.json`。

和音乐清单的差别：
- `kind` 是 sfx；`title` 是英文、`title_zh` 另给（App 目前只认 title，字段多了照忍）；
- `hit`：落点（秒），AI 按它把声音压在切点上；
- 授权一律 `owned`（作者自己生成或买来、有权分发；docs/plans/2026-09-22-audio-library.md 第十节）：不用署名，
  署名页和 music_credits 都不列；`provenance` 记着是 ElevenLabs 生成的还是买来的，只给人看；
- tag 词表：音乐的 TAGS（build_manifest.py）+ 下面的 SFX_TAGS（type 一组是音效的种类）。加 tag 只动这两张表。

用法：
  sfx_build_manifest.py sfx-catalog.tsv <产物目录> manifest.json [--base https://downloads.skylu.ai/Audio]
  sfx_build_manifest.py sfx-catalog.tsv --check     # 只验目录：id 唯一且连号、来源唯一、标题非空、tag 都在词表里
"""
import sys, os, json, csv, argparse, datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build_manifest import TAGS  # noqa: E402

# 音效自己的词表：id → (zh, en, group)。type 是种类，scene / mood 补几个音乐没有的。
SFX_TAGS = {
    "whoosh":     ("呼啸",   "whoosh",     "type"),
    "impact":     ("撞击",   "impact",     "type"),
    "riser":      ("上扬",   "riser",      "type"),
    "downlifter": ("下坠",   "downlifter", "type"),
    "suction":    ("倒吸",   "suction",    "type"),
    "shimmer":    ("闪烁",   "shimmer",    "type"),
    "bed":        ("铺底",   "bed",        "type"),
    "drone":      ("低鸣",   "drone",      "type"),
    "braam":      ("铜管低鸣", "braam",    "type"),
    "harp":       ("竖琴",   "harp",       "type"),
    "transition": ("转场",   "transition", "type"),
    "glitch":     ("故障",   "glitch",     "type"),
    "static":     ("静电",   "static",     "type"),
    "fracture":   ("碎裂",   "fracture",   "type"),
    "ice":        ("冰",     "ice",        "type"),
    "water":      ("水",     "water",      "type"),
    "droplet":    ("水滴",   "droplet",    "type"),
    "bubbles":    ("气泡",   "bubbles",    "type"),
    "wind":       ("风",     "wind",       "type"),
    "storm":      ("风暴",   "storm",      "type"),
    "animal":     ("动物",   "animal",     "type"),
    "creak":      ("吱嘎",   "creak",      "type"),
    "mechanical": ("机械",   "mechanical", "type"),
    "gears":      ("齿轮",   "gears",      "type"),
    "cloth":      ("布料",   "cloth",      "type"),
    "scifi":      ("科幻",   "scifi",      "scene"),
    "cinematic":  ("电影感", "cinematic",  "scene"),
}
ALL_TAGS = {**TAGS, **SFX_TAGS}
PROVENANCE = {"elevenlabs", "purchased"}
LICENSE = {"code": "owned", "by": "Sky Studio", "src": None, "text": "Sky Studio (owned)"}


def check_catalog(rows):
    """目录本身的毛病，一条一条报出来。"""
    problems = []
    ids, sources = [r["id"] for r in rows], [r["source"] for r in rows]
    if len(set(ids)) != len(ids):
        problems.append("id 有重复")
    for n, sid in enumerate(ids, 1):
        if sid != f"sfx_{n:04d}":
            problems.append(f"第 {n} 行的 id 应是 sfx_{n:04d}，是 {sid}"); break
    if len(set(sources)) != len(sources):
        problems.append("来源有重复")
    for r in rows:
        for key in ("title_en", "title_zh"):
            if not r[key].strip():
                problems.append(f"{r['id']} 缺 {key}")
        if r["provenance"] not in PROVENANCE:
            problems.append(f"{r['id']} 的来源方 {r['provenance']!r} 不认识")
        tags = [t for t in r["tags"].split(",") if t]
        if not tags:
            problems.append(f"{r['id']} 没有 tag")
        for t in tags:
            if t not in ALL_TAGS:
                problems.append(f"{r['id']} 的 tag {t!r} 不在词表里")
        if not any(ALL_TAGS.get(t, ("", "", ""))[2] == "type" for t in tags):
            problems.append(f"{r['id']} 没有种类（type）tag")
    for sid, tag in SFX_TAGS.items():
        if sid in TAGS:
            problems.append(f"tag {sid!r} 在音乐词表里已经有了")
    return problems


def intensity(lufs):
    """1–5：峰值都在 -1 dBFS 时，整段响度越高 = 越满、越冲。"""
    if lufs is None:
        return 3
    return 5 if lufs >= -12 else 4 if lufs >= -16 else 3 if lufs >= -20 else 2 if lufs >= -26 else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("catalog")
    ap.add_argument("normdir", nargs="?")
    ap.add_argument("out", nargs="?")
    ap.add_argument("--base", default="https://downloads.skylu.ai/Audio")
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    rows = list(csv.DictReader(open(args.catalog, encoding="utf-8"), delimiter="\t"))
    problems = check_catalog(rows)
    for p in problems:
        print(f"  ✗ {p}", file=sys.stderr)
    if args.check:
        print(f"目录 {len(rows)} 条，{'有 %d 处毛病' % len(problems) if problems else '没毛病'}", file=sys.stderr)
        sys.exit(1 if problems else 0)
    if problems:
        sys.exit(1)
    if not args.normdir or not args.out:
        ap.error("要产物目录和输出路径")

    records = json.load(open(os.path.join(args.normdir, "_sfx_normalize.json")))
    items, missing = [], []
    for r in rows:
        rec = records.get(r["id"])
        if not rec or not os.path.exists(os.path.join(args.normdir, f"{r['id']}.m4a")):
            missing.append(r["id"]); continue
        tags = [t for t in r["tags"].split(",") if t]
        items.append({
            "id": r["id"],
            "kind": "sfx",
            "title": r["title_en"].strip(),
            "title_zh": r["title_zh"].strip(),
            "artist": "",
            "album": "",
            "duration": rec["duration"],
            "size": rec["size"],
            "url": f"{args.base}/SoundEffects/{r['id']}.m4a",
            "cover": None,
            "loudness": rec["loudness"],
            "peak_limited": False,
            "has_vocals": False,
            "intensity": intensity(rec["loudness"]),
            "hit": rec["hit"],
            "tags": [{"zh": ALL_TAGS[t][0], "en": ALL_TAGS[t][1], "group": ALL_TAGS[t][2]} for t in tags],
            "provenance": r["provenance"],
            "license": dict(LICENSE),
        })
    manifest = {"manifest_version": 1, "kind": "sfx",
                "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "items": items}
    json.dump(manifest, open(args.out, "w"), ensure_ascii=False, indent=1)
    print(f"manifest：{len(items)} 条 → {args.out}", file=sys.stderr)
    for sid in missing:
        print(f"  − {sid}: 没有规格化记录或产物", file=sys.stderr)
    sys.exit(1 if missing else 0)


if __name__ == "__main__":
    main()
