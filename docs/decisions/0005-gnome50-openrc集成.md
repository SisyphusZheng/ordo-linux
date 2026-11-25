# ADR 0005 — GNOME 50 在 OpenRC 上的集成方式

- 状态：已采纳
- 日期：2026-11-18
- 背景：L1 验收期间 GDM 登录框长期不可见，排查跨十余层后定位并修复

## 一、问题陈述

现象：系统能开机、ZFSBootMenu 正常、内核与 OpenRC 正常、GDM 起来了、GNOME Shell
渲染出壁纸和顶栏时钟，**但没有密码输入框**——用户无法登录。

该现象具有误导性：shell 进程存活、时钟运行、会话 `Active=yes`、seat 正常、
AccountsService 可枚举用户。所有「服务是否运行」的检查均通过，但 UI 缺少该部分。

## 二、根因

`install.sh` 的品牌替换段把 **3840×2160 的壁纸**复制成了 GDM 的 logo 文件
`/usr/share/pixmaps/gentoo-gdm.svg`，并把它设为 `org.gnome.login-screen logo`。

GDM 的 LoginDialog 这样加载 logo：

```js
const texture = this._textureCache.load_file_async(
    this._logoFile,
    -1, -1,              // ← 宽高 -1 = 不缩放，按原始像素
    scaleFactor, resourceScale);
this._logoBin.add_child(texture);
```

于是 4K 壁纸被塞进 `login-dialog-logo-bin`，该 actor 撑到 `3840×2160`、
定位 `(-1185, -1280)`，**完全覆盖整个登录对话框**。

探针实测（automation-script，greeter 会话内）：

```
login-dialog-logo-bin  sz=3840x2160  pos=-1185,-1280  vis=true
  child[0] Clutter_Actor  sz=3840x2160
login-dialog-user-selection-box  pos=551,310  sz=367x304  vis=true   ← 被盖住
```

对话框本身完全健康（`visible=true opacity=255 mapped=true`），只是被自己那个
超大 logo 盖住了。

## 三、决策

### 3.1 品牌替换必须区分"壁纸"与"图标"

| 资产类型 | 尺寸约束 | 用途 |
|---|---|---|
| 壁纸 | 3840×2160（原始） | `/usr/share/backgrounds/ordo/` |
| logo / 图标 | ≤ 256×256 | `/usr/share/pixmaps/`、GDM login-screen |

**规则**：任何往 `pixmaps/` 或 `org.gnome.login-screen logo` 写的东西，
必须是真正的小图标。壁纸永远不进 logo 槽位。

### 3.2 GDM 配置走 dconf，不覆盖 `custom.conf`

原先 `printf ... > /etc/gdm/custom.conf` 会整体覆盖，抹掉所有其他 GDM 配置。
改为：`custom.conf` 写完整模板；logo/主题等行为配置走
`/etc/dconf/db/local.d/` + `dconf update`。

### 3.3 greeter 的 dconf profile 必须包含 `system-db:local`

GDM 的 profile 装在 `/usr/share/dconf/profile/gdm`，但 dconf 只读
`/etc/dconf/profile/`；且默认内容只有 `user-db:user` +
`file-db:greeter-dconf-defaults`，**不含 `system-db:local`**。
不加这两项，系统级壁纸/登录屏配置对 greeter 完全无效。

### 3.4 用 Gentoo 标准 `display-manager` 机制

不手写 `/etc/init.d/gdm`。装 `gui-libs/display-manager-init`，
`/etc/conf.d/display-manager` 里写 `DISPLAYMANAGER="gdm"`，
`rc-update add display-manager default`。

## 四、GNOME 50 + OpenRC 的六条硬性要求

这些不是"优化"，是**不满足就起不来**：

1. **用户 `dbus` 服务进 boot runlevel**
   `gdm-wayland-session` 的 `spawn_bus()` 先 `g_bus_get_sync(G_BUS_TYPE_SESSION)`；
   若 `/run/user/$uid/bus` 不可用就自建 `/tmp/dbus-xxx` 临时总线。
   临时总线在会话启动早期被关闭，shell 报「连接已关闭」，登录框逻辑全部失效。
   → 给 `gdm-greeter` 与普通用户的**用户级** boot runlevel 加 `dbus`。

2. **`pam_openrc.so` 必须在 PAM 栈末尾**
   夹在 `pam_elogind` 之前时 `/run/user/$uid` 尚未就绪。
   （上游 `gnome-session-openrc` README 明确要求"append"。）

3. **`rc/bin/*` 必须能从 `/bin` 找到**
   非 TTY 环境下 OpenRC 的 `functions.sh` 会把 `ebegin`/`eend`/`service_set_value`
   委托给外部二进制；用户服务的 PATH 不含 `/usr/libexec/rc/bin`，
   导致 `ebegin: 未找到命令` 并把服务判死。

4. **`gnome-settings-daemon` 聚合服务不能声明 supervisor**
   上游脚本有 `supervisor=supervise-daemon` 却无 `command=`，
   聚合服务永远无法启动，连带 `gnome-session.gnome-login` 失败。

5. **`gnome-session-dbus.gnome-session` 符号链接**
   裸 `gnome-session` 服务 `need` 它；缺失会报
   `needs non existent service 'gnome-session-dbus.gnome-session'`。

6. **theme CSS 需要文件系统兜底**
   `_getStylesheet()` 先查 `resource://`，失败后回退到
   `$datadir/gnome-shell/theme/`。Gentoo 只装 gresource 不装松散文件，
   且 GNOME 50 的 gresource 里只有 `-dark/-light/-high-contrast` 变体，
   缺 `gnome-shell.css`。补一份落地文件可避免主题加载抛异常导致 UI 无样式。

## 五、诊断方法论（可复用）

这次排查花了很久，因为**绝大多数检查都返回"正常"**。真正定位靠的是：

**在 shell 进程内部跑探针**，而不是从外面猜。

gnome-shell 支持 `--automation-script <file>`，脚本以 ES module 形式
在 shell 上下文执行，可以直接 `import * as Main from
"resource:///org/gnome/shell/ui/main.js"` 读取任意内部状态。

```js
import GLib from "gi://GLib";
import * as Main from "resource:///org/gnome/shell/ui/main.js";

export function init() {
    GLib.timeout_add(GLib.PRIORITY_DEFAULT, 14000, () => {
        const d = Main.screenShield?._dialog;
        const out = [
            `isGreeter=${Main.sessionMode.isGreeter}`,
            `dialog.visible=${d?.visible}`,
            `dialog.opacity=${d?.opacity}`,
        ];
        for (let i = 0; i < (d?.get_n_children() ?? 0); i++) {
            const c = d.get_child_at_index(i);
            out.push(`  [${i}] ${c.constructor.name} style=${c.style_class} ` +
                     `sz=${c.width}x${c.height} pos=${c.x},${c.y} vis=${c.visible}`);
        }
        GLib.file_set_contents("/var/lib/gdm-greeter/probe.txt", out.join("\n"));
        return GLib.SOURCE_REMOVE;
    });
}
```

该方法将不可见的 UI 转为可读的 actor 树，可直接观察到 logo 占满屏幕。

结论：外部观测全部正常但现象仍错误时，应停止增加外部检查，
改为在被怀疑的进程内部取状态。

## 六、后果

- 登录框正常显示，重启后保持（已验证）
- `install.sh` §13 与 §14 包含全部 9 项修复
- `docs/deviations.md` 记录 #15–#23
- greeter 壁纸暂未生效（GNOME 50 的 `SystemBackground` 在启动早期缓存背景，
  改 gsettings 不触发重绘）—— 不影响登录，留作后续美化项
