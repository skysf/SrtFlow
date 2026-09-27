# 2026-09-27 烧录页存好的字幕样式，要先去烧录页转一圈，剪辑页才用得上

## 症状

在「烧录字幕」页把字幕调成自己的样式（比如黄字、大一号），退出 SrtFlow 再打开。主窗口回到上次的栏目 ——
常常是剪辑页。这时剪辑页预览里的字幕、剪辑导出烧进去的字幕都是**默认样式**（白字黑边），不是刚存的那套；
去烧录页点一下再回来，才变成自己的样式。压缩页记住的编码设置同理（压缩只从那一页起，用户碰不到；AI 起压缩时
就会碰到）。

从 2026-08-03 剪辑页开始用烧录页的样式起就有。做 AI 的压缩 / 烧录工具时发现：它们要以用户记住的设置为底，
一查读回来的地方只有页面的 `onAppear`。

## 根因

全 App 只有一套字幕样式，放在烧录队列上（`EncodeQueue.burnIn.burnInStyle`）。剪辑页的字幕叠层、剪辑导出、
AI 的导出 / look 都读它。可「从 UserDefaults 读回来」写在烧录页的 `restore()` 里、只在那一页出现时跑；
页面是侧边栏切换、按需创建的，App 直接进剪辑页时烧录页从没出现过，队列上一直是 `BurnInStyle.default`。
压缩页的 `restoreSettings()` 是同一个写法。

「每一页自己记、自己读」在只有这一页用这份设置时没问题；剪辑页开始共用样式的那一刻，读回来的时机就该跟着
挪走，当时没挪。同一仓库里剪辑导出的设置（`VideoEditExporter`）一直是在 init 里读回来的，没有这个问题。

## 修复

- 新的 `EncodeQueueMemory`：两个队列记住的几样（编码设置、字幕样式、再挂一条字幕轨）存在哪个键、怎么读回来，
  只有这一处。
- `EncodeQueue` 创建时就读回来（`init(… memory:)`，两个全局队列各带自己的键）—— 谁先用到队列，拿到的都是用户
  存的那套，不依赖哪一页出现过，也不依赖启动顺序。和 `VideoEditExporter` 同一个做法。
- 两页删掉自己的读回来，只在改动时写（键引用 `EncodeQueueMemory` 的常量）；烧录页「第一次用挑一个有中文的
  默认字体」要知道存没存过样式，改成问 `EncodeQueueMemory.hasRememberedStyle()`。

## 验证

- 扫描守卫 `checks/encode-settings-memory.sh`（check-all 第 1 组）：两个队列创建时带着 memory、init 里调
  `restore`、四个键的字面量只在 `EncodeQueueMemory.swift`、两页不再出现 `JSONDecoder`。
- 反向验证：去掉烧录队列的 `memory:` → 守卫当场红（「剪辑页和 AI 会用默认字幕样式」）；把烧录页换回修复前的
  版本 → 三个键的字面量和页面自己解码各红一条；恢复后全绿。
- 实机：人工回归清单见 [导出设置](../architecture/export-settings.md) 第六节。

## 顺带查过、不是 bug 的

`EncodeQueue.burnInFontURL` 从 2026-08-03 起就没被赋值过：烧录页真烧的时候，选中的字体文件没软链进任务目录
（预览那一路有）。拿 App 带的 ffmpeg 烧一帧对照：这版 libass 用 CoreText 找字体，不链文件也按名字找到了同一个
`/System/Library/Fonts/Supplemental/Chalkduster.ttf`；Helvetica 缺的汉字落到能读的那份苹方上。成片一样，
所以这次不动它。

## 教训 / 防回归

- **一份设置有了第二个读者，「什么时候读回来」就不能再挂在某一页的 `onAppear` 上**：挂在持有它的对象创建时
  （长期约束写在 [导出设置](../architecture/export-settings.md) 第六节）。
- 页面按需创建（侧边栏切换）时，「这一页出现过」不是 App 的前提 —— 主窗口会回到上次的栏目。
