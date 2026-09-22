#!/usr/bin/env python3
"""从 MTG-Jamendo 元数据里选出 SrtFlow 音乐库的候选曲目。

只收 CC-BY（理由见 docs/plans/2026-09-22-audio-library.md 第十节）。
输出 TSV 到 stdout：track_id / duration / genres / moods / instruments / title / artist / album / url
"""
import re, sys, collections, argparse

# 配乐类 genre：命中其一才收
SCORE = {"soundtrack", "score", "ambient", "classical", "orchestral", "atmospheric",
         "darkambient", "newage", "minimal", "cinematic", "filmscore"}
# 歌曲类 genre：命中其一就排除（这些几乎必然有人声或不适合垫底）
SONG = {"pop", "rock", "folk", "hiphop", "jazz", "metal", "blues", "reggae", "rap",
        "country", "songwriter", "punk", "funk", "soul", "rnb", "disco", "dance",
        "house", "techno", "trance", "dubstep", "drumnbass", "hardrock", "indie",
        "alternative", "electropop", "rocknroll", "ska", "latin", "world"}
# 情绪 / 场景：能白捡的部分
MOOD_KEEP = {"film", "epic", "dark", "sad", "emotional", "melancholic", "documentary",
             "soundscape", "adventure", "space", "dream", "drama", "trailer",
             "mysterious", "meditative", "deep", "calm", "slow", "nature", "relaxing",
             "background", "inspiring", "hopeful", "sport", "travel", "game"}
# 曲名里出现这些词的排除：多半是歌或不适合
TITLE_BAN = re.compile(r"\b(feat|remix|vocal|song|cover|live|demo|intro\s*chiante)\b", re.I)


def load_licenses(path):
    """audio_licenses.txt 每条：路径行 → 署名行 → license 行（行数不固定，用状态机）。"""
    lic, attrib, cur = {}, {}, None
    path_re = re.compile(r"^(\d+)/(\d+)\.mp3\s*$")
    for line in open(path, encoding="utf-8", errors="replace"):
        if (m := path_re.match(line)):
            cur = int(m.group(2))
        elif cur is not None:
            if (l := re.search(r"creativecommons\.org/(?:licenses|publicdomain)/([a-z0-9.-]+?)/", line)):
                lic.setdefault(cur, l.group(1))
            elif " by " in line and "Jamendo" in line:
                attrib.setdefault(cur, line.strip())
    return lic, attrib


def load_meta(path):
    meta = {}
    for line in open(path, encoding="utf-8").read().splitlines()[1:]:
        f = line.split("\t")
        if len(f) >= 8:
            meta[int(f[0].split("_")[1])] = dict(title=f[3], artist=f[4], album=f[5],
                                                 released=f[6], url=f[7])
    return meta


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("data_dir", help="放 MTG-Jamendo 元数据的目录（见 fetch-metadata.sh）")
    ap.add_argument("--per-artist", type=int, default=2)
    ap.add_argument("--min-dur", type=float, default=45)
    ap.add_argument("--max-dur", type=float, default=360)
    args = ap.parse_args()

    SP = args.data_dir
    lic, attrib = load_licenses(f"{SP}/audio_licenses.txt")
    meta = load_meta(f"{SP}/raw.meta.tsv")

    rows, stage = [], collections.Counter()
    for r in open(f"{SP}/raw.tsv", encoding="utf-8").read().splitlines()[1:]:
        f = r.split("\t")
        if len(f) < 6:
            continue
        tid, aid, dur = int(f[0].split("_")[1]), f[1], float(f[4])
        tags = [t for t in f[5:] if "---" in t]
        g = {t.split("---")[1].strip() for t in tags if t.startswith("genre---")}
        i = {t.split("---")[1].strip() for t in tags if t.startswith("instrument---")}
        m = {t.split("---")[1].strip() for t in tags if t.startswith("mood/theme---")}

        stage["① 总曲目"] += 1
        if lic.get(tid) != "by":
            continue
        stage["② CC-BY"] += 1
        if not (g & SCORE):
            continue
        stage["③ 配乐类 genre"] += 1
        if g & SONG:
            continue
        stage["④ 非歌曲类"] += 1
        if i & {"voice", "choirs", "singing"}:
            continue
        stage["⑤ 未标人声"] += 1
        if not (args.min_dur <= dur <= args.max_dur):
            continue
        stage["⑥ 时长合格"] += 1
        md = meta.get(tid)
        if not md or TITLE_BAN.search(md["title"]):
            continue
        stage["⑦ 曲名过滤"] += 1
        rows.append((tid, aid, dur, sorted(g & SCORE), sorted(m & MOOD_KEEP), sorted(i), md))

    # 每位艺人限量，并优先保留有 mood 标注、genre 更贴配乐的
    rows.sort(key=lambda r: (-len(r[4]), -len({"soundtrack", "score", "cinematic"} & set(r[3])), r[0]))
    seen, picked = collections.Counter(), []
    for r in rows:
        if seen[r[1]] < args.per_artist:
            seen[r[1]] += 1
            picked.append(r)
    stage[f"⑧ 每艺人≤{args.per_artist}"] = len(picked)

    for k, v in stage.items():
        print(f"# {k:<16} {v:>7,}", file=sys.stderr)
    print(f"# 艺人数 {len(seen)}", file=sys.stderr)

    print("track_id\tduration\tgenres\tmoods\tinstruments\ttitle\tartist\talbum\turl\tattribution")
    for tid, aid, dur, g, m, i, md in sorted(picked, key=lambda r: r[0]):
        print("\t".join([str(tid), f"{dur:.1f}", ",".join(g), ",".join(m), ",".join(i[:6]),
                         md["title"], md["artist"], md["album"], md["url"],
                         attrib.get(tid, "")]))


if __name__ == "__main__":
    main()
