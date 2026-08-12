# 2026-08-12 转场前面有硬切，导出直接失败（xfade timebase 不匹配）

## 症状

时间线里既有硬切又有转场时，点导出立刻红字失败，一帧都出不来：

```
[Parsed_xfade_199 @ 0x600002196040] First input link main timebase (1/1000000)
  do not match the corresponding second input link xfade timebase (1/24)
[Parsed_xfade_199 @ 0x600002196040] Failed to configure output pad on Parsed_xfade_199
```

用户视角是「以前都没有过」：只放转场、或者只放硬切，导出都正常；把两者混在
一条主轨上（而且转场**不是**第一处接缝）才炸。ffmpeg 是在配置滤镜图阶段就
EINVAL，所以没有任何进度、没有半成品文件。

## 根因

`VideoEditExportGraph.plan()` 把主轨拼成一条链：硬切用 `concat`，转场用
`xfade`。两种滤镜对 timebase 的处理完全不同：

| 这一节的来源 | 输出 timebase |
| --- | --- |
| 素材段 `trim,setpts,fps=<工程帧率>,…` | `1/fps`（`fps` 滤镜按帧率设的） |
| 补黑场 `color=black:r=<工程帧率>` | `1/fps` |
| `concat` 的输出 | **固定 `AVTB` = 1/1000000**（`f_concat.c` 里写死） |

而 `xfade` 在 `config_output()` 里对两条输入的 timebase 做**逐字段相等**的硬
检查，不等就直接返回 EINVAL。于是链上只要出现「先 `concat`、后 `xfade`」，
左边是 1/1000000、右边是 1/24，必炸。

反过来「先 `xfade`、后 `concat`」一直没事：两条输入都还是 1/fps，检查通过；
`concat` 自己不挑输入 timebase。这正是它此前没被发现的原因 —— 只在**接缝
顺序**上翻车，与转场种类、时长、素材都无关。触发条件很朴素：

- 主轨上任意一处硬切排在某处转场**前面**；
- 或者第一段之前/两段之间有空隙（补出来的黑场也是一次 `concat`）。

`acrossfade`（音频那一路）没有这个检查，实测 `concat` → `acrossfade` 正常出
5.5 秒，所以问题只在视频链上。

## 修复

`Sources/SrtFlow/VideoEditExportGraph.swift` 的拼接循环里，在每次 `xfade`
之前把两条输入都显式压到同一个 timebase：

```
[<左>]settb=AVTB[tbN];[<右>]settb=AVTB[tbM];[tbN][tbM]xfade=…
```

选 `AVTB` 而不是 `1/fps`，是因为它同时也是 `concat` 的输出值：这样
`xfade` 的输出（继承第一条输入）也是 `AVTB`，后面再接 `concat` 或下一次
`xfade` 都还是这个值，整条链自洽，不用在别处再补第二处转换。`settb` 会把
帧的 PTS 一并 rescale，时间账不变（132 帧的用例逐帧数过）。

## 验证

- 最小复现：`concat` 两段 24fps 色块再 `xfade` 第三段 → 原样报出用户那条
  错误；加上 `settb=AVTB` 后出片 5.5 秒 / 132 帧，与预期逐帧相符。
- 回归守卫：`checks/ExportFrameRate/main.swift` 增加「硬切和转场混排」两条
  用例（硬切在前 / 转场在前，素材带真音轨，`acrossfade` 一路也走到），调真实
  `plan()` 跑真实 ffmpeg，断言退出码 0 且约 132 帧。
- **反向验证**：临时撤掉 `settb`，`scripts/check-export-frame-rate.sh` 红在
  `硬切在前、转场在后 的 ffmpeg 执行失败：code: -22 (Invalid argument)`，
  反序那条仍绿（符合根因）；恢复修复后 25 checks / 0 failures。
- 回归面：`scripts/check-all.sh` 全绿。

## 教训 / 防回归

1. **ffmpeg 滤镜的隐式合同不止像素格式。** 这条链一直很小心地统一了帧率、
   SAR、pix_fmt，唯独 timebase 没人管 —— 因为绝大多数滤镜会自己适配，只有
   `xfade` 这类会硬检查。往拼接链里加新滤镜时，要连 timebase 一起对账。
2. **顺序敏感的 bug 需要顺序敏感的用例。** 修复前的检查只测「一段素材」，
   连一处接缝都没有，自然测不出来；新守卫特意把两种接缝顺序都排上。以后给
   拼接链加能力（新转场、新的段类型），用例至少要覆盖「混排且转场不在首位」。
3. 段的产出统一是 `1/fps`、`concat` 与 `xfade` 的输出统一是 `AVTB`，这是现在
   这条链的不变量；要改成别的值，两处得一起改。
