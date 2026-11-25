# 09 · x86 真机安装

> 前提：一台 x86_64 机器（Intel/AMD 均可），能插 U 盘启动。
> 当前走「Gentoo 官方 ISO + Ordo 仓库」路径（L2 的 Ordo ISO 会简化这一切）。
> **从零编译约 24 小时**，这是 L2 binhost 未落地前的现实。

## 0. 准备（在现有电脑上做）

```sh
# 下载 Gentoo amd64 minimal ISO
curl -LO "https://mirrors.ustc.edu.cn/gentoo/releases/amd64/autobuilds/current-install-amd64-minimal/$(curl -sL https://mirrors.ustc.edu.cn/gentoo/releases/amd64/autobuilds/current-install-amd64-minimal/ | grep -oE 'install-amd64-minimal-[0-9T]+Z\.iso' | head -1)"

# 写入 U 盘（macOS，把 /dev/diskN 换成你的 U 盘）
diskutil list
sudo dd if=install-amd64-minimal-*.iso of=/dev/rdiskN bs=4m

# 把 Ordo 仓库也拷到 U 盘（或稍后 git clone）
cp -r linux-dis /Volumes/<U盘名>/ordo-repo
```

## 1. 从 U 盘启动

开机按 F12/F2/Delete 进 BIOS → 选 U 盘启动 → 选 `Gentoo Linux` 回车。

## 2. 联网（关键步骤）

```sh
# 有线：通常自动 DHCP
ping -c1 1.1.1.1

# WiFi（如果有线不可用）
nmcli device wifi list
nmcli device wifi connect "<SSID>" password "<密码>"
ping -c1 1.1.1.1
```

## 3. 拿到 Ordo 仓库

```sh
mkdir -p /root && cd /root
# 方式 A：从 U 盘拷
cp -r /mnt/cdrom/ordo-repo /root/ordo   # 路径按实际挂载点改
# 方式 B：git clone（需要网络）
git clone <你的仓库地址> /root/ordo
```

## 4. 确认目标磁盘

```sh
lsblk
# 注意：选对磁盘！安装会抹除整个盘
# 常见：/dev/nvme0n1（NVMe）或 /dev/sda（SATA）
```

## 5. 安装（一条命令，24 小时）

```sh
cd /root/ordo
ORDO_ARCH=amd64 ORDO_PLATFORM=bare-metal sh install.sh /dev/sda
```

**关键环境变量**：

| 变量 | 作用 |
|---|---|
| `ORDO_ARCH=amd64` | 用 x86 架构（stage3/profile/march/显卡全自动切） |
| `ORDO_PLATFORM=bare-metal` | 启用 WiFi/固件/电源/微码（默认 `vm` 会跳过） |
| `ORDO_VIDEO_CARDS="amdgpu radeonsi"` | 可选，按实际显卡（默认含 amdgpu/i915） |
| `ORDO_USER_PASSWORD='...'` | 可选，不设会生成随机密码并打印一次 |
| `ORDO_ROOT_PASSWORD='...'` | 可选，不设会锁定 root 口令（提权走 doas） |
| `ORDO_DOAS_NOPASS=1` | 可选，仅一次性 VM 用；默认 doas 需要密码 |

> **部分 NVMe 分区路径（已修）**：`install.sh` 现在会自动判断分区命名——
> `*nvme*` / `*mmcblk*` / `*loop*` 用 `${DISK}p1`，其他用 `${DISK}1`。
>
> ```sh
> case "$DISK" in
>     *nvme*|*mmcblk*|*loop*) PART_SEP="p" ;;
>     *)                      PART_SEP="" ;;
> esac
> DISK_P1="${DISK}${PART_SEP}1"
> ```
>
> 所以 `/dev/nvme0n1` 和 `/dev/sda` 都可以直接传，不用手改脚本。

## 6. 等待

- 约 24 小时（678 包源码编译）
- 重跑整个安装器会重新分区。中断后先保留目标盘并检查安装日志。
- **建议**：接电源、关睡眠（`sudo systemctl mask sleep.target` 不适用，用 `echo -n mem > /sys/power/state` 前先 `setterm -blank 0`）

## 7. 重启

```sh
reboot
```

拔掉 U 盘 → 应该进 ZFSBootMenu → 自动引导 → 中文 GDM。

## 8. 首次登录后

```sh
# 用户 ordo，密码 ordo（请立即改）
passwd

# 验证
ordo info
ordo doctor
```

## 常见问题

| 问题 | 原因 | 解决 |
|---|---|---|
| WiFi 连不上 | 缺固件 | 真机安装请用 `ORDO_PLATFORM=bare-metal`（会读 `config/world.bare-metal`）；或在 `config/world` 里加 `sys-firmware/linux-firmware` 后 `ordo config apply world` |
| 显卡没加速 | VIDEO_CARDS 不匹配 | 改 `config/arch` 的 VIDEO_CARDS 后重编 mesa |
| 蓝牙不工作 | 服务未启动 | `doas rc-update add bluetooth default` |
| 声卡无声 | 缺 UCM 配置 | `emerge media-sound/alsa-ucm-conf` |
| 触控板失灵 | 缺驱动 | 检查 `VIDEO_CARDS` 和内核模块 |

## 已知限制

- **没有图形安装器**（L2 才有）
- **24 小时编译**（L2 binhost 后降到 30 分钟）
- **需要一定 Linux 基础**（会 `lsblk`、会连 WiFi）
