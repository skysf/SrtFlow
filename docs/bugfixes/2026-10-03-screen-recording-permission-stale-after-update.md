# 2026-10-03 录屏开关开着、自定义区域还是说没权限：升级之后系统认的还是旧签名

## 症状

录屏选「自定义区域」，横幅说：

> SrtFlow doesn’t have permission to record the screen yet. Turn it on in System Settings ▸ Privacy & Security ▸
> Screen & System Audio Recording. If the switch is already on, turn it off and on again.

用户：系统设置里的开关「开了又关、关了又开，每次都重启，还是不行」，而且每次都这么麻烦。

## 根因

**发布版是 ad-hoc 签名，系统的录屏授权钉着某一个旧构建；拨开关不换钉着的签名。**

1. ad-hoc 签名的 designated requirement 就是 cdhash，每出一个新版本就变一次
   （[签名与系统权限](../architecture/code-signing-and-permissions.md) 第一节）。
2. 用户本机系统 TCC.db 里 `com.srtflow.SrtFlow` 的录屏记录（要完全磁盘访问才读得到）：

   ```
   kTCCServiceScreenCapture | com.srtflow.SrtFlow | auth_value=2（允许）| auth_reason=4（系统设置里拨的）
   last_modified = 2026-10-03 10:46:33        ← 用户刚拨过
   csreq = cdhash H"2e971222941bb3b3e8abfb537c7ea7440bea1768"
   ```

   装着的 0.18.21 是 `cdhash H"7a5bb65b62140a1a36bf0b9636b0359d299c7e46"`；废纸篓里 0.18.17–0.18.21 的五个构建
   也都不是 `2e971222…` —— 钉着的是更早的某一版。系统拿正在跑的 App 去比这条 requirement：

   ```console
   $ codesign --verify -R stored.req /Applications/SrtFlow.app
   test-requirement: code failed to satisfy specified code requirement(s)
   ```

   `last_modified` 是刚才、`csreq` 还是老的：**系统设置里关掉再打开只改开关，不换钉着的签名**。所以 App 里那句
   「关掉再打开」从来救不回这种记录。
3. 那句话是怎么来的：2026-08-06 Phase 0 量出「ad-hoc 签名的 App，TCC 授权会卡死」，当时生效的是
   「`tccutil reset` + 关掉再打开」（[实施报告](../reports/2026-08-06-native-screen-recording-implementation-report.md)
   门槛 1 结论 4、第 11 节）。写进产品文案时只留下了用户做得到的后半句，要先删记录的前半句丢了；报告里
   「需在 Phase 2 用真实 SrtFlow 复验它对正式分发的影响」那一条也一直没做。
4. 同一个根因还有三处没人报的小麻烦：测试版读下载文件夹的记录，`csreq` 是今天这一版的 cdhash（用户 10:08 刚又点了
   一次允许）—— 每次升级都重新弹框；fal 的 Key 每个新版本弹一次钥匙串授权框（[fal.ai 生成](../architecture/fal-generation.md)
   第六节记着「取舍待用户拍板」）；麦克风也按签名认（没单独量）。

## 修复

1. **发布版、测试版改用一把固定的自签名证书签**（`scripts/signing/`）：
   - `create-identity.sh` 一次性建「SrtFlow Signing」证书，放进仓库外的专用钥匙串 `~/.config/srtflow/signing/`；
     已经有了就拒绝重建。仓库钉着它的 SHA-1：`packaging/signing-identity.sha1`。
   - `sign-app.sh` 是唯一签名的地方（`build-app.sh`、`build-beta-app.sh` 都调它）：先签 Helpers 再签外层；有身份就用、
     证书和钉着的不是一把就不签、签完核对 requirement 是 `certificate leaf = H"…"`；没有身份才退回 ad-hoc 并警告。
   - 签出来的 requirement：`identifier "com.srtflow.SrtFlow" and certificate leaf = H"76d275650223bc09efe7708900458dbdb0ab90ef"`，
     换版本不变，系统权限跟着走。
2. **App 自己删旧记录**：`ScreenCapturePermissionRepair.resetRecordOncePerBuild()` —— 录自定义区域发现没授权时，用
   `tccutil reset ScreenCapture <自己的 bundle id>` 删掉自己那条录屏记录再请求，系统重新问、新记录钉在现在的签名上；
   每个构建最多删一次（再删会把用户刚开、还没重开 App 生效的那条也删掉）。兜的是换签之前留下的旧记录、没证书的构建。
   起子进程抽成 `ChildProcess.exitStatus`（「连接 AI」调 `claude mcp add` 原来有一份一样的私有函数，第二次出现就合成一份）。
