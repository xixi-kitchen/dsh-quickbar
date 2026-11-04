# dsh-quickbar（快捷唤起）

DeepSeek Harness 的**系统级全局快捷键**插件（macOS）：按 `⌘⇧Space` 弹出一个**轻量置顶输入框**
（带工作区 / 模型 / 思考强度三个下拉），输入完按回车，主窗口才到前台、在指定工作区用指定模型
流式输出答案。窗口内还有 `⌘⇧K` 的完整浮层（支持 ⌘V 粘图、附加文件）。

- 不修改 Harness 本体，不依赖 Electron 的全局快捷键 API。
- 原生助手走 Carbon `RegisterEventHotKey`，**不需要「辅助功能」「屏幕录制」权限**。
- 预编译二进制是 **universal（arm64 + x86_64）**，Apple Silicon 与 Intel Mac 都能用。

## 安装

**方式一：从 npm 安装（推荐）**

```
plugin_manager install_bundle  target=dsh-quickbar
```

**方式二：从插件市场 Discover 安装**

在 `设置 → 插件 → Discover` 里添加市场索引地址（见下方「发布」），搜索 `快捷唤起` / `quickbar`
后一键安装。

**方式三：本地目录（开发用）**

```
plugin_manager install_bundle  target=/path/to/quickbar
```

安装后刷新一次 Harness 窗口（`⌘R`）即可加载前端部分；Host 部分由插件管理器的热重载生效。

## 使用

- **全局快捷键**（默认 `⌘⇧Space`）：在任意应用里按下 → 弹出轻量置顶输入框（主窗口不打扰）。
  - 上方三个下拉：**工作区**（默认「默认工作区」）、**模型**（`供应商 · 模型名`）、**思考强度**；
  - 输入后 `Enter` 发送 → 主窗口到前台并展示答案；`Esc` 取消；
  - 会记住你上次选的工作区/模型/强度（10 分钟内延续），两处界面双向同步。
- **窗口内备用快捷键**（默认 `⌘⇧K`）：注册到 Harness 的快捷键服务（桌面端走原生命令，
  可在「设置 → 快捷键」重绑；与默认组合冲突时自动退到 `⌥⌘K`）。打开完整的 App 内浮层，除三个下拉外还支持
  `⌘V` 粘贴图片（≤4 张）与「附加文件」（≤4 个）。
- **设置页**：`设置 → 快捷唤起`
  - 快捷键录制框：点一下直接按新组合（至少含一个修饰键 ⌘/⇧/⌥/⌃ + 一个键），保存后立即生效；
  - 可选键：`a-z`、`0-9`、`Space`、`Tab`、`Return`、`Esc`、`F1-F12`、`-` `,` `.` `/` `` ` ``、方向键；
  - 状态：`已就绪`（含助手 pid）/`启动中`/`错误`（如快捷键被占用）/`已停用`；
  - `测试` 按钮：等价于按一次全局快捷键（弹出原生输入框）；
  - 开关：启用插件、提交后是否把窗口拉到前台。

## 配置（`cordis.patch.yml` 的 `quickbar` 行）

| 字段 | 默认 | 说明 |
|---|---|---|
| `enabled` | `true` | 关闭后不注册全局快捷键（窗口内快捷键同时停用） |
| `hotkey` | `'cmd+shift+space'` | 全局快捷键 spec：`+` 连接的修饰键 + 键；`off`/`none`/空串 = 关闭 |
| `raiseWindow` | `true` | 提交后是否把 Harness 窗口拉到前台 |
| `inAppShortcut` | `'cmd+shift+k'` | 窗口内备用快捷键（只由前端读取） |

## 平台与权限

- **macOS**：全局快捷键与原生浮框属于 macOS 实现（Carbon + AppKit）。Windows/Linux 上插件会
  显示「已停用」，但窗口内 `⌘⇧K` 浮层仍可用。
- **权限**：不需要辅助功能、输入监控、屏幕录制。原生助手只链接 Carbon/AppKit，热点监听走
  Carbon HotKey，不是 `CGEventTap`。
- **Harness 需保持运行**：快捷键由插件托管的原生助手注册；完全退出 Harness 后快捷键不生效
  （窗口关掉/最小化没问题）。

## 已知限制

- 全局快捷键是**独占**的：被其它应用占用时状态显示 `register-failed`，换个组合即可。
- 原生浮框支持 ⌘V 粘图，但不支持传文件（文件请在 App 内进入具体工作区处理）。
- 部分模型不支持图片输入（例如纯文本模型），会明确提示 `Send rejected: Model ... does not
  support image input.`；发图请选支持视觉的模型。
- `⌘⇧Space` 可能和系统/其它应用冲突，冲突时在设置页换组合。

## 排障

- 状态不是「已就绪」：
  - `错误：register-failed …` → 快捷键被占用，换一个组合；
  - `错误：hotkey helper binary is missing …` → 重新编译：`bash native/build.sh`（需要 Xcode CLT）；
  - `已停用` → 检查设置页开关、`hotkey` 是否为 `off`，或是否在非 macOS 平台。
- 原生助手 stderr 里的 `TISFileInterrogator` / `Keyboard Layouts` 是 macOS 自身噪音，正常。
- 改了 `index.js`：重载插件（或重启 Harness）生效；改了 `client.js`：刷新 Harness 窗口生效。

## 开发 / 验证

```sh
bash native/build.sh                                   # 编译 universal 二进制（arm64 + x86_64）
bash native/check.sh                                   # 原生助手全量自检（协议/CFG/SUBMIT/IME 源码断言）
native/quickbar-hotkey cmd+shift+space --selftest        # READY + TRIGGER，退出 0
native/quickbar-hotkey cmd+shift+space --ui-test '<cfg-json>' '你好'   # 一条结构化 SUBMIT
node --check index.js && node --check client.js
```

设计契约见 `CONTRACT.md`（Host/Client wire 类型、原生助手协议、各版本演进）；
开发/调试/发版文档见 [`DEVELOPMENT.md`](DEVELOPMENT.md) 与 [`docs/dev/`](docs/dev/README.md)；
原生助手说明见 [`native/README.md`](native/README.md)。

## 发布

**npm**

```sh
cd plugins/dsh-quickbar
npm pack --dry-run     # 检查包内容
npm publish --access public
```

包名 `dsh-quickbar`（若被占用，改成 `@你的scope/dsh-quickbar`，并同步更新 `docs/index.json`）。

**插件市场（Discover）**

`docs/index.json` 是按 `@deepseek-ai/dsh-plugin-market-index` format 1 写的市场索引，把它和
`docs/icon.svg` 一起托管到任意 HTTPS 静态站点（本仓库用 GitHub Pages，发布源设为 `main` 分支的 `/docs`），然后在
`设置 → 插件 → Discover` 添加该索引 URL 即可被搜索安装。详见 [docs/README.md](docs/README.md)。

发布新版本时：改 `package.json` 的 `version` → `npm publish` → 同步更新 `docs/index.json`
里该插件的 `versions`（`version`、`publishTimestamp`、`source.type: "npm"`）。
