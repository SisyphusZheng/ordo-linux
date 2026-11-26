# 本地 Portage overlay

本 overlay 只放**上游没有打包**的包。能用 GURU 或主树装的，一律不复制进来。

## 当前内容

```
gui-apps/luciole/
├── Manifest
└── luciole-0.1.0.ebuild

app-crypt/libsecret/
├── Manifest
├── files/                上游补丁
└── libsecret-0.21.8.2-r100.ebuild
```

## luciole

Luciole 是 Noctalia 套件的文件管理器。本地配方固定到构建 Ordo Linux 0.1.0 随附二进制包时使用的源码提交。仓库同时分发该提交归档与 ebuild 的校验清单。[Luciole 源码提交](https://github.com/noctalia-dev/luciole/tree/bae75c541ce1d863438d013f1f157b0db85e87df)

升级时选定新的完整提交 ID，更新 `LUCIOLE_COMMIT`，验证归档来自该提交，再运行 `ebuild luciole-0.1.0.ebuild manifest`。将配方与新清单一起提交。归档的本地文件名带完整提交 ID，避免复用版本号对应的旧归档。

### 打包时踩过的包名错误

| 上游 meson 依赖 | 正确 Gentoo 包 |
|---|---|
| `libacl` | `virtual/acl` |
| `libarchive` | `app-arch/libarchive` |
| `liblzma` | `app-arch/xz-utils` |
| `meson >=1.1` | `dev-build/meson`（BDEPEND 不能带版本限制） |

## 启用

将本目录完整部署到 `/var/db/repos/local`，并在 `/etc/portage/repos.conf/local.conf` 将其注册为 `local` 仓库。部署时保留已提交的 `Manifest`，使离线镜像上的 Portage 同样能够识别配方。

## 目录约定

```
overlay/
├── metadata/layout.conf      masters = gentoo
├── profiles/repo_name        local
└── gui-apps/<pkg>/
    ├── <pkg>-<ver>.ebuild
    └── files/                随源码安装的附属文件（如 initd 脚本）
```

## libsecret

Ordo 保留桌面程序依赖的 libsecret 客户端库。
本地 `0.21.8.2-r100` 来自 Gentoo `5612e759ddbb58ff224546966df19866d460a93f` 的 `0.21.8.2-r1`。
沿用原许可和源码，移除自动安装 Secret Service 服务的 `PDEPEND`。补丁随上游
**LGPL-2.1** 分发，全文见 `licenses/LGPL-2.1.txt`。升级配方时重新校验 Manifest 和无密钥服务的依赖闭包。
