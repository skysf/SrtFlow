# 签名与系统权限：发布版用一把固定的自签名证书

> 2026-10-03 起。改打包、签名（`scripts/build-app.sh`、`scripts/build-beta-app.sh`、`scripts/signing/`），
> 或者改任何要系统权限的地方（录屏、麦克风、读下载文件夹、钥匙串）之前必读。
> 案例：[录屏开关开着、自定义区域还是说没权限](../bugfixes/2026-10-03-screen-recording-permission-stale-after-update.md)。

## 一、为什么：系统权限按签名记账

macOS 的隐私授权（TCC：录屏、麦克风、下载 / 桌面 / 文稿文件夹……）每条记录按 bundle id 找，但**按签名认**：
记录里存着授权那一刻那个 App 的 designated requirement（TCC.db 的 `csreq` 列），之后每次都拿正在跑的 App
去比，对不上就当没授权。钥匙串项的访问控制同理。

ad-hoc 签名（`codesign --sign -`）的 designated requirement 就是 `cdhash H"…"`：二进制、Info.plist 任何一处
变了 cdhash 就变（内容一样重签，cdhash 不变）。所以 ad-hoc 签的每个新版本，在系统眼里都是「另一个 App」。
2026-10-03 在 macOS 26.5 上量到的各种权限对不上之后的表现：

| 权限 | 用户怎么给 | 换了签名之后 |
| --- | --- | --- |
| 录屏（ScreenCapture，系统的 TCC.db） | 系统设置里拨开关 | 开关照样显示开着，App 照样被拒。**关掉再打开只改开关、不换钉着的签名**（用户刚拨过的记录 `last_modified` 是新的，`csreq` 还是老构建的 cdhash），怎么拨都没用。只有删掉这条记录（`tccutil reset`，或在列表里选中按「−」）让系统重新问 |
| 下载文件夹（用户的 TCC.db） | 系统弹框点「允许」 | 下一次访问重新弹框；点了允许，`csreq` 换成新构建的 |
| 钥匙串（fal 的 Key，[fal.ai 生成](fal-generation.md) 第六节） | 弹框点「始终允许」 | 每个新构建第一次读弹一次 |

## 二、做法：一把固定的自签名证书

- **证书**：自签名、只能签代码（EKU codeSigning）、20 年，名字「SrtFlow Signing」。签出来的 designated
  requirement 是 `identifier "<bundle id>" and certificate leaf = H"<证书的 SHA-1>"`，换版本不变，系统里给过的
  权限跟着走。2026-10-03 的探针：同一把证书签的两个不同构建（cdhash 不同）互相满足对方的 requirement
  （`codesign --verify -R`）；前一个构建在钥匙串里建的项，后一个构建不弹框就读得到（对照：两个 ad-hoc 构建读不到）。
- **不是 Developer ID**：不花钱，Gatekeeper 的表现不变 —— 照样没公证，下载来的第一次打开照样要「仍要打开」
  （`spctl` 照样 rejected）。哪天换成 Developer ID，requirement 再变一次，用户再给一次权限。
- **私钥在仓库外**：`~/.config/srtflow/signing/`（专用钥匙串 `srtflow-signing.keychain-db` + 它的密码
  `keychain-password`，目录 700、文件 600，同 `r2.env`）。仓库里只钉证书的 SHA-1：`packaging/signing-identity.sha1`。
- **签名只经一处**：`scripts/signing/sign-app.sh`（`build-app.sh`、`build-beta-app.sh` 都调它）。先签
  `Contents/Helpers` 里的 ffmpeg、srtflow-mcp，再签外层。有签名身份就用它签，签完核对 requirement 真的钉在
  证书上；没有就退回 ad-hoc 并警告（README 里自己编着用的人不受影响）。只换了签名身份：没开 hardened runtime、
  没有 entitlement，和 ad-hoc 时一样。
- **专用钥匙串只在签名那几秒挂上搜索列表**：codesign 只在搜索列表里的钥匙串中找身份，`--keychain` 只是在
  列表里挑，不在列表里就报「no identity found」（实测）。签完原样放回、锁上；不长期挂着 —— 上了锁的钥匙串
  留在列表里，别的 App 找证书时会弹框要它的密码。
