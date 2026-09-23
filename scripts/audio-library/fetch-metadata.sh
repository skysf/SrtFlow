#!/usr/bin/env bash
# 下 MTG-Jamendo 数据集的元数据（约 18MB，纯文本，**不进 git**）。
#
# 这三份文件是整条素材管线的地基：
#
#   raw.tsv            56,639 首的 genre / instrument / mood-theme 标签
#   raw.meta.tsv       曲名 / 艺人 / 专辑 / 发行日 / Jamendo 链接
#   audio_licenses.txt 每一首的授权与现成的署名句
#
# **不需要任何 API key 或账号** —— 这是 UPF 音乐科技组公开发布的研究数据集。
# 授权政策（只收 CC-BY）和筛选管线见
# docs/build/audio-library-pipeline.md 与 docs/plans/2026-09-22-audio-library.md。
#
# 用法：
#   scripts/audio-library/fetch-metadata.sh <输出目录>
set -euo pipefail

OUT="${1:?用法: fetch-metadata.sh <输出目录>}"
BASE="https://raw.githubusercontent.com/MTG/mtg-jamendo-dataset/master"
mkdir -p "$OUT"

for f in data/raw.tsv data/raw.meta.tsv audio_licenses.txt; do
  name="$(basename "$f")"
  if [ -s "$OUT/$name" ]; then
    echo "  已有 ${name}（$(wc -c <"$OUT/$name" | tr -d ' ') 字节），跳过"
    continue
  fi
  echo "  下载 $name …"
  # 失败必须炸出来：半截的元数据会让选曲静默少一批，而那种错在 manifest 里
  # 看不出来（只是"这次挑出来的少一点"）。
  curl -fsSL --retry 3 -o "$OUT/$name.part" "$BASE/$f"
  mv "$OUT/$name.part" "$OUT/$name"
done

echo "元数据就绪 → $OUT"
