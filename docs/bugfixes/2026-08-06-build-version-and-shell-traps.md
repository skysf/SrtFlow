# 2026-08-06 打包脚本贴错版本号，修它时又踩中两个 shell 陷阱

## 症状

`dist/` 里躺着一个 `SrtFlow-0.3.0-arm64.dmg`，**文件时间是 8-03**，而 v0.3.0
是 7-30 发的；体积也和 GitHub 上 v0.3.0 的资产对不上：

| 文件 | 本地 | GitHub release 资产 |
|------|------|---------------------|
| `SrtFlow-0.3.0-arm64.dmg`（8-03 建） | 26056898 | 25520931 ← 不一致 |
| `SrtFlow-0.4.0-arm64.dmg`（8-05 建） | 26218228 | 25953144 ← 不一致 |
| `SrtFlow-0.4.1-arm64.dmg` | 26218240 | 26218240 ← 一致 |

也就是说：**本地有两个贴着旧版本号、内容却是别的版本的安装包**。这种包一旦发
出去，用户装上「0.3.0」得到的是完全不同的代码，报 bug 时版本号完全不可信。

## 根因

`scripts/build-app.sh` 里写死了默认版本号：

```bash
VERSION="${VERSION:-0.3.0}"
```

发布到 0.4.1 了，这行还停在 0.3.0。**不传 `VERSION=` 就静默打出 0.3.0 的包**，
没有任何提示。硬编码默认值必然随发布腐烂，而它腐烂时唯一的表现就是产物名字错
——不报错、不失败，最难发现的那种。

修这一处时，新写的版本兜底逻辑自己又踩中两个 bash 陷阱，都是先写完再测才抓到的：

**陷阱 1：裸 `$VAR` 紧跟中文，变量名会被多吃一个字节。**

```bash
echo "回退到最近的 tag v$VERSION，但 HEAD 已领先"   # ✗ unbound variable
```

bash 展开不带花括号的变量名时，会把后面多字节字符的**首字节**也算进名字里，
于是去找的是 `VERSION\xef` 而不是 `VERSION`；配上 `set -u` 当场退出。实测与
bash 版本、locale 都无关 —— bash 5.3 + `en_US.UTF-8` 一样中招：

```console
$ bash -c 'set -u; V=1.0; echo "v$V，尾"'
bash: line 1: V<ef>: unbound variable
$ bash -c 'set -u; V=1.0; echo "v${V}，尾"'
v1.0，尾
```

本仓库所有 `.sh` 的提示文案都是中文，这个陷阱在这里是**结构性**的。

**陷阱 2：`pipefail` 下赋值失败会绕开自己写的报错。**

```bash
VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')"
if [ -z "$VERSION" ]; then echo "✗ 友好提示"; exit 1; fi   # ✗ 永远走不到
```

管道的退出码在 `set -o pipefail` 下取的是 **git 的 128**（不是 sed 的 0），
`set -e` 于是在赋值那行就把脚本干掉了，退出码 128、没有任何提示。精心写的错误
分支成了死代码。

## 修复

`scripts/build-app.sh`：删掉硬编码默认值，改成**兜底取最近的 git tag**——它跟着
发布自动走，不会腐烂；同时在 HEAD 领先 tag 时明确警告这是开发版产物。

```bash
if [ -z "${VERSION:-}" ]; then
  # pipefail 下 git 失败会让整条赋值以 128 退出、走不到下面的报错，所以兜 || true
  VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
  if [ -z "${VERSION}" ]; then
    echo "✗ 未传 VERSION，也取不到 git tag（不在 git 仓库？）。" >&2
    echo "  请显式指定：VERSION=x.y.z $0" >&2
    exit 1
  fi
  AHEAD="$(git rev-list --count "v${VERSION}..HEAD" 2>/dev/null || echo 0)"
  if [ "${AHEAD}" -gt 0 ]; then
    echo "⚠️  未传 VERSION，回退到最近的 tag v${VERSION}，但 HEAD 已领先 ${AHEAD} 个提交。"
    echo "    这是开发版产物；正式发版请显式指定：VERSION=x.y.z $0"
  fi
fi
```

三个决定值得记：

- **不改成「必须传 VERSION」**：README 里两处写的就是无参 `scripts/build-app.sh`，
  改成强制会打断日常构建。兜底取 tag 既不腐烂又不打断。
- **兜底取 tag 而不是取「tag+1」之类**：猜下一个版本号只会造出另一种错标。
  取真实 tag + 明确说「你领先了 N 个提交」，把判断交还给人。
- **警告只在 HEAD 领先 tag 时出现**：正好在 tag 上构建是干净的复现场景，不该吵。

## 验证

版本解析那段单独抽出来跑三个用例（不必跑完整打包）：

