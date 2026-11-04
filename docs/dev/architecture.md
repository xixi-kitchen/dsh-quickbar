# 架构

插件由三部分组成，各自独立进程/上下文：

```
┌──────────────────────────────┐
│ Harness 主进程（Electron）    │
│  └─ Host 插件  index.js       │   ← Node，dsh bundle patch 挂载
│      · Config（volatile 字段） │
│      · QuickbarService        │   ← ctx.quickbar，Typert 远程服务
│      · 原生助手 supervisor     │
└───────────┬──────────────────┘
            │ stdin/stdout 行协议
┌───────────▼──────────────────┐
│ native/quickbar-hotkey（C/ObjC）│  ← 独立进程，Carbon 全局热键 + NSPanel
│  · 全局快捷键注册               │
│  · 浮窗 UI / 输入 / 图片粘贴     │
│  · 通过 SUBMIT 行把内容交回 Host │
└──────────────────────────────┘
            │（同一进程内，经 Host 广播）
┌───────────▼──────────────────┐
│ 渲染进程（Web 前端）            │
│  └─ Client 插件 client.js      │   ← window.__ModuleLoader__.load
│      · shell.overlay 浮层       │
│      · settings.section 设置页  │
│      · 远程调用 ctx.quickbar    │
│      · ctx.shortcuts 注册快捷键 │
└──────────────────────────────┘
```

## 文件职责

| 文件 | 职责 |
|---|---|
| `index.js` | Host 插件：`Config`、`inject: ['subprocess']`、`QuickbarService extends TypertRemoteService`、原生助手生命周期、提交事件广播 |
| `client.js` | Client 插件：浮层 UI、设置页、远程方法描述符（`$mount`）、快捷键命令注册、locale 字典 |
| `cordis.patch.yml` | bundle patch：插入一行 `id: quickbar`，带默认 config（`enabled/hotkey/raiseWindow/inAppShortcut`） |
| `native/quickbar-hotkey.m` | 原生助手源码（Carbon 热键 + AppKit 浮窗 + 图片编码 + 协议） |
| `native/build.sh` | clang 两个 arch 编译 + lipo 合成 universal |
| `native/check.sh` | 验收脚本（见 testing.md） |
| `native/DESIGN.md` | 原生浮窗的视觉规范（唯一权威） |
| `CONTRACT.md` | v1–v5 的线协议/接口契约（改动接口先改它） |
| `locale/*.json` | 插件管理页/设置页的标题与描述 |
| `docs/index.json` | Discover 市场索引（GitHub Pages 发布） |

## 数据流：按一次全局热键

1. Carbon `RegisterEventHotKey` 命中 → 原生助手显示 NSPanel（窗口不抢主窗口焦点）。
2. 用户输入/粘图，回车 → 助手把结构化 `SUBMIT <base64(json)>` 写到 **stdout**。
3. Host 的 `onHelperLine` 解析：`submitFromHelper` → `fireSubmit` → 广播 `submit` 事件（`watch` 流）。
4. Client 收到 `submit` → 通过 `ctx.sessions` 在选定工作区发送 prompt（图片转成 v2 内容块），
   成功后调 `reportSubmitResult(true)` + `raiseWindow()`。
5. Host 把 `SUBMIT_OK` / `SUBMIT_FAIL <原因>` 写回助手 stdin → 助手关闭浮窗或显示内联错误。

## Host 侧要点

- `Config` 每个字段都 `.volatile()`：设置页写入后无需重启，`watch` 会拿到新状态。
- 远程服务用 `TypertRemoteService` + 手写 `REMOTE_METHODS` 标记（`markRemoteMethods`），
  `watch` 是 stream 方法（`cancellation: { parameter: 'signal' }`）。
- 原生助手由 `subprocess` spawn，`stdio: pipe`；stdout 只允许协议行，诊断走 stderr。
- 提交前有 ack 看门狗：无窗口连接立刻失败；有窗口 12s 无确认就回报，避免干等 15s。

## Client 侧要点

- 以 `window.__ModuleLoader__.load({ id: 'dsh-quickbar', factory(require) })` 形式加载，
  只 `require('react')`。
- `shell.overlay` 注册浮层（`id: quickbar-overlay`），`settings.section` 注册设置页。
- 远端描述符与 Host 方法签名严格对应；参数需要 `strict` codec。
- **桌面端的快捷键必须通过 `ctx.shortcuts.register`** 注册（Electron 原生键盘桥会先截获已注册组合，
  DOM `keydown` 收不到）。
- 主题色只用 `--dsw-alias-*` token，不写死颜色。

## 原生侧要点

- Swift 工具链在这台机器上不可用，所以用 C/ObjC + clang。
- 助手是 accessory 进程（无 Dock 图标、无菜单栏）→ **必须自建 Edit 菜单**，
  否则 ⌘V 这类标准编辑快捷键不会路由到输入框。
- 浮窗用 `NSVisualEffectView`（popover 材质）+ 圆角 16 + 系统单层阴影；无外描边。
- 输入区用 13pt 文字 + 比卡片更深的一层填充色表示（不用描边/聚焦环）。
- 图片粘贴：`⌘V` → `qb_pasteboard_image` → 缩放到长边 1600px → PNG（>1.2MB 转 JPEG 0.8，必要时 0.6）。
