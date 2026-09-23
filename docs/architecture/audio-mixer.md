# 推子与电平表：轨道头上的混音台

> 2026-09-23 落地。改轨道推子 / 总推子、轨道头的推子视图、电平表（音频 tap）之前必读。
> 方案与产品决策见 [声音编辑方案](../plans/2026-09-23-audio-mixing.md)；
> 段自己的音量见 [音量曲线](audio-volume-curve.md) 与 [声音：音量与渐入渐出](audio-fades.md)。

## 一、三级增益，一条账

听到的 = **段**（`volume` 或音量曲线）× 渐入渐出 × **轨道推子** × **总推子**。

- 轨道推子：`EditLane.volume`（上层视频轨、音频轨）和 `TimelineState.mainVolume`（主轨不是
  `EditLane`，同 `mainHidden`）。总推子：`TimelineState.masterVolume`。
- 都存**线性幅度 0…2**（与 `EditClip.volume` 同一个语义，1 = 0 dB），界面用 dB，换算只有
  `AudioGain` 一份；夹紧只有 `AudioGain.clampedLinear` 一处（读盘、写入都走它）。
- 推子**属于轨**，段换轨就换成新轨的推子；选段导出把推子一起带走（升上来当主轨的那条带着
  自己的推子）。
- 工程格式 **v19**，推子不在 0 dB 才写键。

### 两条管线怎么乘

两个推子都是常数，**直接乘进每一段自己的增益**，不在图里另加节点：

- 预览：`makeAudioMix` 给每一段算 `gainScale = trackVolume(containingClip:) × masterVolume`，
  乘进这一段的每个音量设定点（主轨 A/B 两条合成轨都按主轨推子算）。
- 导出：乘进这一段的 `volume=`（或曲线 `aeval` 的每片叶子）。推子都在 0 dB 时参数与改动前
  逐字节相同。
- 只动推子属于「只换 audioMix」（`differsOnlyInAudioMix` 已经抹平三级推子），画面不闪。

**总推子不能挪到混音之后单独乘**：那样预览（每条合成轨各乘各的）和导出（混完再乘）数学上
虽等价，却多出一处「总推子在哪乘」的账，迟早分叉。

## 二、回归

| 检查 | 守什么 |
| --- | --- |
| `scripts/check-project-file.sh`（第 28 组） | 推子的取值口与夹紧、只动推子 = 只换 audioMix、选段导出带着推子走（含升轨）、存盘按需写键 / v19、越界值夹回来、v18 老工程读成 0 dB |
| `scripts/check-audio-fade.sh`（第 7a、7e 组） | 真实包络里推子那 −3 dB 两条管线都在；快路径与重建等价 |
