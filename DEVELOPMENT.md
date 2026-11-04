# 开发

> 完整的开发者文档在 [`docs/dev/`](docs/dev/README.md)。

## 环境

- macOS（原生浮窗与全局热键仅 macOS 支持；其它平台会退化成 App 内 ⌘⇧K 浮层）；
- 本机 Swift 工具链不可用，原生助手用 **C/ObjC + clang** 构建（`x86_64` + `arm64`，lipo 合成 universal）；
- Node 仅用于 `node --check` 与自检脚本，不需要打包步骤。

## 一分钟

```sh
bash native/build.sh     # 改了 native/*.m 之后必须重建
bash native/check.sh     # 65 项验收，必须全绿

node --check index.js    # Host 侧语法
node --check client.js   # Client 侧语法
```

## 在运行中的 Harness 里生效

本机以 `link:` 方式安装（桌面 profile），所以：

- Host / 原生改动：在 DSH 里把 bundle 关掉再打开（等价于重启 Host + 原生助手）；
- Client 前端改动：**完全退出 App（⌘Q）再重开**。桌面端 ⌘R 无效。

## 文档索引

| 文档 | 内容 |
|---|---|
| [docs/dev/architecture.md](docs/dev/architecture.md) | 三部分结构与数据流 |
| [docs/dev/protocol.md](docs/dev/protocol.md) | 原生助手 ↔ Host 协议 |
| [docs/dev/native-popup.md](docs/dev/native-popup.md) | 浮窗行为与踩坑记录 |
| [docs/dev/testing.md](docs/dev/testing.md) | 验收 / 交互自检 / 隔离 Host 端到端 |
| [docs/dev/releasing.md](docs/dev/releasing.md) | 发版 + npm 2FA + 市场索引 |
| [CONTRACT.md](CONTRACT.md) | Host/Client/原生 的接口契约（v1–v5） |
| [native/DESIGN.md](native/DESIGN.md) | 原生浮窗视觉规范（唯一权威） |
| [native/README.md](native/README.md) | 原生助手的构建与命令行开关 |

## 工作区

本仓库位于 `plugins-workspace/plugins/dsh-quickbar`，工作区约定见
[../../README.md](../../README.md)。
