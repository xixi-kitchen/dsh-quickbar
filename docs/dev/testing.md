# 测试

## 1. 原生验收：`bash native/check.sh`

65 项，全部通过才算完。覆盖：

- 构建两次幂等、universal 双架构（`lipo -archs` → `x86_64 arm64`）、`-Wall -Wextra` 干净；
- `--selftest`（READY + TRIGGER）、`--ui-test`（结构化 SUBMIT 解码）、
  `--ui-test-ack`（SUBMIT_OK / SUBMIT_FAIL / 15s 超时）、`--interaction-test`；
- 源码断言：IME 回车保护、CFG/SUBMIT 字段、ack 生命周期、三 pill、
  **输入框必须在视图层级**、**标签必须裁剪**、**⌘V 必须路由到 paste:**、
  **瞬时焦点丢失不得关窗**、设计常量（圆角 16 / 输入 13pt / 动效时长…）；
- 二进制大小报告。

## 2. 交互自检：`native/quickbar-hotkey cmd+shift+space --interaction-test`

纯内存构造面板，逐项打印 `INTERACTION ok:` / `fail:`，覆盖切换+草稿、Esc 清空、
粘贴 4 图上限、缩略图在卡片内可见、自动增高、Shift+Enter、发送态、设计常量。
`--interaction-test` 退出码非 0 表示有失败项。

## 3. 端到端（隔离 Host，不碰桌面 profile）

要点：临时 `DSH_HOME` + 临时 profile + `link:` 依赖，用 CLI 起一个独立 Host，
再用浏览器自动化验证页面行为。

```sh
TEST_HOME=/tmp/qb-iso; rm -rf "$TEST_HOME"
mkdir -p "$TEST_HOME/profiles/coldtest/node_modules"
cat > "$TEST_HOME/profiles/coldtest/package.json" <<'JSON'
{ "name": "dsh-profile-coldtest", "private": true,
  "dependencies": { "dsh-quickbar": "link:/abs/path/to/plugins/dsh-quickbar" },
  "dsh": { "profile": { "bundles": ["@deepseek-ai/dsh-base","@deepseek-ai/dsh-web-app","dsh-quickbar"] } } }
JSON
printf '# cold\n[]\n' > "$TEST_HOME/profiles/coldtest/cordis.yml"
printf -- '- id: quickbar\n  name: dsh-quickbar\n  config: { enabled: true, hotkey: cmd+shift+space, raiseWindow: false, inAppShortcut: cmd+shift+k }\n' \
  > "$TEST_HOME/profiles/coldtest/cordis.patch.yml"
ln -s /abs/path/to/plugins/dsh-quickbar "$TEST_HOME/profiles/coldtest/node_modules/dsh-quickbar"

DSH_HOME="$TEST_HOME" \
DSH_DESKTOP_NODE_EXECUTABLE="/Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness" \
"/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh" \
  --profile coldtest --no-open --host 127.0.0.1 --port 0
```

启动日志里会有 `http://127.0.0.1:<port>/?token=…`。用 ego-browser / Playwright 打开它，
按 ⌘⇧K 验证浮层、调 `ctx.quickbar` 远程方法验证提交链路（可写一个一次性 devtools
插件在 `apply` 里 `setTimeout` 后调 `submitFromHelper`）。

要点：隔离实例与原实例可以同时跑；原生热键是独占的，隔离实例的 `⌘⇧Space` 注册会失败，
但 Client 浮层、提交链路、页面渲染都不受影响，足够验证。

## 4. 真实桌面端

- Host/原生改动：DSH 里 `plugin_manager set_bundle dsh-quickbar false` → `true`（热重载）。
- **Client 前端改动：必须完全退出 App（⌘Q）再重开**；桌面端 ⌘R 无效。
- 验证清单：⌘⇧Space 开/关、⌘V 粘图、回车发送、Esc、点击外部、⌘⇧K（桌面端走
  「设置 → 快捷键」里注册的命令）。
