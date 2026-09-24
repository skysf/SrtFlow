# 2026-09-24 剪辑导出面板说「音频原样复制，不损失音质」，其实每次都重新编码

## 症状

剪辑导出面板的 Audio 一栏默认是「Copy (original quality)」，下面一行写着「Audio is
copied untouched, so nothing is lost」。实际导出的成片里，声音**每一次**都被重新编码成
AAC 192 kbps —— 选不选 Copy 都一样。选「Re-encode AAC」再挑码率倒是生效的，所以这个
选项不是全坏，只是默认那一项在说假话。

不是用户报的：导出面板改版、把这一栏收进「高级」时，对照滤镜图读出来的。

## 根因

压缩、烧录、剪辑导出三个工具共用一个 `EncodeSettingsView`。前两个是「一个源文件进、
一个出」，声音真的能 `-c:a copy`；剪辑导出是多段合成，声音要裁切、变速、调音量、做
渐变、混音，只能重新编码 —— `VideoEditExportGraph` 里无条件写 `-c:a aac`，
`settings.audio.mode` 一次都没读过。

同一类错这里已经犯过一次：分辨率 / 帧率上限剪辑导出也不消费，当时（计划 §3.3）的
修法是给这个视图加了个 `showsScalingLimits: false` 开关，把那两个控件藏起来。**修的是
那两个控件，不是这一类问题**：开关只管「分辨率 / 帧率」，音频那一栏没人对照过管线。

## 修复

- `EncodeSettingsView` 拆成「一整张 Form」和可嵌入的 `EncodeSettingsSections`，后者收一个
  `Pipeline`：`.sourceFile`（压缩 / 烧录）、`.timeline`（剪辑导出）、`.timelineAudioOnly`
  （剪辑导出里只选了声音、出 .m4a）。每个管线真消费什么，写在枚举的注释里。
- 剪辑导出的 Audio 一栏只剩「AAC bitrate」，下面一句「时间线上的声音要重新混音，所以
  总是编码成 AAC」。
- 顺手按同一条原则收了另一处：只导音频（.m4a）时，那条管线只看码率 —— 画面编码、
  「网页串流 / 元数据」都不读，面板上也就不再显示；烧字幕那一行同理。
- 原来的 `showsScalingLimits` 开关并进 `Pipeline`，不再有两个各管一半的参数。

## 验证

- GUI 冒烟（真实窗口，见 [GUI 冒烟流程](../testing/gui-smoke-testing.md)）：剪辑导出的
  「高级」里 Audio 只有「AAC bitrate 192 kbps」；只导音频时「高级」里只剩这一栏，摘要是
  「AAC 192 kbps」；压缩工具的设置页原样（分辨率、帧率、Copy 都还在）。
- 真导出一次读成片：`aac (LC) … 192 kb/s`，与面板一致。
- 这类「面板承诺了管线不做的事」自动化够不着（要对照 UI 和滤镜图），写进了
  [导出设置](../architecture/export-settings.md) 的人工回归清单。

## 教训 / 防回归

1. **共用一套设置界面的几条管线，能力不一样时，要按管线声明「我消费哪些」**，别在视图
   上一个控件一个控件地加开关 —— 开关只会修到被点名的那几个。
2. 修一个「显示了管线不吃的控件」的 bug 时，**把同一个视图里剩下的控件也对照一遍管线**。
   §3.3 那次要是顺手对一下音频，这个假承诺不会活到今天。
3. 长期约束（面板上只放管线真消费的设置）写在 [导出设置](../architecture/export-settings.md)。
