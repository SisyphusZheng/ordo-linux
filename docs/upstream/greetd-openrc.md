# 上游待提交：gui-libs/greetd 缺少 OpenRC 服务

状态：材料已备，未提交。
关联 bug：https://bugs.gentoo.org/977631（2026-06-18，仍 UNCONFIRMED，assigned to ajak）

## 一、现有 bug 的诊断不完整

#977631 的标题与正文主张：

> Greetd cannot be set as the login display manager on openrc profiles without
> gui-libs/display-manager-init installed, but there is no dependency to
> automatically pull it in.

实测结论：**问题不在依赖，而在 ebuild 的 `src_install()` 没有安装 OpenRC 服务文件。**

证据：

1. 本机 `gui-libs/display-manager-init` 已安装，`greetd` 仍无 `/etc/init.d/greetd`。
2. `display-manager` 服务通过 `DISPLAYMANAGER` 变量与 `/usr/bin/startDM` 驱动，
   而 `startDM` 期待一个可在前台运行的 DM 二进制；`greetd` 是守护进程，
   需要 supervisor（`supervise-daemon`）包装，二者语义不同。
3. 因此仅添加 `display-manager-init` 依赖并不能让 greetd 启动。

## 二、三条验证

### ① 可引用的源码行号

`gui-libs/greetd/greetd-0.10.3-r1.ebuild`：

```
inherit cargo optfeature pam systemd
```

```
src_install() {
	dobin "$(cargo_target_dir)"/{agreety,fakegreet,greetd}

	insinto /etc/greetd
	doins config.toml

	systemd_dounit greetd.service

	doman ...
}
```

`systemd_dounit` 是唯一的服务安装调用，无 `newinitd`。
`inherit` 中无 `openrc`（Gentoo 无此 eclass，其他包直接调 `newinitd`）。

对比正确的写法，`gui-libs/display-manager-init` 的 `src_install()`：

```
newinitd "${FILESDIR}"/display-manager-setup.initd-r1 display-manager-setup
newinitd "${FILESDIR}"/display-manager.initd-r6 display-manager
newinitd "${FILESDIR}"/xdm.initd xdm
newconfd "${FILESDIR}"/display-manager.confd display-manager
```

### ② 干净环境复现

```
$ grep -c "etc/init.d" /var/db/pkg/gui-libs/greetd-0.10.3-r1/CONTENTS
0

$ cat /proc/1/comm
init

$ cat /var/db/pkg/gui-libs/greetd-0.10.3-r1/USE
arm64 elibc_glibc kernel_linux
```

安装完成后系统中不存在 greetd 的 OpenRC 服务，且无任何警告。

### ③ 排除自身配置问题

- `make.conf` 中 `USE="-systemd elogind ..."`，未启用 systemd
- PID 1 为 `init`（OpenRC），非 systemd
- 系统为 arm64，但问题与架构无关（ebuild 无条件只调 `systemd_dounit`）
- 已在干净安装的 L1 系统上复现两次（首次安装、重启后确认）

## 三、建议的 patch

新增文件 `gui-libs/greetd/files/greetd.initd`：

```sh
#!/sbin/openrc-run
# greetd 的 OpenRC 服务。行为对应上游 greetd.service：
#   Type=simple / Restart=always / Alias=display-manager
#
# greetd 自行管理 VT 切换（config.toml 的 [terminal] vt），
# 不经 display-manager 包装脚本。本服务 provide display-manager，
# 因此与 /etc/init.d/display-manager 互斥。

description="Greeter daemon (login manager)"
supervisor="supervise-daemon"
command="/usr/bin/greetd"
command_args="-c /etc/greetd/config.toml"
command_user="root"
respawn_delay=1
respawn_max=5
respawn_period=30

depend() {
    need localmount dbus
    after bootmisc
}
```

ebuild 中 `src_install()` 增加一行：

```
	newinitd "${FILESDIR}"/greetd.initd greetd
```

## 四、提交方式建议

不要新开 bug，在 #977631 下补充：

```
上文诊断的依赖缺失并非根因。display-manager-init 安装后 greetd 仍无
/etc/init.d/greetd，因为 ebuild 的 src_install() 只调用 systemd_dounit。

此外 display-manager 通过 startDM 启动，期待前台运行的 DM 二进制，
而 greetd 是守护进程，需要 supervise-daemon 包装，二者不能直接对接。

附件为 greetd.initd 与 ebuild 的一行改动，供参考。
```

## 五、注意事项

- `depend()` 中的 `need dbus` 与 `elogind` 需按实际讨论决定；上游 unit 只有
  `After=getty@tty1.service` 与 `Conflicts=getty@tty1.service`。
- OpenRC 下 VT 抢占需确认：greetd 会自行 `VT_ACTIVATE`，与 getty 冲突时
  可能需要 `Conflicts` 的等价处理（OpenRC 无此机制，需在 initd 中 `after getty` 或
  由 `provide display-manager` 表达）。
- 提交前应在一个全新 OpenRC Gentoo 环境验证 patch 可用。
