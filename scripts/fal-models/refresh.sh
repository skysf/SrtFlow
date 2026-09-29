#!/usr/bin/env bash
# fal.ai 预设模型的维护工具（要联网，不在 check-all 里）：重下接口定义快照、列各类最新的模型、核对价格。
# 说明见 refresh.py 开头和 docs/architecture/fal-generation.md「预设怎么选、怎么更新」。
set -euo pipefail
exec python3 "$(dirname "$0")/refresh.py" "$@"
