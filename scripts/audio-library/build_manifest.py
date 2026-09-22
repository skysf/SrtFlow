#!/usr/bin/env python3
"""把候选清单 + 规格化结果 + 声学特征合成 `Audio/manifest.json`。

tags 分四组，来源各不相同（诚实标注，见 docs/plans/2026-09-22-audio-library.md）：

| 组 | 来源 | 可靠度 |
|---|---|---|
| texture 质感 | genre / instrument 标签 | 白捡，艺人自己标的 |
| mood 情绪 | mood 标签优先，没有就从声学特征推 | 标签可靠，推的是启发式 |
| scene 场景 | mood 标签 + 时长 + 包络形状 | 启发式 |
| intensity 强度 | 响度 p90 + 起伏，1–5 | 算出来的 |

**双语放在数据里，不进 Localizable.strings** —— tag 会随 manifest 增长，
不该每加一个就发一次 App 版本（plan 第四节第 3 条）。
"""
import sys, os, json, re, csv, argparse, hashlib

# ── tag 词表：id → (zh, en, group)。加 tag 只动这张表。
TAGS = {
    # texture
    "ambient":    ("环境",   "ambient",    "texture"),
    "orchestral": ("管弦",   "orchestral", "texture"),
    "piano":      ("钢琴",   "piano",      "texture"),
    "strings":    ("弦乐",   "strings",    "texture"),
    "synth":      ("合成器", "synth",      "texture"),
    "guitar":     ("吉他",   "guitar",     "texture"),
    "choir":      ("人声吟唱", "choir",    "texture"),
    "percussion": ("打击乐", "percussion", "texture"),
    "score":      ("配乐",   "score",      "texture"),
    "classical":  ("古典",   "classical",  "texture"),
    "electronic": ("电子",   "electronic", "texture"),
    # mood
    "dark":       ("黑暗",   "dark",       "mood"),
    "sad":        ("悲伤",   "sad",        "mood"),
    "epic":       ("宏大",   "epic",       "mood"),
    "emotional":  ("动情",   "emotional",  "mood"),
    "calm":       ("平静",   "calm",       "mood"),
    "tense":      ("紧张",   "tense",      "mood"),
    "warm":       ("温暖",   "warm",       "mood"),
    "mysterious": ("神秘",   "mysterious", "mood"),
    "hopeful":    ("希望",   "hopeful",    "mood"),
    "melancholic":("忧郁",   "melancholic","mood"),
    "dreamy":     ("梦境",   "dreamy",     "mood"),
    "bright":     ("明亮",   "bright",     "mood"),
    "deep":       ("低沉",   "deep",       "mood"),
    # scene
    "opening":    ("开场",   "opening",    "scene"),
    "ending":     ("片尾",   "ending",     "scene"),
    "background": ("垫底",   "background", "scene"),
    "buildup":    ("渐强",   "buildup",    "scene"),
    "trailer":    ("预告",   "trailer",    "scene"),
    "documentary":("纪录片", "documentary","scene"),
    "memory":     ("回忆",   "memory",     "scene"),
    "space":      ("太空",   "space",      "scene"),
    "nature":     ("自然",   "nature",     "scene"),
    "adventure":  ("冒险",   "adventure",  "scene"),
    "drama":      ("剧情",   "drama",      "scene"),
}

