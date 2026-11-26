# ADR 0014 — 二进制包签名策略

- 状态：已采纳
- 日期：2026-11-26
- 关联：ADR 0003、`config/platform/m2/install-native.sh`、`config/release/0.1.0/SOURCES`

## 一、问题陈述

ADR 0003 把远端 binhost 定为 GitHub Releases 上的静态 http 目录，该通道尚未实现，
`config/make.conf.example` 的 `BINHOST` 仍为空。M2 离线安装器另有一套本地二进制包：
`install-native.sh` 用 `PKGDIR=/var/tmp/ordo-native/binpkgs` 合并原生包，并在那次
emerge 调用里显式关闭 `binpkg-request-signature`。没有书面策略时，读者无法判断这是
刻意豁免还是漏配，也无法判断远端通道上线时应该打开什么。

## 二、决定

1. **远端 binhost**（ADR 0003 落地时）：每个 binpkg 由发布钥签名
   （`FEATURES=binpkg-signing`），客户端启用 `FEATURES=binpkg-request-signature`
   校验；公钥随发布清单分发，指纹固定。未满足该条件前 `BINHOST` 保持空。
2. **离线介质**（0.1.0 M2 USB）：不使用远端 binhost。本地 binpkgs 的完整性由签名
   发布清单 `config/release/0.1.0/M2-SHA256SUMS` + `M2-SHA256SUMS.sig` +
   `allowed_signers` 锚定整包。`install-native.sh` 的 FEATURES 覆盖只作用于那一次
   本地 merge，因此同一命令必须清空 `PORTAGE_BINHOST`，并使用 `--getbinpkg=n`
   与 `--usepkgonly`，保证不可能从远端拉取未签名包。
3. 两条路径互斥：任何禁用 `binpkg-request-signature` 的调用，若仍可访问远端
   binhost，即视为策略违规。

## 三、后果

- 离线安装不需要为本地包再签一次名；信任来自整包摘要签名。
- 远端通道上线时必须修改 `config/make.conf.example`，并同步本 ADR 与用例
  `tests/cases/373-binhost-signature-policy.sh`。
- `install-native.sh` 的 FEATURES 覆盖作用域是单次调用，目标系统
  `/etc/portage/make.conf` 里的远端策略不被改写。

## 四、证据

`install-native.sh` 的两次 emerge 都写成：

```sh
FEATURES="-binpkg-request-signature -getbinpkg -buildpkg" PKGDIR="$native/binpkgs" \
    EMERGE_DEFAULT_OPTS='' PORTAGE_BINHOST='' \
    emerge --ask=n --oneshot --usepkgonly --getbinpkg=n --with-bdeps=n "$@"
```

`config/make.conf.example` 当前为 `BINHOST=""`；`config/arch` 固定 stage3 验签指纹。
用例 373 对上述条件做机器检查。
