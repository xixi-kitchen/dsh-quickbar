# 原生助手协议

Host 与 `native/quickbar-hotkey` 之间只有 stdin/stdout 两类行；stderr 只用于诊断
（macOS 会打 TSM/键盘布局噪音，Host 忽略）。

## 助手 → Host（stdout，单行）

| 行 | 含义 |
|---|---|
| `READY <pid>` | 热键注册成功，进程就绪 |
| `TRIGGER <ms>` | 用户按了热键（Host 只更新状态；浮窗由助手自己显示） |
| `SUBMIT <base64>` | 一次提交。`base64` 解码后是 JSON；解不出 JSON 的历史格式按纯文本处理 |
| `CANCEL` | 用户在浮窗里按 Esc |
| `ERROR <code> <msg>` | 致命错误（如热键被占用），Host 不再重启助手 |

`SUBMIT` 的 JSON 结构：

```json
{
  "text": "这张图是什么？",
  "workspaceId": "ws-2",
  "provider": "deepseek-account",
  "model": "deepseek-v4-flash",
  "reasoningEffort": "high",
  "images": [
    { "mediaType": "image/png", "base64": "…", "name": "pasted-1.png", "width": 1400, "height": 900 }
  ]
}
```

- `images` 最多 4 张，字段缺失时 Host 会过滤掉非法项。
- 单个 `SUBMIT` 行必须小于 Host 的 `MAX_PROTOCOL_LINE`（当前 **32 MiB**）。
  历史 bug：上限曾是 64 KiB，带图片提交会被静默丢弃，浮窗只能等到超时。
- Host 在 `fireSubmit` 里校验图片总量，过大时直接回 `SUBMIT_FAIL 内容过大…`。

## Host → 助手（stdin，单行）

| 行 | 含义 |
|---|---|
| `trigger` | 让助手显示浮窗（设置页「测试」按钮用） |
| `CFG <base64(json)>` | 下发工作区/模型/思考强度清单与当前选择 |
| `SUBMIT_OK` | 客户端已受理提交 → 助手显示成功并收起 |
| `SUBMIT_FAIL <原因>` | 提交失败 → 助手保留文字并在输入区下方显示内联错误 |

`CFG` 结构：

```json
{
  "workspaces": [{ "id": "ws-2", "label": "T_T-Des…", "path": "/…" }],
  "models": [
    {
      "provider": { "id": "deepseek-account", "name": "DeepSeek Account" },
      "models": [
        { "id": "deepseek-v4-flash", "name": "DeepSeek-V4.1-Flash",
          "efforts": [{ "id": "low", "name": "Low" }, { "id": "high", "name": "High" }],
          "defaultEffort": "high" }
      ]
    }
  ],
  "selection": { "workspaceId": "ws-2", "provider": "deepseek-account",
                 "model": "deepseek-v4-flash", "reasoningEffort": "high" }
}
```

## 提交的确认语义

1. 助手写出 `SUBMIT`，输入区进入 sending（禁用、显示 spinner）。
2. Host 必须在 **12s** 内收到 Client 的 `reportSubmitResult`，否则自己写
   `SUBMIT_FAIL 窗口未响应：请刷新窗口后重试`；无订阅者时立即写
   `SUBMIT_FAIL 没有已连接的窗口…`。
3. 助手自己还有 15s 兜底超时（保留文字）。

## 命令行开关（自检用）

```sh
native/quickbar-hotkey cmd+shift+space --selftest          # READY + TRIGGER
native/quickbar-hotkey cmd+shift+space --ui-test [CFG] 文本 # 打印一次 SUBMIT
native/quickbar-hotkey cmd+shift+space --ui-test-ack …     # SUBMIT_OK/FAIL 生命周期
native/quickbar-hotkey cmd+shift+space --interaction-test  # 交互/视觉常量自检
```
