# 插件市场索引（Discover）

本目录是给 DeepSeek Harness 的 **Discover** 页面用的市场索引，格式遵循
`@deepseek-ai/dsh-plugin-market-index` 的 **format 1**。它也是本仓库的 GitHub Pages
发布源（`main` 分支的 `/docs`），因此部署后索引地址就是仓库 Pages 根下的 `index.json`。

| 文件 | 作用 |
|---|---|
| `index.json` | 市场索引：标题/分类/标签 + 插件条目 + 每个版本的 npm 来源与兼容范围 |
| `icon.svg` | 插件图标（`index.json` 里用相对路径 `icon.svg` 引用，按索引 URL 解析） |
| `README.md` | 本说明 |

## 校验索引

索引已用官方校验器（format 1）验证通过。发布前建议再跑一次：

```sh
node -e '
const { parseMarketIndex, marketInstallTarget } = await import("@deepseek-ai/dsh-plugin-market-index")
const doc = JSON.parse(require("fs").readFileSync("docs/index.json", "utf8"))
const parsed = parseMarketIndex(doc, "https://xixi-kitchen.github.io/dsh-quickbar/index.json")
for (const p of parsed.plugins) for (const v of p.versions) console.log(marketInstallTarget(p.name, v))
'
```

（该包随 DSH 安装提供；也可用 `node --input-type=module` 从 DSH 运行目录引用。）

## 部署（本仓库已启用 GitHub Pages）

1. 仓库 `Settings → Pages`：Source 选 `Deploy from a branch`，分支 `main`，目录 `/docs`。
2. 生效后索引地址为：

   ```
   https://xixi-kitchen.github.io/dsh-quickbar/index.json
   ```

3. 在 Harness 里：`设置 → 插件 → Discover → 添加索引`，粘贴上面的 URL。
4. 搜索 `快捷唤起` 或 `quickbar` 即可看到插件；安装时市场会把版本解析成
   `dsh-quickbar@0.1.0` 交给 `plugin_manager install_bundle`。

> 要求：索引与图标都必须通过 **HTTPS** 提供（或与索引同源）。图标也可以用
> `data:image/svg+xml;base64,…` 内联（≤32 KiB），这样单文件 `index.json` 即可。

## 发布新版本时

1. `package.json` 升 `version`，`npm publish`；
2. 在 `docs/index.json` 的 `plugins[0].versions` **最前面**加一条：

   ```json
   { "version": "0.2.0", "publishTimestamp": <Unix 秒>, "source": { "type": "npm" }, "engines": { "dsh": ">=0.2.1-rc.2 <0.3.0-0" } }
   ```

3. 提交并推送，Pages 自动更新（`dsh-plugin-market` 有缓存，默认 10 分钟）。

## 关于 `engines.dsh`

`engines.dsh` 决定 Discover 里的兼容性判断。插件使用 Typert Remote 与
`ctx.subprocess`/`ctx.llm`/`ctx.workspaceRegistry`，已在 DSH `0.2.1-rc.3` 上验证；
当前写的是 `>=0.2.1-rc.2 <0.3.0-0`，如果后续验证了更宽的范围可以放宽。
