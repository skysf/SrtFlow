# 2026-09-23 CI 上源文件清单守卫报「缺文件」，其实不缺：pipefail 下 `grep -q` 的 SIGPIPE 假红

## 症状

PR #63 的 CI（run 35862607561）只红了一项。`check-script-source-lists` 报：
「scripts/check-clip-animation.sh 的源文件清单缺 Sources/SrtFlow/VideoEditFadeWindow.swift」。

- 这个文件就在那份清单的第 50 行。同一次 CI 里 check-clip-animation 自己编译、运行都过了。
- 日志里紧挨着那句的是 `checks/check-script-source-lists.sh: line 121: printf: write error: Broken pipe`。
- 本地同一份代码跑 check-all，32 项全绿。上一次 CI（run 35840307187，head 1f80bd1）也是绿的，
  两次之间所有自检脚本的源文件清单一字没变。

## 根因

第 121 行是 `printf '%s\n' "$LISTED" | grep -qx "$companion" || fail "…缺…"`，脚本开着
`set -o pipefail`：

1. `grep -q` 读到第一处匹配就退出。
2. printf 要是还没写完，下一次 write 就吃 SIGPIPE（bash 的 printf 报
   "write error: Broken pipe"），以非零退出。
3. pipefail 取管道里最后一个非零的退出码，整条管道判失败，`|| fail` 就把「命中了」报成了「缺」。

会不会红，看两个进程谁先跑完：

- **内容比管道缓冲（64KB）大时，每次必红。** 实测 264KB 的清单，匹配第一行，在 bash 5.3 和
  macOS 自带的 bash 3.2 上都是 200 次假红 200 次；here-string 写法 0 次。
- 清单只有 1.5KB 时，本地跑 5000 次一次都没红。这条守卫一次运行要做约 5000 次这种判断
  （每个脚本 × 清单里每个文件 × 它的每个同伴）。CI 虚机的调度和本地不一样，偶尔撞上一次就红了。

**仓库以前就踩过这个坑，但只修了一个地方。** 2026-09-21 `checks/transition-handles-wiring.sh`
里写下了「一律用 `grep -c`，不要用 `grep -q` …时灵时不灵」。这条教训没有升格成全仓库的规矩，
也没有检查，别的脚本照写不误：开着 pipefail 的脚本里一共有 111 处管道接 `grep -q`，
`timeline-drag-wiring.sh` 一个文件就占 98 处。

## 修复

- 111 处全部改掉，分两种写法：
  - **查一个变量里有没有**（97 处）：`printf '%s\n' "$X" | grep -q 'y'` 改成
    `grep -q 'y' <<<"$X"`。here-string 没有管道，bash 先把内容写完再跑 grep。
  - **查一条管道的输出**（14 处，上游是 `grep -v`、`awk` 或函数）：末端的 `grep -q` 改成
    `grep -c … >/dev/null`。`-c` 会把输入读完，上游不会吃 SIGPIPE；退出码和 `-q` 一样，
    选中至少一行就是 0。
  - 其中一处直接删掉了：`timeline-drag-wiring.sh` 第 12 节有一行 `… | grep -qc 'geometry.offsetX'`，
    结果没人用。开着 `set -e`，没匹配时它会让脚本**不带任何提示**地退出。下一行才是带提示的
    真检查。
- 新守卫 `checks/shell-pipe-grep-q.sh`，已加进 `scripts/check-all.sh`：
  - 扫仓库里所有开着 pipefail 的 `.sh`，注释行除外；
  - 管道接的 `grep` 选项里带 `q`（含 `-qE`、`-vq`、`--quiet`）就红；
  - `|` 写在行尾、`grep -q` 在下一行开头的也查。

## 验证

- 压测（264KB 清单）：旧写法 200 次假红 200 次，here-string 0 次。bash 5.3 和 bash 3.2 结果一样。
- 新守卫：改之前扫出 111 处（红），改完 0 处（绿）。
  **反向验证**：往 `timeline-drag-wiring.sh` 里放回一处 `echo "$ANIM" | grep -q`，再临时加一个
  「`|` 在行尾、下一行 `grep -qE`」的脚本。两处都被点名，退出码 1；注释里写的不算。
  删掉 / 恢复后退出码 0。
- **改过写法的守卫仍然抓得到真问题**，没有改成永远绿。以下每项都改完后转红、恢复后转绿：
  - 从 `scripts/check-clip-animation.sh` 的清单里删掉 `VideoEditFadeWindow.swift`：
    check-script-source-lists 点名这个文件；
  - 把 `VideoEditView.swift` 里的 `setPixelsPerSecond(exp(` 改名（here-string 写法的一条）；
  - 把音量线视图换回老代码：`grep_code`（`grep -c . >/dev/null` 写法）两条，加上否定式
    `if … | grep -cE … >/dev/null; then fail` 一条，都红。
- 改过的 9 个守卫逐个跑，全绿。`scripts/check-all.sh` 全绿（33 项）。
  `scripts/vendor-ffmpeg.sh` 不在 check-all 里，只跑了 `bash -n`。
- 耗时不变：check-script-source-lists 本地改前 37s，改后 36s。

## 教训 / 防回归

1. **pipefail 下，管道末端不许用 `grep -q`。** 它提前退出，上游吃 SIGPIPE，整条管道判失败：
   命中了反而报没命中。这不只是「偶尔」：内容一超过管道缓冲，就每次都红。长期规矩写进
   [shell 陷阱](2026-08-06-build-version-and-shell-traps.md)的「陷阱 4」，由 `checks/shell-pipe-grep-q.sh` 钉住。
2. **在一个脚本里学到的 shell 教训，要当场升格成全仓库的检查。** transition-handles-wiring.sh
   那句「一律用 grep -c」只管住了它自己，别处同样的写法有 111 处。
3. **遇到「本地绿、CI 红、清单里明明有」，先怀疑检查本身**，看日志里有没有 `Broken pipe`。
