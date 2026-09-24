# 2026-09-24 选了声音场景，检查器上却看不见选的是哪个（右边整条被裁掉）

## 症状

实机首测（用户）：选中一段音频，在「Sound scene」下拉里点 Megaphone —— 声音真的变了，
下面也出现了 Intensity / Distortion / Tone 三个滑杆，但下拉按钮上**看不见** Megaphone。
截图里还有一个没被注意到的细节：最上面的「Mute」只剩「Mu」，右边一截都被裁掉了。

## 根因

新加的那一行把标题和下拉挤在一个 HStack 里，还给下拉挂了 `.fixedSize()`：

```swift
HStack { Text("Sound scene"); Spacer(minLength: 4); Picker(...).pickerStyle(.menu).fixedSize() }
```

菜单型 Picker 的理想宽度按**最长的那个选项**算（「Valley echo」一类），`.fixedSize()` 不许它收缩；
「Sound scene」+ 这个宽度超过了检查器那条窄栏（去掉边距约 220pt）。于是整列被撑宽，检查器的
`ScrollView` 只裁不滚，右边一截（下拉按钮上的字、「Mute」、滑杆后面的百分比）全落在可见区域外。

**Picker 本身没问题**：独立探针里同一个 Picker（带 Section、预先选中 Megaphone）显示得好好的 ——
先排除了「macOS 上带 Section 的菜单 Picker 不显示选中项」这个猜测，才找到真正的原因。

自动检查全绿：量声音、存盘、接线的守卫都够不着「排版在窄栏里放不放得下」。

## 修复

`VideoEditInspector+Sound.swift`：标题单独一行，下拉铺满下一行、可以收缩（同「转场」那一块）；
去掉 `.fixedSize()`。多选时的批量那一块是同一个视图，一起好了。

## 验证

- **实机（GUI 冒烟，按 [流程](../testing/gui-smoke-testing.md)）**：`SrtFlowDev.app` 打开一份手写的
  工程（一段挂了 Megaphone 的音频，`SRTFLOW_SMOKE_PROJECT`），点中那一段，截窗口：下拉上是
  「Megaphone」，「Mute」「0.0 dB」完整；往下滚，Intensity 100% / Distortion 50% / Tone 50% /
  Reset 都完整可见。
- **守卫**：`checks/inspector-fits-width.sh` —— 检查器文件里的 Picker 修饰器链上出现 `.fixedSize()`
  就红。反向验证：把 `.fixedSize()` 放回去 → 红，点名 `VideoEditInspector+Sound.swift` 那一行；
  恢复后绿。

## 教训 / 防回归

1. **检查器是固定的窄栏，一行的最小宽度不许超过它**；菜单 Picker 的宽度跟着选项变，不许锁死。
   长期约束写在 [检查器的排版](../architecture/inspector-layout.md)。
2. **界面改动要在真窗口里看一眼再交**：这一刀的自检量了真实的 PCM、存盘、接线，唯独没人看过
   这块面板长什么样 —— 用户点第一下就发现了。
3. 截图里「不相干」的异常（「Mute」被裁成「Mu」）往往就是根因的线索。
