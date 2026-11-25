# 贡献指南

> 本仓描述一台具体机器，不是可插拔的组件集合。
> 这里的改动会直接作用于作者的日常系统。

## 提交前检查

```sh
make check      # lint + 测试 + CLI 自检
make verify     # 声明 vs 本机实际状态（在真机上跑）
```

3. 在 commit message 中附验收输出，或说明未验证的原因。无证据的配置改动不合入。

## 改动位置

| 你想改 | 改这里 | 不要改 |
|---|---|---|
| 装哪些包 | `config/world`（裸 atom，无注释） | 不要直接 `emerge` 后忘记同步 |
| 包怎么编 | `config/package.use/<文件>` | 不要在 `make.conf` 里加宽泛开关 |
| 桌面长什么样 | `config/desktop/umbriel/*` + `config/desktop/noctalia/*` | 部署是软链，改 `~/.config` 等于改仓库 |
| 系统行为 | `scripts/*` | 不要把业务逻辑塞进 `ordo`（它是委托层） |
| 「为什么这么选」 | `docs/decisions/NNNN-*.md`（ADR） | 不要只写在 commit message 里 |
| 「这里妥协了」 | `docs/deviations.md`（先登记再动手） | 不要静默忍受 |

## 硬性规则

1. core 层一切皆文件：`config/` 中每个配置须可 diff、可编辑、可版本控制。
   Flatpak 应用内部的 dconf 与缓存不在此列。
2. 一个逻辑改动一个 commit。配置改动同 commit 附验收结果。
3. 新增偏离须先登记 `docs/deviations.md`（含收回条件），再实施。
4. 删除文件须在 commit message 中说明理由。
5. 不得引入：第二套回滚机制、systemd 依赖、全局宽泛 keyword、world 中的应用级包。

## 新增命令

1. 在 `scripts/` 写脚本，首行 `#!/bin/sh`，头部注释说明用途与退出码。
2. 在 `scripts/ordo` 的 `usage()` 里加一行，在 `case` 里加一个分支（`_dispatch`）。
3. 如果是用户会直接敲的命令，在 `install.sh` 的入口白名单里加一行。
4. 执行 `sh scripts/ordo-selfcheck`，它检查这三处是否一致。

## 新增迁移

已装机系统获取 `config/` 变更的路径为 `config/migrations/`：

```sh
# 文件名 = <unix 时间戳>-<短描述>.sh
name="$(date +%s)-my-change.sh"
```

要求：幂等、POSIX sh、只调用 `ordo` 子命令或做文件级操作。契约见该目录 README。

## 新增测试

修复缺陷时，同一 commit 须附一条回归用例：

```sh
tests/cases/<编号>-<描述>.sh
```

用例须能在开发机（macOS/Linux）运行，不依赖 ZFS、合成器、Gentoo。

## 报告问题

需提供三项：可复现的命令、实际输出、期望输出。
提交前先查阅 `docs/deviations.md`，其中记录了已确认的非常规行为。
