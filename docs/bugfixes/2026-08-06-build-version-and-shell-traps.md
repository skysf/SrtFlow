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
