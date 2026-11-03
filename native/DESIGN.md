# Quickbar 浮窗 · 视觉与交互规范（native popup）

> 面向 `native/quickbar-hotkey.m` 的 AppKit 实现。依据 `frontend-design` / `impeccable`
> 的 Operate 表面规则：**熟悉感优先、克制、状态完整、一处海拔、一个动作一个强调色**。
> 这是坐在任意桌面内容之上的"命令面板"，不是品牌页；它的成功标准是"消失于任务"。

## 1. 概念方向

**macOS 原生命令面板**：一块浮在桌面之上的圆角材质卡片，三层结构
（选择器行 → 文本输入 → 操作/提示行）。视觉重心在**输入行**；其余元素退后。
不做装饰性玻璃、不用渐变文字、不用 emoji 当图标。

## 2. 尺寸与布局

| 元素 | 规格 |
|---|---|
| 卡片宽度 | 640 pt 固定（小屏限 `min(640, 屏宽 - 96)`） |
| 圆角 | 16 pt（`layer.cornerRadius = 16`，`masksToBounds = NO` 于外层容器以便阴影） |
| 内边距 | 水平 20 pt、垂直 16 pt；三行之间 12 pt |
| 行高 | 选择器行 26 pt；输入区最小 44 pt，自动增高至 5 行（约 132 pt）后内部滚动 |
| 位置 | 屏幕可见区域上 1/3 居中；**记住上次拖动位置**（NSUserDefaults），首次居中 |
| 层级 | `NSFloatingWindowLevel`，`canJoinAllSpaces | fullScreenAuxiliary` |

面板高度 = 顶栏 26 + 间距 12 + 输入区 + 间距 12 + 底栏 26 + 垂直内边距 32（随输入区增高而增高）。

## 3. 材质、层次、颜色

- **材质**：`NSVisualEffectView`，`material = .hudWindow`（暗色）/ 跟随系统用 `.popover`；
  `blendingMode = .behindWindow`，`state = .active`。前景内容全部用系统语义色。
- **海拔只声明一次**：卡片用**柔和阴影**（offset `(0,-10)`、blur `28`、alpha `0.30`，
  暗色下 `0.45`），**不再加外边框**。内部只允许 1px 分隔线（`separatorColor` 12% 透明）分隔底栏。
- **颜色语义**（全部取自 AppKit 语义色，自动适配深浅色/强调色）：
  - 输入文字 `labelColor`；占位符 `placeholderTextColor`（≥4.5:1）；
  - 次级文字（选择器标签、快捷键提示）`secondaryLabelColor`；禁用 `tertiaryLabelColor`；
  - 强调色 **只用于**：发送按钮底色（`controlAccentColor`）、输入框聚焦环、图像缩略图选中描边；
  - 错误 `systemRed`；成功态用 `systemGreen` 仅在"已发送"的 150ms 反馈里出现。
- **输入区不用描边**：用比卡片更深的一层填充色标识输入区（深色 22% 黑、浅色 6% 黑）；
  聚焦时把这层填充再加深一点（深色 +7%、浅色 +4%），不加任何边框/描边。
- **插图预览**：粘贴后出现 56×56 缩略图（圆角 8、深色底 18% + 1px separator 描边 45%），
  右上角 hover 出现移除按钮；同时在输入区下方显示一行中性提示「已添加图片 N/4」（2.5s 自动消失）。
- **粘图入口**：底栏左侧的「⌘V 粘图」是可点击按钮（不是纯提示），用于剪贴板管理器把 ⌘V
  发给别的 App、浮窗收不到粘贴时的手动兜底。
- **⌘V 路由**：助手是无菜单栏的 accessory 进程，必须自建 Edit 菜单（Undo/Cut/Copy/Paste/
  Select All）并在 `QBPasteTextView` 的 `performKeyEquivalent:` 兜底，否则 ⌘V 根本不会
  走到 `paste:`（这是"粘了没反应"的根因）。
- **无外边框 + 有内部阴影**：避免"幽灵卡片"（1px 边框 + 宽阴影同时存在）。

## 4. 排版

- 单一字族：**系统字体**（`NSFont.systemFont`，SF Pro）。Operate 表面不需要展示字体。
- 固定字号（不做流式）：
  - 输入文字 **13 pt**（与其他控件一致），行高 1.35（`NSParagraphStyle.lineSpacing ≈ 2`）；
  - 选择器按钮文字 **13 pt**（medium 字重）；选择器小标签 **11 pt**（secondary，全大写不加字距）；
  - 底栏快捷键提示 **11.5 pt**（secondary）；数字（pid/计数）使用 tabular（`monospacedDigitSystemFont`）。
