# AGENTS.md

本仓库是 Ordo Linux 的系统定义。修改本仓库等同于修改一个 Gentoo 系统的定义。

## 分层原则

```
core（Portage）        oneconfig / 薄 / 安全 / 一切皆文件      ← 纯度要求只在此层
application（Flatpak） 允许不纯粹（dconf / 二进制配置 / 沙箱内部状态）
```

「一切皆文件」只约束 core：core 中每个配置须为可 diff、可编辑、可版本控制的纯文本。
应用层的 dconf 与缓存不受此约束，属 Flatpak 的固有成本。

判定某组件是否属于 core：需要审计或修改的进 core，否则走 Flatpak。

## 修改路径

```
1. 改 config/ 下的声明文件
2. ordo config apply <module>     # 或手动 deploy 到目标机
3. ordo doctor                    # 验收
```

不直接修改 `/etc`；`emerge` 后须同步 `config/world`。`config/` 是唯一事实来源。

## 目录职责

| 路径 | 内容 | 约束 |
|---|---|---|
| `config/world` | core 包集 | **只允许裸 atom**（注释放 `world.notes`）；应用级大件不进（走 Flatpak） |
| `config/world.notes` | world 的理由与注解 | 进 Portage 的不是这个文件 |
| `config/oneshot-packages` | 刻意不进 world 的引导工具 | 每条附理由 |
| `config/apps.d/` | Flatpak 应用清单 | 首启装哪些；`00-core` 必装 |
| `config/migrations/` | 增量升级脚本 | `<unix 时间戳>-<名>.sh`，幂等 |
| `config/desktop/` | 桌面配置总目录 | 见该目录的 README；含 umbriel / noctalia / greetd / skel / wallpapers |
| `tests/` | 回归用例 | 每个修复带一条 |
| `docs/manual/` | 用户手册 | 面向使用者，不含实现细节 |
| `config/package.use/` | USE flag | 每行一个包，附原因注释 |
| `config/package.accept_keywords/` | keyword 例外 | 尽量少，每个都要有理由 |
| `config/make.conf.example` | 编译配置 | 与 `config/arch` 联动 |
| `config/arch` | 架构数据 | stage3 URL / -march / VIDEO_CARDS |
| `config/dataset` | ZFS 布局 | install.sh 与 doctor 共读 |
| `config/desktop/umbriel/` | Umbriel 合成器与会话脚本 | TOML / sh |
| `config/desktop/skel/` | 用户 dotfiles 模板 | 纯文本 |
| `install.sh` | 从零安装 | 幂等，失败即停 |
| `scripts/doctor` | 漂移检查 | 每项都要有判据 |
| `scripts/ordo-config` | OneConfig 入口 | show/verify/apply/diff/path |

## 验收命令

```sh
make check          # 提交门禁：lint + 回归测试 + CLI 自检
make verify         # 声明 vs 本机实际状态（在真机上跑）
make lint           # 只跑静态检查（秒级）
```

单独跑：

```sh
sh tests/lint.sh                       # 语法 + shellcheck + 配置解析 + 声明层格式
sh tests/run-all.sh                    # L1 + L2 全部用例
sh scripts/ordo-selfcheck              # usage × case × 软链 三方一致
sh scripts/doctor                      # 全系统健康检查（0/1/2 三态）
sh scripts/ordo-config verify          # 声明漂移（0/1/2 三态）
umbriel config validate
```

退出码约定：`0` 通过 / `1` 有问题 / `2` 无法判定。
`2` 不等于通过；脚本中不可用 `if ! cmd` 将 2 视为 0。

任何改动后须执行 `make check`。修复缺陷时同 commit 提交回归用例。

## 桌面栈

Noctalia 全家桶：五件套同源，共用壁纸、调色板与配置语言。

| 职责 | 组件 | 语言 | 备注 |
|---|---|---|---|
| 合成器 | Umbriel | C++23 | wlroots + umbrielfx；四种布局 |
| 外壳 | Noctalia Shell | C++23 | 顶栏/启动器/控制中心/通知/锁屏/壁纸/剪贴板/OSD/托盘 |
| 文件管理 | Luciole | C++23 | 图形；同时作为门户的文件选择器 |
| 登录 | greetd + Noctalia Greeter | C / C++23 | 图形登录，自带 wlroots 合成器 |
| 门户 | xdg-desktop-portal-umbriel | C++23 | 截图、录屏、文件选择 |
| 配色 | Noctalia `theme.source = "wallpaper"` | — | 从壁纸提取，无独立调色板文件 |
| 音频 | pipewire + wireplumber | C | Noctalia 的音量 OSD 依赖 |
| 终端 | wezterm | Rust | 主终端 |
| 输入法 | fcitx5 + rime | C++ | `GTK_IM_MODULE=wayland`（text-input-v3） |
| 截图 | grim + slurp | C | 键位直接调用 |
| 媒体键 | playerctl | Rust | `noctalia msg media` 当前版本不可用 |
| Flatpak 商店 | Warehouse | Python | 由 Noctalia 启动器拉起 |

## 约束

以下为硬性约束，`doctor` 或测试中有对应判据：

| 约束 | 判据 |
|---|---|
| `/etc/portage` 不得使用宽泛 keyword（全局 `**`），只允许逐包 | `doctor`：`ACCEPT_KEYWORDS` 检查 |
| `world` 不得包含应用级包（浏览器、办公、IM、编辑器 → Flatpak） | `doctor` + `config/forbidden-world` |
| 不得引入第二套回滚机制 | `doctor`：检测 snapper/timeshift/btrfs |
| 不得引入 systemd 依赖 | `doctor`：`/proc/1/comm` |
| 不得恢复 `config/kde/` | `tests/cases/090` |
| 不得在 `zfs_arc_max=0` 时编译高内存占用包 | `doctor`：读 sysfs |
| `MAKEOPTS` 的 `-j` 不得超过 `nproc` | `doctor`：比较两者 |
| `config/world` 不得含行内注释 | `tests/lint.sh` |
| 无法判定时须 `exit 2`，不得输出通过 | `tests/cases/020` |
| 不得同时安装两套同类组件 | `doctor` |
| 脚本定位同级文件须用 `readlink -f`，不得用裸 `$(dirname "$0")` | `tests/cases/010` |

## 偏离登记

见 `docs/deviations.md`。新增偏离须先登记后实施。

## 环境限制

| 限制 | 原因 |
|---|---|
| Hyprland 全家桶不可用 | 15 个包均不在 Gentoo 树 |
| dconf 二进制 | 由 GTK 应用（portal-gtk）写入 |
| Umbriel 为 pre-release | 配置键名可能在小版本间变动，升级前看上游 changelog |
| Luciole 无发布 tag | ebuild 用 `archive/main` 快照，升级需改 `LUCIOLE_COMMIT` |
| `make test` 的 040/190 在 macOS 宿主必红 | bash 3.2 把紧贴 `$var` 的全角字符并入变量名（如 `"…$_set_dir（需要 root）"`）；Linux VM bash 5 正常 |

编译前须确认 `zfs_arc_max` 非零且 `MAKEOPTS` 的 `-j` 不超过 `nproc`。
ARC 未限时编译高内存占用包会触发 direct reclaim：vCPU 满载但磁盘无写入、
网络无响应。见 `docs/deviations.md` #48。

## 提交规范

- 一个逻辑改动一个 commit
- 配置改动必须同 commit 带上验收结果或说明为何未验
- 删除文件必须在 commit message 说明理由
