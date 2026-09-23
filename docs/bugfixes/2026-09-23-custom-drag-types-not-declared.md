# 2026-09-23 滤镜卡片、音频库素材拖不进时间线：自定义类型没在 Info.plist 里声明

## 症状

从左栏把**滤镜卡片**或**音频库素材**拖到时间线上：没有落点框，松手什么也不发生。
点卡片上的 `+` 照常能加。（转场卡片当时同样拖不进来，但那是另一个原因：落点回了
`.cancel`，见[下一篇案例](2026-09-23-transition-drop-cancel-ends-session.md)。）

把时间线的落点结构修成「只有一个落点」之后（[上一个案例](2026-09-23-in-app-drops-swallowed-by-file-underlay.md)），
滤镜卡片**仍然**拖不进去 —— 所以不是路由的问题。

## 根因

三套卡片各用一个自定义载荷类型，都是 `UTType(exportedAs:conformingTo: .data)` 造的：

| 类型 | 用在 | Info.plist 里声明了吗 |
| --- | --- | --- |
| `com.srtflow.transition` | 转场卡片（#50） | 声明了 |
| `com.srtflow.filter` | 滤镜卡片（#54） | **没有** |
| `com.srtflow.filter-clip` | 滤镜段的复制粘贴（#56） | **没有** |
| `com.srtflow.audio-library-item` | 音频库素材（#59） | **没有** |

没声明的标识符，系统的类型库查不到：`UTType("com.srtflow.filter")` 返回 nil，而
`UTType("com.srtflow.transition")` 能查到（一个小程序当场对比过）。SwiftUI 接拖放时
要把拖动剪贴板上的类型换回 `UTType` 再比对，换不回来，「拖进来的东西是不是滤镜
类型」就恒为否，落点直接拒绝。界面上没有任何提示；运行时那条「expected to be
declared and exported」的警告只进系统统一日志，而调试拷贝用 `log show` 查不到。

所以**滤镜和音频库这两套拖放很可能从上线起就没工作过**，只是一直被别的问题挡在
前面：合成事件驱动不了 `.onDrag`，它们从没被自动验证过；用户第一次实拖时，又先撞上
了「文件落点吞掉卡片」那个回归。

剪贴板那一个类型不影响功能（`NSPasteboard` 按字符串读写，不经过类型库），一并声明
是为了同一条规则不留例外。

### 为什么一直没发现

- 转场那条声明旁边写着一句注释：「**不声明也能跑**（同进程按标识符字符串匹配），
  声明只是更规范」。这是推断，没有实测 —— 后来的滤镜、音频库照着「可选」处理，
  没声明。
- 我在上一个案例的探针里其实已经碰到了：外部拖源拖自定义类型，连只有一个落点、
  类型完全对得上的对照格都是 op=0。当时结论写成了「SwiftUI 不认外部来的自定义
  类型」，**错了**：探针的类型同样没声明。那个现象就是这个根因，只是被我归错了类。

## 修复

- `packaging/Info.plist` 的 `UTExportedTypeDeclarations` 补上 `com.srtflow.filter`、
  `com.srtflow.filter-clip`、`com.srtflow.audio-library-item`（同转场：`public.data`，
  不带文件扩展名），并把那句「不声明也能跑」的注释改成真实的规则。
- 新守卫 `checks/exported-types-declared.sh`（进了 `check-all.sh`）：代码里每一个
  `UTType(exportedAs:)` 的标识符都必须在 Info.plist 里声明。字面量、同文件常量、
  转一手的 `FilterPayloadType.drag` 三种写法都解析；认不出的写法直接红，不静默跳过。
- 探针（`scripts/gui-smoke/drop-routing-probe/`）的 Info.plist 也声明上它的两个测试
  类型，以后用它测外部自定义类型时不会再被这件事带偏。

## 验证

- **用户亲手做的 A/B**：测试版和上一版之间唯一的功能差别就是这三条声明（外加不改变
  行为的诊断日志）。上一版滤镜拖不进去；这一版滤镜、音频库都落地了。诊断日志：
  滤镜两次 `validate → entered → PERFORM`，音频库一次 `validate → entered → PERFORM`。
- 类型库对比：声明之前 `com.srtflow.filter` / `audio-library-item` / `filter-clip` 查不到，
  调试包 `lsregister -f` 登记之后都能查到（`declared=true`）。
- 守卫反向验证：分别删掉滤镜、音频库那条声明 → 各自红，恢复后绿。

## 教训 / 防回归

1. **`UTType(exportedAs:)` 不声明就是坏的，不是「不够规范」。** 它会静默失效，
   唯一的信号在统一日志里。守卫钉着，新加自定义类型时 Info.plist 一起改。
2. **写进代码注释的「不这样也能跑」，要么有实测，要么别写。** 那一句推断让两个后来的
   功能都照着「可选」处理了。
3. **归因之前先排除实验自己的变量。** 探针的类型没声明，于是「外部来的自定义类型
   不认」其实是「没声明的类型不认」。同一个现象归错了类，就会在最该怀疑它的时候
   把它排除掉。
4. 长期约束写进[时间线拖动手势 §5e-2](../architecture/timeline-drag-gestures.md)。