- 字重对比只两档：regular（正文）/ medium（可操作控件）。不用 bold 做强调。

## 5. 组件词汇（全休系统控件或自绘同构）

1. **选择器 Pill（3 个）**：`NSPopUpButton` 去掉原生边框（`isBordered = false`，
   `bezelStyle` 不适用），放在一个 26pt 高、radius 13（pill）的 `NSVisualEffectView` 或
   自绘背景容器里（背景 `quaternaryLabelColor` 8%）；hover 时提高到 12%。
   文本前加 11pt 小标签（工作区/模型/思考）；右侧 8pt chevron（`chevron.down` 用
   `NSImage(systemSymbolName:)`）。
2. **输入区**：`NSScrollView` + 自绘 `NSTextView`，`drawsBackground = false`，
   `textContainerInset = (0, 2)`，`isRichText = false`，`isAutomaticQuoteSubstitutionEnabled = false`
   （中文输入法下不要智能标点）。占位符用 NSTextField 叠加或 `placeholderString` 等价实现。
3. **图像缩略图条**（粘图后出现）：56×56 圆角 8，右侧 4px 内边距；右上角 16pt 圆形 × 按钮
   （`xmark.circle.fill`，hover 才显示）；最多 4 张。条高 64（含 8pt 上间距）。
4. **发送按钮**：右侧 26pt 高 pill，默认 `controlAccentColor` 底 + `alternateSelectedControlTextColor`
   文字 "发送"（13pt medium）；`sending` 时替换为 14pt `NSProgressIndicator`（spinning，tint 白）；
   `sent` 时 150ms 内显示 `checkmark`；`disabled` 时 `quaternaryLabelColor` 底。
5. **底栏**：左：`⌘V 粘图` 提示（11.5pt secondary，仅当支持粘图时）；右：`Enter 发送 · Shift+Enter 换行 · Esc 关闭`。
   左/右之间弹性空白。底栏上方 1px 分隔线（`separatorColor` 12%）。

## 6. 状态与动效

| 状态 | 表现 |
|---|---|
| 打开 | 180ms ease-out：opacity 0→1、位移 6pt 上移、scale 0.98→1（用 `NSAnimationContext` + layer transform 或逐帧） |
| 关闭 | 120ms fade（Esc / 点击外部 / 再按快捷键） |
| 发送中 | 发送按钮 spinner；输入禁用但文字保留；面板不关闭 |
| 成功 | 150ms 内按钮变 checkmark，然后淡出关闭 |
| 失败 | 输入区下方 8pt 处一行 `systemRed` 文本（错误原因），文字保留可重试 |
| 冲突 | 面板不弹出；由 Host/前端提示（见 v5 契约） |

- 动效只表达状态，不做编排；所有时长 ≤ 250ms。
- 点击卡片外部 / 切到别的 App → 关闭（保留草稿，只有 Esc 会清空）。
- **瞬时焦点丢失不算点外部**：输入法候选窗、剪贴板历史选择器（非激活面板）、系统面板
  都会短暂抢走 key window；此时 App 仍处于激活态，浮窗**保持可见**并等焦点回来，
  否则粘贴类工具一点就整框消失。只有激活态变了（真正切到别的 App）才关闭。
- 再次按快捷键 → 打开/关闭切换。

## 7. 键盘与交互细则

- `Enter` 发送（`insertNewline:`，且 `hasMarkedText` 为真时先让输入法上屏）。
- `Shift+Enter` 换行；`Esc` 关闭（清空内容）；`⌘V` 粘图（不插入文本）。
- 点击外部关闭；再次按全局快捷键：可见则关闭，不可见则打开。
- 记住上次位置（`NSUserDefaults` key `quickbar.popup.origin`），每次打开若屏幕变化则回退居中。

## 8. 禁止项（来自 craft floor）

- 不加外边框；不做装饰性玻璃/渐变文字；不用 emoji 当图标；不用等宽字体装"技术感"；
  不做错误弹窗（用内联错误行）；卡片圆角不超过 16；控件不做无意义动效。
- 占位符/正文对比度 ≥ 4.5:1；所有状态（默认/hover/focus/active/disabled/loading/error）必须实现。

## 9. 验收

- [ ] 深浅色两种系统外观下均正确（语义色 + material 自动适配）。
- [ ] 长文本自动增高至 5 行后滚动；Shift+Enter 换行、Enter 发送、中文输入法回车不误发。
- [ ] 粘图：⌘V 出现缩略图、可删、随发送进入会话。
- [ ] 快捷键切换开合；点击外部关闭；Esc 关闭。
- [ ] 发送中/成功/失败三态可见；失败后文字保留。
- [ ] 拖动后再次打开位置保持；多显示器/全屏 Space 正常。
