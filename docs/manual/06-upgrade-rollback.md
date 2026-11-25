# 06 · 升级与回滚

> 本章说明升级流程、回滚机制与快照策略。

## 升级

```sh
doas ordo sysup
```

它会按顺序做这些事，任何一步失败就停下来并告诉你怎么办：

1. 检查编译并行度、ZFS ARC 上限和池空间（可用空间低于 4 GiB 时会提示）
2. 给**当前运行的数据集**打快照 `@pre-update-<时间戳>`
3. 用 `zfs hold` 钉住这个快照（防止被自动轮转删掉）
4. `emerge --sync` → `emerge -uDN @world`
5. 运行待执行的迁移（`ordo migrate`）
6. 检查最新已安装内核的 initramfs 和对应 ZFS 模块，以及当前启动环境的 ZFSBootMenu 属性
7. 全过才释放 hold；不过则保留 hold 并告诉你

先看看会发生什么（不改任何东西）：

```sh
doas ordo sysup --dry-run
```

## 升级炸了怎么办

`sysup` 失败时会直接打印路径，大致是：

```
 1. 重启 → 进入 ZFSBootMenu
 2. 在菜单里选中当前 BE
 3. 按 Ctrl+S 进入快照子菜单
 4. 选中 pre-update-20261121-113000
 5. 按 Ctrl+X（clone and promote）→ 得到可启动的影子系统
 6. 启动该影子系统，在其中执行: ordo snap rollback pre-update-20261121-113000
```

**为什么不能就地回滚**：ZFS 拒绝回滚正在被挂载使用的数据集。
所以必须先从 ZBM 引导快照（作为一个临时 clone 启动），在**那个**环境里
才能把回滚做完。这不是 Ordo 的限制，是 ZFS 的语义。

## 快照

```sh
ordo snap list                    # 看所有快照（按类型分组）
doas ordo snap create 改配置前     # 手动打一个
doas ordo snap delete 改配置前     # 删一个
ordo snap identity                # 我到底跑在哪个数据集上？
```

自动快照三档（`ordo snap auto on` 启用后由 cron 每小时跑）：

| 类型 | 频率 | 保留 |
|---|---|---|
| `@auto-hourly-*` | 每小时 | 24 个 |
| `@auto-daily-*` | 每天 03:xx | 7 个 |
| `@auto-weekly-*` | 每周一 04:xx | 4 个 |
| `@manual-*` | 手动 | 永不自动删 |
| `@pre-update-*` | 升级前 | 永不自动删 |

## 备份（和快照不是一回事）

**快照和你的数据在同一个池里**——池坏了，快照跟着一起没。真正的备份必须离池。

```sh
doas ordo backup send /mnt/usb         # zfs send 到外置盘
ordo backup list
doas ordo backup verify /mnt/usb/xxx.zfs
```

`ordo backup` 刻意做了这些保守选择：先写 `.part` 再改名、目标已存在拒绝覆盖
（要 `--force`）、发送前算大小、**绝不自动删备份**。

## 回滚后系统"名字不对"是正常的

回滚会 clone 出一个新数据集（`rpool/root/ordo-rb-<时间戳>`），
系统就跑在那个上面。此时：

- `RUNNING_ROOT` = 实际在跑的数据集（所有快照/升级的对象）
- `DATASET` = 配置里的规范名（`config/dataset`）

`ordo doctor` 会提示"身份漂移"，这是**回滚后的正常状态**。
要规范化回原名，`ordo snap rollback` 的输出里给了两条路径（A：改名回原名；
B：接受临时名）。选一条，别两条都抄——它们互斥。
