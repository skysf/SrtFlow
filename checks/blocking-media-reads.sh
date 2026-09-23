#!/usr/bin/env bash
# 扫描守卫：循环调 `copyNextSampleBuffer()` 的阻塞读取，不许写在 async 函数里。
#
# async 函数跑在 Swift 并发的协作线程池上：每个 QoS 只有「CPU 核数」条线程，堵住的
# 不补。`copyNextSampleBuffer()` 会卡住线程等 CoreMedia 解码，而 CoreMedia 那份活要在
# 同一档 QoS 上分线程 —— 同时读的文件一凑满核数就死锁，整档 QoS 从此什么都不跑。
# 2026-09-23 打开 43 个素材的工程，波形和缩略图全空，就是它
# （docs/bugfixes/2026-09-23-waveform-decode-deadlocks-thread-pool.md）。
#
# 正确写法（docs/architecture/blocking-media-reads.md）：`loadTracks` 这类异步加载留在
# async 函数里做完，读采样的循环写成**单独的同步函数**，交给 `MediaReadQueue` 去跑。
#
# 判据：每一处 `copyNextSampleBuffer`，往上找离它最近的 `func` 声明（签名可以跨行，
# 读到 `{` 为止），签名里带 `async` 就红。已知的盲区：同步函数里再包一层
# `Task { … }` / `Task.detached` 把循环塞进线程池，这里看不出来 —— 那种写法的真实
# 后果由 `scripts/check-waveform.sh` 第 7 节（很多文件同时读）按行为兜着，但只兜波形
# 这两处；新的读取别这么写。
#
# 用法：checks/blocking-media-reads.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# 例外（每一条都要写清为什么不会凑满线程池）：
# - 字幕生成按窗口抽音频：严格一个窗口一个窗口地读（TranscriptionTask 里的 for 循环），
#   同一时刻最多卡住一条线程，凑不满。哪天要并行抽，先挪到 MediaReadQueue。
ALLOWED="Sources/SrtFlow/SubtitleGen/AudioWindowReader.swift"

is_allowed() { # is_allowed <文件>
  local allowed
  for allowed in ${ALLOWED}; do
    if [ "$1" = "${allowed}" ]; then return 0; fi
  done
  return 1
}

# 判据是一段 perl，放在带引号的 heredoc 里：一个字都不经 shell 展开，文件名用 perl 自己的
# `$ARGV`。别改回「`$( … )` 里套 case、再套单引号」的写法 —— macOS 自带的 /bin/bash 3.2
# （CI 用的就是它）会把 case 模式的 `)` 当成命令替换的结尾，后面的引号全部错位，perl 里的
# 变量被 shell 展开，`set -u` 当场报 unbound variable。本机 PATH 上是 Homebrew 的 bash 5.3，
# 一声不吭（2026-09-23 CI 首跑就这么红的）。
read -r -d '' SCAN <<'PERL' || true
BEGIN { $sig = ""; $sigline = 0; $open = 0 }
next if /^\s*\/\//;
if (/\bfunc\b/) { $sig = $_; $sigline = $.; $open = !/\{/; }
elsif ($open) { $sig .= $_; $open = 0 if /\{/; }
if (/copyNextSampleBuffer/ && $sig =~ /\basync\b/) {
  (my $head = $sig) =~ s/\s+/ /g;
  printf "%s:%d（在第 %d 行的 async 函数里：%s）\n", $ARGV, $., $sigline, $head;
}
PERL

HITS=""
while IFS= read -r file; do
  if is_allowed "${file}"; then continue; fi
  found="$(perl -ne "${SCAN}" "${file}")"
  if [ -n "${found}" ]; then
    HITS="${HITS}${found}
"
  fi
done < <(find Sources -name '*.swift' | LC_ALL=C sort)

if [ -n "${HITS}" ]; then
  echo "✗ 这些阻塞读取写在了 async 函数里（会占住 Swift 并发线程池的线程，文件一多整档 QoS 死锁）：" >&2
  printf '%s' "${HITS}" >&2
  echo "  读采样的循环写成单独的同步函数，交给 MediaReadQueue 跑；见 docs/architecture/blocking-media-reads.md" >&2
  exit 1
fi
echo "✓ blocking-media-reads：没有写在 async 函数里的 copyNextSampleBuffer 循环"
