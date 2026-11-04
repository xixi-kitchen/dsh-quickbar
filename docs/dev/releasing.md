# 发版

前置：在仓库根、工作区干净、`bash native/check.sh` 全绿。

## 1. 版本与变更

```sh
# 改 package.json version（例如 0.2.1）
# 改 CHANGELOG.md：新增一节，说明交互/修复
```

## 2. 市场索引

编辑 `docs/index.json`，把 `plugins[0].versions` 换成新版本（`publishTimestamp`
发布后再填真实值）：

```json
{ "version": "0.2.1", "publishTimestamp": 0,
  "source": { "type": "npm" },
  "engines": { "dsh": ">=0.2.1-rc.2 <0.3.0-0" } }
```

## 3. 提交与标签

```sh
git add -A && git commit -m "release: 0.2.1"
git tag -a v0.2.1 -m "dsh-quickbar 0.2.1"
git push origin main --tags
```

## 4. npm 发布（账号开了发布 2FA）

```sh
npm publish --cache /tmp/npm-cache --otp=<6位验证码>
```

- `~/.npm` 缓存有 root 归属文件时，必须带 `--cache /tmp/npm-cache`；
- 24 小时内不能覆盖同一版本，小修就发 `0.2.1`；
- 2FA 发布可能留下一个 `0.0.0-stage` 占位版本（`latest` 不受影响），
  可 `npm unpublish dsh-quickbar@0.0.0-stage --otp=…` 清掉。

## 5. 回填索引时间戳

```sh
npm view dsh-quickbar time --json --cache /tmp/npm-cache
# 把 0.x.y 的 ISO 时间转成 epoch 秒填进 docs/index.json，再 commit + push
```

GitHub Pages（`main` 分支 `/docs`）会自动刷新；验证：

```sh
curl -s https://xixi-kitchen.github.io/dsh-quickbar/index.json | head -3
```

## 6. 验证发布产物

```sh
npm view dsh-quickbar version engines dist.tarball --cache /tmp/npm-cache
curl -sI "$(npm view dsh-quickbar dist.tarball --cache /tmp/npm-cache)" | head -1
```

建议再做一次「从 npm 真装」的隔离验证（见 [testing.md](testing.md) 第 3 节，
依赖改成 `"dsh-quickbar": "0.2.1"` 并 `npm install`），确认二进制可执行位与启动正常。
