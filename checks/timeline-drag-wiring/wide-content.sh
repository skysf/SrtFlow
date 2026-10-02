#!/usr/bin/env bash
# checks/timeline-drag-wiring.sh 的一节：超宽内容（2026-09-23 深度缩放）—— Canvas 只画可见的那一段、波形按文件读一次。
#
# **不单独跑**：由 timeline-drag-wiring.sh 用 `source` 装进来，共用它的 fail / grep_code 和路径变量
#（WAVEFORM / RULER / THUMBS）。2026-10-02 从主文件搬出来的（主文件在行数基线上只许降不许涨）。

# ── 超宽内容：Canvas 只画可见的那一段（2026-09-23 深度缩放） ──────────
# 放大到 4800pt/秒之后，块和标尺能有几百万点宽。SwiftUI 的 Canvas 只光栅化可见条带，
# 却每滚 128pt 就把闭包**整宽**重跑一次：整宽画的话 10M 宽时一次 370ms、内存只涨不退
#（270 → 1080MB）。闭包里必须按 `context.clipBoundingRect` 裁到可见范围
#（docs/architecture/audio-waveform.md）。
grep_code 'context.clipBoundingRect' "$WAVEFORM" \
  || fail "波形没按 clipBoundingRect 裁到可见范围：放大后每滚一下都要把整段重画一遍"
grep_code 'context.clipBoundingRect' "$RULER" \
  || fail "标尺没按 clipBoundingRect 裁到可见范围：放大后每滚一下都要把整条刻度重算一遍"
grep_code 'context.clipBoundingRect' "$THUMBS" \
  || fail "缩略图没按可见范围铺格子：放大之后一张图会被拉成一万多点宽的横缝"
# 波形的数据按文件读一次（多级峰值），不许退回「每段按范围读成固定几百根柱子」——
# 那样放多大都是那几百根，放大只是把每根拉宽（用户报的「放到最大还是不够」）。
grep_code 'WaveformStore.shared.peaks(for:' "$WAVEFORM" \
  || fail "波形没走 WaveformStore（按文件读一次的多级峰值）"
