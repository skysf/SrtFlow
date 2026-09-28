#!/usr/bin/env python3
"""把本机配音模型（Kokoro-82M 的 CoreML 版）整理成要传到 R2 的样子，并生成清单 manifest.json。

来源（钉死版本，换版本就换 R2 上的文件夹 v2，已经装好的用户不受影响）：
  - 模型：huggingface.co/aufklarer/Kokoro-82M-CoreML @ f8ff771e4cab0bb3368e8af3a090a7e847485401（Apache-2.0，
    权重来自 hexgrad/Kokoro-82M，Apache-2.0）
  - 法、葡、印地的词典 dict_*.json：github.com/soniqo/speech-swift @ e345dbf95e7bb6c7b51d3f06175360188fa33d1e
    的 Sources/KokoroTTS/Resources（Apache-2.0；词条来自 open-dict-data/ipa-dict，MIT）

用法：
  scripts/voice-models/prepare-kokoro.py --model <下好的模型目录> --dicts <dict_*.json 所在目录> --out <整理好的目录>

只拷 App 用得到的文件（主模型 kokoro_5s、英语补拼写的两个小模型、词表、词典、54 个音色），外加一份 NOTICE.md（署名）。
清单里每个文件：相对路径、大小、SHA-256；App 下载完逐个核对（Sources/SrtFlow/KokoroVoiceManifest.swift 读它）。
长期约束见 docs/build/voice-model-pipeline.md。
"""
import argparse
import hashlib
import json
import os
import shutil
import sys

MODEL_SOURCE = "huggingface.co/aufklarer/Kokoro-82M-CoreML@f8ff771e4cab0bb3368e8af3a090a7e847485401"
DICT_SOURCE = "github.com/soniqo/speech-swift@e345dbf95e7bb6c7b51d3f06175360188fa33d1e:Sources/KokoroTTS/Resources"

MODEL_DIRS = ["kokoro_5s.mlmodelc", "G2PEncoder.mlmodelc", "G2PDecoder.mlmodelc", "voices"]
MODEL_FILES = ["vocab_index.json", "g2p_vocab.json", "us_gold.json", "us_silver.json"]
DICT_FILES = ["dict_fr.json", "dict_pt.json", "dict_hi.json"]

NOTICE = """# SrtFlow voices (Kokoro-82M, CoreML)

- Model weights: Kokoro-82M by hexgrad — https://huggingface.co/hexgrad/Kokoro-82M — Apache License 2.0.
- CoreML conversion: https://huggingface.co/aufklarer/Kokoro-82M-CoreML — Apache License 2.0.
- French, Portuguese and Hindi pronunciation dictionaries: speech-swift (https://github.com/soniqo/speech-swift),
  Apache License 2.0; entries from ipa-dict (https://github.com/open-dict-data/ipa-dict), MIT License.

Apache License 2.0: https://www.apache.org/licenses/LICENSE-2.0
"""


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--dicts", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    if os.path.exists(args.out):
        shutil.rmtree(args.out)
    os.makedirs(args.out)
    for name in MODEL_DIRS:
        source = os.path.join(args.model, name)
        if not os.path.isdir(source):
            sys.exit(f"✗ 模型目录里没有 {name}")
        shutil.copytree(source, os.path.join(args.out, name))
    for name in MODEL_FILES:
        shutil.copy2(os.path.join(args.model, name), os.path.join(args.out, name))
    for name in DICT_FILES:
        shutil.copy2(os.path.join(args.dicts, name), os.path.join(args.out, name))
    with open(os.path.join(args.out, "NOTICE.md"), "w", encoding="utf-8") as f:
        f.write(NOTICE)

    files = []
    for root, _, names in os.walk(args.out):
        for name in sorted(names):
            if name.startswith(".") or name == "manifest.json":
                continue
            path = os.path.join(root, name)
            rel = os.path.relpath(path, args.out).replace(os.sep, "/")
            files.append({"path": rel, "size": os.path.getsize(path), "sha256": sha256(path)})
    files.sort(key=lambda f: f["path"])
    voices = sum(1 for f in files if f["path"].startswith("voices/"))
    manifest = {"name": "Kokoro-82M-CoreML", "version": 1, "sources": [MODEL_SOURCE, DICT_SOURCE], "files": files}
    with open(os.path.join(args.out, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=1)
    total = sum(f["size"] for f in files)
    print(f"✓ {len(files)} 个文件（{voices} 个音色），共 {total / 1e6:.1f} MB → {args.out}/manifest.json")


if __name__ == "__main__":
    main()
