# 安全策略

## 报告漏洞

请勿提交公开 issue。使用 GitHub 私密安全公告（Security → Report a vulnerability），
或邮件联系维护者。

需提供：受影响组件与版本、复现步骤、影响范围。
预期：7 天内确认收到，30 天内给出结论。

## 安全模型

Ordo 是单用户桌面发行版。安全目标是：在默认配置下不因自身设计引入额外风险。
不覆盖有物理访问权的攻击者。

| 项 | 现状 | 说明 |
|---|---|---|
| root 登录 | 默认锁定（`passwd -l root`） | 提权走 doas；需要救援口令时设 `ORDO_ROOT_PASSWORD` |
| doas | 默认 `permit persist :wheel`（需密码） | `ORDO_DOAS_NOPASS=1` 才免密，且会打警告 |
| sshd | **默认不启用** | `ORDO_SSH=1` 才开 |
| 防火墙 | **未配置** | 已知缺口，见 `docs/deviations.md` |
| 供应链 | stage3 校验 PGP + SHA256 | 见 `install.sh` 的 stage3 段 |
| 回滚 | ZFS BE + ZFSBootMenu | 系统被改坏可回到上一环境 |
| Flatpak | 沙箱 + Flathub | 应用层默认走沙箱 |

未覆盖项：无防火墙规则、无 faillock、无完整性监控。登记于 `docs/deviations.md`。

## 支持的版本

仅 `version` 文件中的当前版本接受安全修复。