- **建身份**：`scripts/signing/create-identity.sh`，一次性。建完自己签一个小程序验 requirement，仓库还没钉
  证书时顺手写进 `packaging/signing-identity.sha1`。用系统的 `/usr/bin/openssl`（LibreSSL）：Homebrew 的
  OpenSSL 3 默认导出的 p12 `security import` 认不出来。

## 三、规矩

1. **打包脚本不许自己调 `codesign`**，只经 `scripts/signing/sign-app.sh`。
2. **永远不重建证书，这个目录要有备份。** 换机器就把整个 `~/.config/srtflow/signing/` 拷过去；这台机器上没有它时，停下来
   告诉用户，别去跑 `create-identity.sh`（本机 2026-10-03 的情况：Time Machine 包含这个目录，备份盘是一块外接 USB 盘，
   插上跑过一次才算有了备份）。`create-identity.sh` 发现已经有了就拒绝；`sign-app.sh` 发现这台机器上的证书和仓库钉着的不是一把就不签。真要换：改
   `packaging/signing-identity.sha1`，并在发版说明里告诉用户要把录屏等权限重新给一次。
3. **退回 ad-hoc 的包不许发版**（`sign-app.sh` 会打一段 ⚠️ 警告）。
4. **App 这边**：录自定义区域发现没授权时，先 `ScreenCapturePermissionRepair.resetRecordOncePerBuild()` 再
   `CGRequestScreenCaptureAccess()`。它用 `tccutil reset ScreenCapture <自己的 bundle id>` 删掉 SrtFlow 自己那条
   录屏记录，**每个构建（cdhash）最多删一次**：删完、系统重新问过之后，同一个构建再被拒，要么用户没开，要么开了还没
   重开 SrtFlow（授权下次启动才生效），再删只会把用户刚开的那条也删掉。改成固定签名之后升级不会再让记录作废，它兜的是
   改签之前留下的旧记录和没有证书的构建。调 `tccutil` 的只有它；起子进程用 `ChildProcess`（结束回调，不占线程）。
5. **给用户的话不写「关掉再打开」**：拨开关救不回钉着旧签名的记录。写「到系统设置里打开 SrtFlow，再退出并重新打开」。
6. 冒烟用的开发版（`SrtFlowDev.app` 等，[GUI 冒烟流程](../testing/gui-smoke-testing.md)）照旧 ad-hoc：它们的权限本来就
   每次重给。

## 四、第一次换到固定签名时（每台机器一次）

老的记录全是 ad-hoc 的 cdhash，换签之后都对不上，每台机器还要再给一次：录自定义区域时 App 自己删掉旧记录、系统问一次
→ 到系统设置里打开 → 退出并重新打开；读下载文件夹弹一次；钥匙串里的 fal Key 弹一次「始终允许」。之后升级都不用再给。

## 五、守卫与人工回归

| 检查 | 钉什么 |
| --- | --- |
| `checks/release-signing.sh`（第 1 组） | 第三节 1–5：打包脚本只经 `sign-app.sh`；它有身份就用、核对钉着的证书和签完的 requirement、ad-hoc 只在没有身份那一支；钉着正好一把证书；请求录屏授权之前先删旧记录、`tccutil` 只在一处；表里没有「关掉再打开」 |
| `scripts/check-mcp.sh` 开头 | 小程序先拷进 Helpers 再签名，`sign-app.sh` 里先签小程序再签外层 |
| `sign-app.sh` 自己 | 有身份时签完核对 requirement 是 `certificate leaf = H"<钉着的 SHA-1>"`，不是就红 |

够不着的（系统设置、系统弹框、TCC.db 要完全磁盘访问），发版前实机走一遍：

1. `codesign -d -r- dist/SrtFlow.app` → `certificate leaf = H"<packaging/signing-identity.sha1 里那一行>"`。
2. 装上之后录一次自定义区域：没授权时系统弹框问 → 打开 → 退出并重新打开 → 能录。
3. 再装下一个版本（不同的 cdhash）：不用再授权，自定义区域照样能录；读下载文件夹不弹框；fal 的 Key 不弹框。
4. 有完全磁盘访问的终端里：`sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" "select hex(csreq) from access
   where service='kTCCServiceScreenCapture' and client='com.srtflow.SrtFlow'"`，解出来（`xxd -r -p` → `csreq -r - -t`）
   是 `certificate leaf` 那种，不是 `cdhash`。
