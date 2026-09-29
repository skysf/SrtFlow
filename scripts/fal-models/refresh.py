#!/usr/bin/env python3
"""fal.ai 预设模型的维护工具（不在 check-all 里：要联网）。

用户口径（2026-09-29）：预设只用当前**最新**的模型，太老的不要；视频只用 minimax/h3-max/ 这个系列。
fal 的目录天天在变，所以这里把「挑最新的」和「核对登记的东西没变」做成工具，别靠记忆：

  refresh.sh                重下每个登记端点的接口定义快照（checks/Fal/schemas/），说哪些变了
  refresh.sh --newest [N]   按上架日期列出各类最新的 N 个模型（默认 8；fal 公开的目录接口，不用 Key）
  refresh.sh --prices       抄每个登记端点在 fal.ai 页面上的价格那一句，和 Sources/SrtFlow/Fal/FalModels.swift 里登记的对一遍
  refresh.sh --all          三样都做

接口定义：https://fal.ai/api/openapi/queue/openapi.json?endpoint_id=<端点号>（公开）。
目录：https://api.fal.ai/v1/models（公开，分页，限速 429 时退避重试）。
价格：模型页 https://fal.ai/models/<端点号> 里渲染出来的「Your request will cost …」（没有公开的价格接口，那个要 Key）。
只用标准库（Rosetta 终端下 numpy 之类装不了，见 docs/build/）。
"""
import html
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MODELS = ROOT / "Sources/SrtFlow/Fal/FalModels.swift"
SCHEMAS = ROOT / "checks/Fal/schemas"
UA = {"User-Agent": "Mozilla/5.0"}
CATEGORIES = ["text-to-image", "text-to-video", "image-to-video", "text-to-speech", "text-to-audio", "audio-to-audio", "video-to-audio"]


def get(url: str, retries: int = 6) -> bytes:
    for attempt in range(retries):
        try:
            return urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60).read()
        except urllib.error.HTTPError as error:
            if error.code == 429 and attempt + 1 < retries:
                time.sleep(8 * (attempt + 1))
                continue
            raise
    raise RuntimeError(url)


def registered_endpoints() -> list[str]:
    return re.findall(r'endpoint: "([^"]+)"', MODELS.read_text(encoding="utf-8"))


def schemas() -> None:
    SCHEMAS.mkdir(parents=True, exist_ok=True)
    for endpoint in registered_endpoints():
        url = "https://fal.ai/api/openapi/queue/openapi.json?endpoint_id=" + urllib.parse.quote(endpoint, safe="/")
        spec = json.loads(get(url))
        text = json.dumps(spec, indent=1, sort_keys=True, ensure_ascii=False) + "\n"
        path = SCHEMAS / (endpoint.replace("/", "__") + ".json")
        old = path.read_text(encoding="utf-8") if path.exists() else None
        path.write_text(text, encoding="utf-8")
        print(f"{'unchanged' if old == text else 'CHANGED  ' if old else 'new      '}  {endpoint}")
        time.sleep(0.5)
    print("\n变了的接口定义要对一遍 Sources/SrtFlow/Fal/FalInputs.swift / FalOutputs.swift，再跑 scripts/check-fal.sh。")


def catalog() -> list[dict]:
    models, cursor = [], None
    while True:
        query = {"limit": "100"}
        if cursor:
            query["cursor"] = cursor
        data = json.loads(get("https://api.fal.ai/v1/models?" + urllib.parse.urlencode(query)))
        models += data.get("models", [])
        cursor = data.get("next_cursor")
        if not data.get("has_more") or not cursor:
            return models
        time.sleep(3)


def newest(count: int) -> None:
    registered = set(registered_endpoints())
    by_category: dict[str, list] = {}
    for model in catalog():
        meta = model["metadata"]
        if meta.get("status") == "active":
            by_category.setdefault(meta["category"], []).append((meta["date"][:10], model["endpoint_id"], meta["display_name"]))
    for category in CATEGORIES:
        print(f"\n## {category}")
        for date, endpoint, title in sorted(by_category.get(category, []), reverse=True)[:count]:
            print(f"  {date}  {'*' if endpoint in registered else ' '} {endpoint}  |  {title}")
    print("\n* = 已登记的预设。视频只用 minimax/h3-max/ 这个系列（用户 2026-09-29），别的类换最新的之前先看 docs/architecture/fal-generation.md「预设怎么选」。")


def prices() -> None:
    for endpoint in registered_endpoints():
        # 先去掉标签再找：渲染出来的价格常被标签切开（「$」「0.027」「per image」各在一个 span 里）。
        page = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", html.unescape(get("https://fal.ai/models/" + endpoint).decode("utf-8", "replace"))))
        sentences = []
        for match in re.finditer(r"(?:Your request will cost|Each voice clone request will cost|Video costs)[^\"\\]{0,170}", page):
            text = match.group(0).strip()
            if text not in sentences and len(text) > 30:
                sentences.append(text)
        print(f"\n{endpoint}")
        for text in sentences[:3]:
            print(f"   {text}")
        time.sleep(0.6)
    registry = MODELS.read_text(encoding="utf-8")
    print("\n登记的单价（FalModels.swift）：")
    for line in re.findall(r'unitPrice: [0-9.]+|"(?:480|768|1080)P": [0-9.]+', registry):
        print("   " + line)
    print("\n价格页上的话和登记的对不上就改登记、并把 docs/architecture/fal-generation.md 价格表的日期改成今天。")


def main(argv: list[str]) -> None:
    args = [a for a in argv if not a.startswith("--")]
    flags = {a for a in argv if a.startswith("--")}
    everything = "--all" in flags
    if everything or not flags:
        schemas()
    if everything or "--prices" in flags:
        prices()
    if everything or "--newest" in flags:
        newest(int(args[0]) if args else 8)


if __name__ == "__main__":
    main(sys.argv[1:])
