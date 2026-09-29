# 2026-09-27 批量转换字幕，旁边的同名文件被悄悄盖掉

## 症状

批量转换页把 `a.srt` 转成 WebVTT，输出文件夹（默认就是源文件旁边）里已经有一个 `a.vtt` —— 比如用户手改过的那份 ——
转完它就被新的盖掉了，没有任何提示。转成**自己的格式**、又写回源文件夹时（`a.srt` → SRT），盖掉的是源文件本身，内容换成
重新写出来的一份（ASS 的注释、样式表以外的东西就没了）。一批里有两个同名文件（不同文件夹的 `a.srt`、`a.ass`）转到同一个
输出文件夹，后一个盖掉前一个。从 2026-07-28 开源第一版起就这样。

做 AI 的 `convert_subtitles` 时对照手动这一页发现的（AI 那条路一开始就是撞名加编号、从不覆盖）；用户 2026-09-27 拍板：
「批量转换改成加编号」。

## 根因

`SubtitleConverter.convertFile` 算出 `<名字>.<扩展名>` 就 `write(to:)`，默认覆盖。「撞名加编号」这条规则 App 里有两份
（AI 用的 `DefaultFolder.unoccupied`、压缩 / 烧录页 `EncodeQueue` 自己的一个循环），都在 App 里，Core 的转换函数用不到。

## 修复

- 规则挪进 SrtFlowCore：`ExportFileName.unoccupied`（`名字.后缀` 占了就 `名字 2.后缀`、`名字 3.后缀`……），只有这一份。
  批量转换（`convertFile`）、压缩 / 烧录页的成品名、AI 做出来的文件、替没存过的工程存的盘都调它；`DefaultFolder.unoccupied`
  删掉、`EncodeQueue` 的循环换掉。
- `convertFile` 写的时候再加 `.withoutOverwriting`：算名字和写之间就算有别人抢先写了同名文件，也是报错而不是盖掉。
- 面板上成功那一行显示的就是实际写出的文件名（`✓ a 2.vtt`），用户看得到另起了名字。

## 验证

- `SrtFlowCoreChecks` 的 `SubtitleConvertChecks`（原来 main.swift 里写文件的那几条挪了过来）：旁边有手改过的 `movie.vtt` →
  新的叫 `movie 2.vtt`、旧的一个字没动；再转一次 `movie 3.vtt`；同格式转到源文件夹 → `movie 2.srt`、源文件没动。
- 反向验证：`convertFile` 换回直接覆盖的老写法，4 项当场红；恢复后 7 项全绿。
- 编号规则本身的三种情况（空着、占了加 2、2 也占了加 3）在 `checks/MCP/FolderChecks.swift` 里，改成调 Core 的函数。

## 教训 / 防回归

- **写用户文件夹的地方默认不覆盖**：要覆盖就像剪辑导出那样先提示、再确认（[导出设置](../architecture/export-settings.md)
  第五节）；不问的就加编号。长期约束写在那一节。
- 同一条命名规则在 App 里抄了两份、Core 里还缺一份 —— 规则放在最底下那一层（Core），上面各处都调它。
