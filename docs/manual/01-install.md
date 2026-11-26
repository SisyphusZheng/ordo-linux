# 01 · 安装

> 前提：一台能启动 USB 的机器（当前验证范围：arm64 VM；x86_64 参数化就绪但未实测）。

## 快速安装

```sh
# 1. 从 Gentoo minimal ISO 启动，确认联网
ping -c1 mirrors.ustc.edu.cn

# 2. 拿到仓库
git clone https://github.com/ordo-linux/ordo /root/ordo
cd /root/ordo

# 3. 装（会抹掉目标磁盘，需输入 yes 确认）
sh install.sh /dev/vda
```

安装前确保目标磁盘已卸载，安装目录为空。装完后重启，从 ZFSBootMenu 选择新环境。

## 参数

第一个位置参数指定磁盘。其他设置通过环境变量传入。

| 变量 | 默认 | 说明 |
|---|---|---|
| `<第一个位置参数>` | `/dev/vda` | 目标磁盘（会被**完全抹除**） |
| `ORDO_ARCH` | `arm64` | `arm64` 或 `amd64` |
| `ORDO_PLATFORM` | `vm` | `vm` 或 `bare-metal`（后者启用 WiFi/固件/微码） |
| `ORDO_USER_PASSWORD` | 随机 | 用户 `ordo` 的密码；不设则随机生成并只打印一次 |
| `ORDO_ROOT_PASSWORD` | 未设 | 不设则锁定 root 密码登录 |
| `ORDO_DOAS_NOPASS` | `0` | 设 `1` 则 doas 免密（仅建议一次性 VM） |
| `ORDO_SSH` | `0` | 设 `1` 才启用 sshd |
| `ORDO_STAGE3_GPG_FPR` | Gentoo 自动周构建发布主钥的指纹 | 更换受信发布密钥时使用完整指纹 |
| `ORDO_LAYOUT_ONLY` | `0` | 设为 `1` 只建立磁盘布局并解包 stage3，完成后导出池 |

例子：

```sh
# x86_64 真机，指定密码
ORDO_ARCH=amd64 ORDO_PLATFORM=bare-metal ORDO_USER_PASSWORD='改成你的' \
  sh install.sh /dev/nvme0n1
```

## 它到底做了什么

1. 确认目标是未挂载的整块磁盘，并检查 Live 环境工具和编译条件
2. 在写盘前验证 Gentoo 签名摘要并校验 stage3
3. 重建磁盘分区（ESP 512 MiB，其余给 ZFS），创建池和数据集
4. 把 `config/` 铺进目标系统
5. 进入 chroot，同步 Portage，注册本地 overlay，并按声明包集安装
6. 配置 dracut initramfs、ZFSBootMenu、EFI 启动项
7. 建用户、配 doas、装桌面栈、装 Flatpak 应用清单
8. 部署 `ordo` CLI 并**当场自检**（跑不通就中止）
9. 干净卸载并导出 pool

## 装完立刻该做的

```sh
ordo doctor        # 看有没有 ✘
ordo info          # 确认版本与数据集
```

## 常见失败

| 现象 | 原因 | 处理 |
|---|---|---|
| `Live 环境缺少依赖` | Live 环境缺少分区、OpenPGP 或 ZFS 工具 | 补齐提示中的工具后重试 |
| `池已导入` | 当前 Live 环境已经导入目标名称的池 | 核对该池的归属并导出，再重新确认安装盘 |
| `stage3 SHA256 不匹配` | 镜像损坏或被篡改 | 换镜像重试；**不要**跳过校验 |
| `PROFILE 为空` | 非预期调用方式 | 用 `sh install.sh` 而不是 `source install.sh` |
| chroot 内 `emerge` 失败 | 网络、镜像或依赖解析出错 | 根据 Portage 的报错处理。重新运行整个安装器会重新分区 |
| 装完 `ordo` 跑不起来 | CLI 安装段失败 | 脚本会在这一步 `die`；看 `/opt/ordo/scripts` 是否完整 |
