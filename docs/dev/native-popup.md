# 原生浮窗：行为决策与踩过的坑

设计目标：一个**极轻的随手问**入口。按热键立刻出现，输入/粘图，回车就走，
主窗口在答案开始后再出现。

## 行为

| 交互 | 结果 |
|---|---|
| 全局热键 | 打开；再按一次关闭（**保留草稿**） |
| `Esc` | 关闭并清空（输入法组合中时只取消组合） |
| 点击浮窗外 | 关闭，**保留草稿**（只有 Esc 会清空） |
| 输入法/剪贴板选择器抢焦点 | **不关闭**，等焦点回来（只在真正切到别的 App 时关闭） |
| `⇧Enter` / `Enter` | 换行 / 发送 |
| `⌘V` / 底栏「⌘V 粘图」 | 粘贴最多 4 张图；72×72 整图预览；hover 可删；输入区下方提示「已添加图片 N/4」 |
| 发送中 | 输入禁用 + 按钮 spinner，面板不关 |
| 成功 / 失败 | `SUBMIT_OK` 收起；`SUBMIT_FAIL` 保留文字 + 红色内联错误 |

## 踩过的坑（改代码前先读）

1. **⌘V 没反应（历史最久）**
   助手是无菜单栏的 accessory 进程，`⌘V` 是菜单快捷键，没有主菜单就不会路由到
   `paste:`。修法：自建 Edit 菜单（Undo/Cut/Copy/Paste/Select All）+ 文本框
   `performKeyEquivalent:` 兜底。

2. **输入框完全无法输入**
   v5 换成 `NSScrollView` + `NSTextView` 时，scroll view 没有加进视图层级 →
   text view 没有 window → `makeFirstResponder` 失败。修法：`[container addSubview:scroll]`，
   `check.sh` 里有回归断言。

3. **文字被截断**
   标签 frame 宽度按精确文本宽度设置，而 `NSTextField` cell 有内边距 →
   最后一个字变成省略号。修法：`NSLineBreakByClipping` + 宽度加 8pt padding。

4. **焦点丢失就关窗**
   以前 `windowDidResignKey` 立即关闭，导致输入法候选窗/剪贴板历史面板一出现就整框消失。
   修法：失焦后延迟 0.35s 判断，若 App 仍是激活态则保留（瞬时抢焦点），否则关闭。

5. **带图片提交超时**
   Host 协议行上限 64 KiB 会静默丢弃 SUBMIT。修法：上限 32 MiB + 超限回报错误 +
   原生端缩放图片（长边 1600px）。

6. **图片预览看不出是什么**
   56×56 且按“填满裁切”只剩中间一条。修法：72×72 + `MIN` 缩放（整图可见）。

## 视觉规范

唯一权威是 [`native/DESIGN.md`](../../native/DESIGN.md)。要点：

- 材质卡片（popover）、圆角 16、单层系统阴影、无外描边；
- 三个 pill 下拉（工作区 / 模型 / 思考），11pt 说明 + 8pt chevron；
- 输入 13pt（与控件一致），用**比卡片更深的一层填充**表示输入区，不用描边/聚焦环；
- 底栏 11.5pt 提示 + 强调色「发送」按钮（禁用/发送中/成功三态）；
- 动效 180ms 打开 / 120ms 关闭 / 150ms 成功停留；全部语义色，深浅色自适应；
- 拖动位置按显示器记到 `NSUserDefaults`（`quickbar.popup.origin`）。