```console
=== 用例1：不传 VERSION（HEAD 领先 tag）===
⚠️  未传 VERSION，回退到最近的 tag v0.4.1，但 HEAD 已领先 11 个提交。
    这是开发版产物；正式发版请显式指定：VERSION=x.y.z ...
RESOLVED=0.4.1
=== 用例2：显式传 VERSION=0.5.0 ===
RESOLVED=0.5.0
=== 用例3：不在 git 仓库 ===
✗ 未传 VERSION，也取不到 git tag（不在 git 仓库？）。
  请显式指定：VERSION=x.y.z ver.sh
退出码=1
```

回归面：拿陷阱 1 的正则扫了仓库全部 5 个 `.sh`，除本案例新增的注释举例外**没有
其他裸 `$VAR` 紧跟多字节字符**的地方：

```bash
git ls-files '*.sh' | while read -r f; do
  perl -ne 'print "'"$f"':$.: $_" if /\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F\s]/' "$f"
done
```

`bash -n scripts/build-app.sh` 通过。本地那两个错标的 DMG 已删（GitHub release
上的资产才是权威副本，两份都在）。

## 教训 / 防回归

1. **脚本里任何「会随发布变化的常量」都不能写死默认值。** 它腐烂时不报错，只是
   悄悄产出错的东西。要么从真实来源推导（git tag / 文件内容），要么显式失败。
2. **改 `.sh` 时，变量紧跟中文就用 `${VAR}`。** 这是本仓库的结构性陷阱（所有脚本
   都是中文提示），不是个别写法问题。上面那条 perl 正则可以直接拿来扫。
3. **`set -euo pipefail` 下，`VAR="$(a | b)"` 的退出码是整条管道的**，前半段失败
   会让脚本在赋值处就死掉、绕开后面精心写的错误分支。要保留自己的报错就补 `|| true`。
4. **写完 shell 一定要真跑一遍分支，别只 `bash -n`。** 这次两个陷阱语法全合法，
   `bash -n` 一声不吭，是执行三个用例才炸出来的。

## 复发：2026-09-23（陷阱 1 从「拿正则扫」升级成自动检查）

上面第 2 条教训写的是「上面那条 perl 正则可以直接拿来扫」—— 但一直是**人记得才扫**。
2026-09-23 一次扫出 5 处：

- `checks/timeline-drag-wiring.sh` 4 处，全在失败提示里（`（在 $FILE_DROP）`、
  `路由器不认 $t：`……）。这种行平时根本跑不到，一旦守卫真的触发，脚本先在
  `set -u` 上崩掉，打出来的是 `flagM-o: unbound variable` 而不是那句提示 —— 守卫是
  红了，红的原因却不对。是反向验证时看见「红了但没有 ✗ 那一行」才发现的
  （[案例](2026-09-23-in-app-drops-swallowed-by-file-underlay.md)）。
- `scripts/audio-library/fetch-metadata.sh` 1 处（`已有 $name（…）`）：素材元数据
  已经下过、再跑一次管线时，走到「跳过」那一行就崩。

同一次还踩了陷阱 3 的变体：`X="$(for f in …; do grep … | sed …; done)"`，最后一个
文件没匹配时 grep 退出码 1，`pipefail` 把整个命令替换判成失败，脚本在赋值处**静默**
退出 —— 连一行报错都没有。管道里的 grep 要自己兜 `|| true`。

**防回归**：`checks/shell-var-boundary.sh`（进了 `scripts/check-all.sh`）扫仓库里
全部 `.sh`（含还没提交的），注释行除外，裸 `$VAR` 紧跟多字节字符就红。反向验证：
把 `timeline-drag-wiring.sh` 里任意一处 `${FILE_DROP}）` 改回 `$FILE_DROP）` → 红。

## 陷阱 4（2026-09-23）：pipefail 下管道末端的 `grep -q` 会假红

`grep -q` 读到第一处匹配就退出；上游（`printf "$X"`、`grep -v`、`awk` …）要是还没写完，
下一次 write 就吃 SIGPIPE，`pipefail` 把整条管道判成失败 —— **命中了反而报没命中**。
内容超过管道缓冲（64KB）时每次必红，小内容时看两个进程谁先跑完：本地几千次不出事，
CI 上偶尔红一次。这就是 2026-09-23 那次「清单里明明有、CI 说缺」
（[案例](2026-09-23-grep-q-sigpipe-false-red.md)）。

```bash
printf '%s\n' "$BODY" | grep -q 'x'        # ✗ pipefail 下时灵时不灵
grep -q 'x' <<<"$BODY"                     # ✓ 查变量：here-string，没有管道
some_command | grep -c 'x' >/dev/null      # ✓ 查管道输出：-c 会把输入读完
```

**防回归**：`checks/shell-pipe-grep-q.sh`（进了 `scripts/check-all.sh`）扫全部开着 pipefail
的 `.sh`，管道接 `grep -q`（含 `-qE` / `-vq` / `--quiet`，`|` 在行尾换行的也算）就红。