# 数据集 genre/instrument → 我们的 texture tag
GENRE_MAP = {
    "ambient": "ambient", "darkambient": "ambient", "atmospheric": "ambient",
    "orchestral": "orchestral", "classical": "classical", "soundtrack": "score",
    "score": "score", "cinematic": "score", "newage": "ambient", "minimal": "ambient",
}
INSTR_MAP = {
    "piano": "piano", "electricpiano": "piano", "strings": "strings",
    "violin": "strings", "cello": "strings", "synthesizer": "synth",
    "computer": "electronic", "drummachine": "electronic", "guitar": "guitar",
    "acousticguitar": "guitar", "electricguitar": "guitar", "classicalguitar": "guitar",
    "drum": "percussion", "drums": "percussion", "percussion": "percussion",
    "choirs": "choir", "orchestra": "orchestral", "flute": "strings",
}
# 数据集 mood/theme → 我们的 mood/scene tag
MOOD_MAP = {
    "dark": "dark", "sad": "sad", "epic": "epic", "emotional": "emotional",
    "melancholic": "melancholic", "calm": "calm", "relaxing": "calm",
    "meditative": "calm", "dream": "dreamy", "deep": "deep", "hopeful": "hopeful",
    "inspiring": "hopeful", "mysterious": "mysterious", "soundscape": "ambient",
    "film": "drama", "documentary": "documentary", "trailer": "trailer",
    "adventure": "adventure", "space": "space", "nature": "nature",
    "background": "background", "drama": "drama", "slow": "calm", "game": "adventure",
}
# 曲名语义（英 / 西 / 法 / 德，Jamendo 艺人多在欧洲）
TITLE_HINTS = [
    (r"\b(dark|noir|shadow|night|nuit|oscur|schwarz|black|abyss|void)\w*", "dark"),
    (r"\b(sad|elegy|elegia|requiem|lament|triste|sorrow|tear|farewell|adieu)\w*", "sad"),
    (r"\b(epic|epico|battle|batalla|war|guerra|hero|heroic|titan|rise)\w*", "epic"),
    (r"\b(dream|sueno|sueño|reve|rêve|traum|sleep|lullab)\w*", "dreamy"),
    (r"\b(space|cosmos|cosmic|stellar|orbit|galaxy|nebula|planet|lunar|moon)\w*", "space"),
    (r"\b(rain|storm|wind|forest|ocean|sea|river|mountain|nature|earth)\w*", "nature"),
    (r"\b(memory|memoria|souvenir|remember|nostalg|past|yesterday)\w*", "memory"),
    (r"\b(hope|esperanza|espoir|dawn|sunrise|light|luz|lumiere)\w*", "hopeful"),
    (r"\b(tension|suspense|danger|chase|alarm|threat|fear|miedo)\w*", "tense"),
    (r"\b(warm|home|heart|corazon|amour|gentle|soft|tender)\w*", "warm"),
]


def infer(feat, moods, genres, instrs, title, dur):
    """推 tags。有标签的优先用标签，没有的用声学特征 + 曲名。返回 (tag_ids, 依据)。"""
    tags, why = set(), {}

    for g in genres:
        if (t := GENRE_MAP.get(g)):
            tags.add(t); why.setdefault(t, "genre")
    for i in instrs:
        if (t := INSTR_MAP.get(i)):
            tags.add(t); why.setdefault(t, "instrument")
    for m in moods:
        if (t := MOOD_MAP.get(m)):
            tags.add(t); why.setdefault(t, "mood-tag")

    low = title.lower()
    for pat, t in TITLE_HINTS:
        if re.search(pat, low):
            tags.add(t); why.setdefault(t, "title")

    # ── 声学特征补位（只在该组还空着时才推，别和艺人自己的标签抢）
    c, swing, slope = feat.get("centroid_hz"), feat["swing"], feat["slope_db_per_min"]
    has_mood = any(TAGS[t][2] == "mood" for t in tags)
    if c is not None and not has_mood:
        # **一定要给出一个情绪**：情绪是用户翻库时最先用的筛选维度，没有这一组
        # 的素材等于藏起来了。按频谱重心分三档兜底 —— 中间档给「平静」，那是
        # 器乐配乐最常见的落点，也是最不会误导的一个。
        if c < 1100:
            tags.add("deep"); why.setdefault("deep", f"频谱重心 {c}Hz（低）")
        elif c > 2400:
            tags.add("bright"); why.setdefault("bright", f"频谱重心 {c}Hz（高）")
        else:
            tags.add("calm"); why.setdefault("calm", f"频谱重心 {c}Hz（中），兜底")
    if swing >= 11:
        tags.add("drama"); why.setdefault("drama", f"起伏 {swing}dB")
    elif swing <= 5 and dur >= 100:
        tags.add("background"); why.setdefault("background", f"起伏仅 {swing}dB")
    if slope >= 2.0 and feat["head_vs_tail"] >= 3.0:
        tags.add("buildup"); why.setdefault("buildup", f"斜率 +{slope}dB/min")
    if dur <= 100 and slope >= 0:
        tags.add("opening"); why.setdefault("opening", f"{dur:.0f}s 且不衰减")
    if feat["silence_tail"] >= 1.5:
        tags.add("ending"); why.setdefault("ending", f"尾部静音 {feat['silence_tail']}s")
    return sorted(tags), why