3. **文案**：不再叫人「关掉再打开」，改成「到系统设置里打开 SrtFlow，再退出并重新打开」（三张表）。

## 验证

- **探针**（scratchpad，不碰用户的钥匙串）：同一把自签名证书签两个内容不同的小程序 —— cdhash 不同、designated
  requirement 一样，B 满足 A 的 requirement；A 在钥匙串里建的项 B 读得到、不弹框（`kSecUseAuthenticationUIFail`
  下返回 0）；对照组两个 ad-hoc 构建、证书签的建 ad-hoc 的读，都是 -128（要弹框）。自签名的 App 用 `open` 起得来，
  `spctl` 和 ad-hoc 一样 rejected。
- **脚本**（`/bin/bash` 3.2 跑，用一个临时的签名目录）：`create-identity.sh` 建身份、自验、再跑一次拒绝；`sign-app.sh`
  签一份测试版拷贝 —— App 和两个 Helpers 都是 `Authority=SrtFlow Signing`、requirement 是 certificate leaf；钉着的证书
  对不上拒签；没有身份退回 ad-hoc 并警告；参数不对报用法。每次跑完钥匙串搜索列表都原样只剩登录钥匙串。
- **守卫反向验证**：`checks/release-signing.sh` 在下面四种改动下各自变红，恢复后转绿 —— `build-app.sh` 换回原来的
  ad-hoc 那几行；删掉请求授权前的 `resetRecordOncePerBuild()`；西班牙语表换回原来那句「关掉再打开」；`sign-app.sh`
  有身份那一支改成 ad-hoc。`scripts/check-mcp.sh` 的签名顺序那一节：把 `sign-app.sh` 里外层挪到小程序前面 → 红。
- 全部扫描守卫（`scripts/check-guards.sh`）、界面文案覆盖（973 条三张表都有）、`swift build --arch arm64` 通过。
- **实机**（TCC 自动化够不着，2026-10-03 用户本机，main `60c4632` 打的 0.18.22 装进「应用程序」）：
  - 装之前那条记录还是老的：`2|4|10:46:33|cdhash H"2e971222…"`，新包 `codesign --verify -R` 照样对不上。
  - 用户录自定义区域：系统重新问 → 打开开关 → 退出并重新打开 → 录得了（用户：「可以没有问题了」）。之后的记录：
    `auth_value=2`、`last_modified=11:48:46`、`csreq` 解出来是
    `identifier "com.srtflow.SrtFlow" and certificate leaf = H"76d275650223bc09efe7708900458dbdb0ab90ef"` —— 不再是 cdhash。
  - App 自己删旧记录这一步真的跑了：`defaults read com.srtflow.SrtFlow screenRecording.permissionResetForBuild` =
    `13960eb0…`，正是装着的 0.18.22 的 cdhash（App 里起的 `tccutil reset` 不用管理员权限也成）。
  - 下一个版本不用再授权：把装着的包拷一份、版本号改成 0.18.99、照 `sign-app.sh` 重签（cdhash 变成 `c983a7be…`），
    `codesign --verify -R <这条记录>` 通过；ad-hoc 签的测试版 0.18.21 不通过（对照）。

## 教训 / 防回归

1. **「设置里开关开着却被拒」先去读 TCC.db 的 `csreq`，拿 `codesign --verify -R` 比一下。** 一条命令就能定性，
   比反复拨开关、重启快得多。
2. **把实测结论写进产品文案时，前提条件不能丢。** Phase 0 的结论是「先 `tccutil reset`，再关掉再打开」，文案只留下了
   后半句，一个从来不生效的办法就这样教了用户两个月。
3. **ad-hoc 签名不是「没签名」的免费替代品**：它让每个新版本在系统眼里都是另一个 App。要系统权限的 App，签名身份
   必须固定；固定了就永远别换（换 = 每个用户再授权一次），所以私钥要备份、仓库要钉住证书。
4. 实施报告里写着「需要复验」的风险，要么排进计划、要么写进架构文档的人工回归，别只留在报告里。
