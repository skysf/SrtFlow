#!/usr/bin/env bash
# 音效目录 `scripts/audio-library/sfx-catalog.tsv` 是音效清单的源头（docs/build/audio-library-pipeline.md 第八节）：
# id 唯一且从 sfx_0001 连号（**id 永不改**：工程文件存的就是它，撞车或改号 = 老工程失链）、来源文件唯一、中英标题都有、
# 每条至少一个种类（type）tag、tag 都在词表里（音乐的 TAGS + 音效的 SFX_TAGS，两张表不许重名）、来源方只认
# elevenlabs / purchased。目录改坏了不会当场炸，要到下次扩库合清单时才把库合错，所以提交前钉住。
set -euo pipefail
cd "$(dirname "$0")/.."

export PYTHONDONTWRITEBYTECODE=1
python3 scripts/audio-library/sfx_build_manifest.py scripts/audio-library/sfx-catalog.tsv --check
echo "✓ sfx-catalog：音效目录没毛病"