def intensity(feat):
    """1–5。响度高且起伏大 = 强。"""
    p90, swing = feat["loud_p90"], feat["swing"]
    s = 0
    s += 2 if p90 >= -12 else 1 if p90 >= -18 else 0
    s += 2 if swing >= 12 else 1 if swing >= 6 else 0
    return min(5, max(1, s + 1))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("candidates"); ap.add_argument("normdir")
    ap.add_argument("features"); ap.add_argument("out")
    ap.add_argument("--base", default="https://downloads.skylu.ai/Audio")
    ap.add_argument("--limit", type=int, default=0)
    args = ap.parse_args()

    cand = {r["track_id"]: r for r in csv.DictReader(open(args.candidates, encoding="utf-8"), delimiter="\t")}
    feats = json.load(open(args.features))
    norms = {r["track_id"]: r for r in json.load(open(os.path.join(args.normdir, "_normalize.json")))}

    items, skipped = [], []
    for tid in sorted(feats, key=int):
        c, f, nz = cand.get(tid), feats[tid], norms.get(tid)
        if not c or not nz:
            skipped.append((tid, "缺候选或规格化记录")); continue
        m4a = os.path.join(args.normdir, f"{tid}.m4a")
        if not os.path.exists(m4a):
            skipped.append((tid, "产物不存在")); continue

        moods = [x for x in c["moods"].split(",") if x]
        genres = [x for x in c["genres"].split(",") if x]
        instrs = [x for x in c["instruments"].split(",") if x]
        ids, why = infer(f, moods, genres, instrs, c["title"], f["duration"])
        if not any(TAGS[t][2] == "mood" for t in ids):
            skipped.append((tid, "推不出任何情绪 tag")); continue

        items.append({
            "id": f"mus_{tid}",
            "kind": "music",
            "title": c["title"].strip(),
            "artist": c["artist"].strip(),
            "album": c["album"].strip(),
            "duration": round(f["duration"], 2),
            "size": nz["size"],
            "url": f"{args.base}/Music/mus_{tid}.m4a",
            "cover": f"{args.base}/Music/covers/mus_{tid}.jpg" if nz["cover"] else None,
            "loudness": nz["measured_out"],
            "peak_limited": nz["peak_limited"],
            "has_vocals": False,
            "intensity": intensity(f),
            "tags": [{"zh": TAGS[t][0], "en": TAGS[t][1], "group": TAGS[t][2]} for t in ids],
            "license": {
                "code": "CC-BY-3.0",
                "by": c["artist"].strip(),
                "src": c["url"].strip(),
                "text": c["attribution"].strip(),
            },
            "_why": why,          # 只用于人工复核，发布前剥掉
        })
        if args.limit and len(items) >= args.limit:
            break

    manifest = {"manifest_version": 1, "kind": "music",
                "generated_at": __import__("datetime").datetime.now(
                    __import__("datetime").timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "items": items}
    json.dump(manifest, open(args.out, "w"), ensure_ascii=False, indent=1)

    print(f"manifest：{len(items)} 首 → {args.out}", file=sys.stderr)
    for tid, r in skipped:
        print(f"  − {tid}: {r}", file=sys.stderr)
    groups = {}
    for it in items:
        for t in it["tags"]:
            groups.setdefault(t["group"], set()).add(t["zh"])
    for g in ("texture", "mood", "scene"):
        print(f"  {g}: {' '.join(sorted(groups.get(g, [])))}", file=sys.stderr)


if __name__ == "__main__":
    main()
