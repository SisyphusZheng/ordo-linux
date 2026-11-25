# 07 · 配置与主题

## 心智模型

```
config/（仓库）  →  ordo config apply  →  你的机器
   ↑ 唯一事实来源                              ↓
   └────────────  ordo config verify  ←────────┘
                    （漂移检查）
```

**改仓库，然后 apply** —— 不要直接改 `~/.config` 后忘记回写。
否则下一次 `ordo config verify` 会告诉你漂移了，而你说不清哪边是对的。

## 配置命令

```sh
ordo config show              # 当前生效的配置（打印解析后的值）
ordo config verify            # 仓库 vs 实际，有漂移就报
doas ordo config apply world  # 按当前平台更新 @ordo-core
ordo config apply theme       # 已废弃（配色由 Noctalia 从壁纸提取）
ordo config apply desktop     # 把 Umbriel/Noctalia 配置部署到家目录
ordo config apply all         # 上面三个都做
ordo config diff              # 看具体差在哪
```

退出码：`0` 全绿 / `1` 有漂移 / `2` 无法判定（工具缺失等）。
**`2` 不等于通过** —— 这是刻意的。

更新包集后，可用 `doas emerge --noreplace @ordo-core` 安装或选中声明的包。旧版系统可能还直接选中了已从声明移除的包，`ordo config diff` 会列出这些选择。确认该包无需继续保留后，可通过 `doas emerge --deselect <atom>` 取消选择。

## 配色

配色由 Noctalia 从壁纸提取，不需要手写色值。换壁纸 = 换整套配色。

```toml
# ~/.config/noctalia/config.toml（软链到仓库）
[theme]
mode = "dark"
source = "wallpaper"
wallpaper_scheme = "m3-content"
pure_black_dark = true
```

可选提取算法：

| 值 | 效果 |
|---|---|
| `m3-monochrome` | 完全去色 |
| `m3-tonal-spot` | 只取一个色相做单色系 |
| `m3-content` | 从壁纸取主色，保留色相关系（默认） |
| `muted` | 低饱和 |
| `vibrant` | 高饱和 |
| `m3-fruit-salad` | 多色乱配，**会把界面染成暗红，别用** |

也可以在 Noctalia 的设置界面里改：右键顶栏 → Settings → Theme。

## 换壁纸

壁纸放在 `config/desktop/wallpapers/`，`install.sh` 会铺到
`/usr/share/backgrounds/ordo/`。在 Noctalia 设置里选择即可，
配色会跟着变。

## 改键位 / 窗口规则

```sh
vim config/desktop/umbriel/config.toml   # 改仓库里这份
ordo config apply desktop                # 部署（符号链接）
# 保存即生效，Umbriel 热重载 TOML
umbriel config validate                  # 校验语法
```

## 改完之后

```sh
make check                     # lint + 测试
ordo config verify             # 声明与系统是否一致
git add -A && git commit       # 配置改动请带上验收输出
```

## 常见误区

| 想法 | 现实 |
|---|---|
| "我直接改 `~/.config/umbriel/config.toml`" | 那是软链，改它等于改仓库；但会被 git 当成改动，**确认要提交再改** |
| "我在机器上 `emerge` 一下就行" | `doctor` 会报 world 漂移，`depclean` 可能拆掉它 |
| "手写一份配色表更可控" | 配色由 Noctalia 从壁纸生成，手写会在换壁纸时被覆盖 |
