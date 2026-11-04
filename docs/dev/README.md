# 开发者文档

面向要改这个插件（或照它写新插件）的人。用户文档在仓库根 `README.md`。

| 文档 | 内容 |
|---|---|
| [architecture.md](architecture.md) | 三部分结构（Host / Client / 原生助手）、数据流、每个文件负责什么 |
| [protocol.md](protocol.md) | 原生助手 ↔ Host 的 stdin/stdout 协议、CFG / SUBMIT / 图片格式、行长上限 |
| [native-popup.md](native-popup.md) | 原生浮窗的行为决策与踩过的坑（⌘V 路由、焦点、切换、输入法、位置） |
| [testing.md](testing.md) | `check.sh`、`--interaction-test`、隔离 Host 端到端测试的做法 |
| [releasing.md](releasing.md) | 版本号、CHANGELOG、git tag、npm 发布（2FA）、市场索引与 Pages |

## 一分钟上手

```sh
cd plugins/dsh-quickbar

bash native/build.sh          # 重建 universal 原生二进制（改变 .m 后必须）
bash native/check.sh          # 65 项验收（源码断言 + 自检 + 交互自检）

# 让运行中的 Harness 重新加载这个插件（Host + 原生助手）
#   -- 在 DSH 里调用 plugin_manager set_bundle dsh-quickbar false→true
#   -- Client 前端改动需要完全退出并重开 App（桌面端 ⌘R 无效）
```

插件在桌面 profile 里以 `link:` 方式安装，所以改代码后重载即可，不需要发版。
