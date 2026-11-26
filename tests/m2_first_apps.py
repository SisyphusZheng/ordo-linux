#!/usr/bin/env python3
"""P1-04：M2 首启必须消费 config/apps.d，按用户身份装到用户级 remote。

回归三个真实故障：
  1. remote 装成系统级、应用装成用户级 —— 用户级根本没有 flathub；
  2. 消费端只跳 # 开头的行 —— 带行内注释的一整行被当成 app id；
  3. M2 路径全文没有 apps.d —— 清单写了也无人执行。
"""
import os
from pathlib import Path
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]
PLATFORM = REPO / "config/platform/m2"
SCRIPT = PLATFORM / "first-apps.sh"

FLATPAK = r'''#!/bin/sh
printf '%s\n' "$*" >> "$FLATPAK_LOG"
case "$1" in
    remote-add) exit "${REMOTE_STATUS:-0}" ;;
    list) printf '%s\n' "$INSTALLED"; exit 0 ;;
    install)
        case "$*" in
            *"$FAIL_APP"*) exit 1 ;;
        esac
        printf '%s\n' "$*" >> "$INSTALLED_LOG"
        exit 0 ;;
esac
exit 1
'''


def run(tmp, **overrides):
    bins = tmp / "bin"
    bins.mkdir(exist_ok=True)
    tool = bins / "flatpak"
    tool.write_text(FLATPAK)
    tool.chmod(0o755)
    env = {
        "PATH": f"{bins}:{os.environ['PATH']}",
        "ORDO_APPS_DIR": str(tmp / "apps.d"),
        "ORDO_FIRST_APPS_MARKER": str(tmp / "state/first-apps.done"),
        "FLATPAK_LOG": str(tmp / "flatpak.log"),
        "INSTALLED_LOG": str(tmp / "installed.log"),
        "INSTALLED": "",
        "FAIL_APP": "never",
    }
    env.update(overrides)
    result = subprocess.run(["sh", str(SCRIPT)], env=env, capture_output=True, text=True)
    calls = (tmp / "flatpak.log").read_text().splitlines() if (tmp / "flatpak.log").exists() else []
    installed = (tmp / "installed.log").read_text().splitlines() if (tmp / "installed.log").exists() else []
    return result, calls, installed


def fixture(tmp):
    apps = tmp / "apps.d"
    apps.mkdir()
    (apps / "00-core.list").write_text(
        "# 首启应用清单\n"
        "org.mozilla.firefox          # 浏览器（默认；Chrome 走 01-optional）\n"
        "io.github.flattool.Warehouse # 可视化 Flatpak 商店\n"
        "# org.gnome.Nautilus 已移除（2026-11-22）\n"
    )
    (apps / "01-optional.list").write_text("org.gnome.Nautilus # 可选\n")


def main():
    with tempfile.TemporaryDirectory(prefix="m2-apps-") as raw:
        tmp = Path(raw)
        fixture(tmp)
        result, calls, installed = run(tmp)
        assert result.returncode == 0, result.stderr
        assert calls[0].startswith("remote-add --user --if-not-exists flathub "), calls
        # 行内注释必须先洗掉：整行当 app id 是这次要修的病
        assert any("install --user" in call and "flathub org.mozilla.firefox" in call for call in installed), installed
        assert any("io.github.flattool.Warehouse" in call for call in installed), installed
        assert not any("#" in call or "浏览器" in call for call in installed), installed
        # *optional* 清单不装
        assert not any("Nautilus" in call for call in installed), installed
        marker = tmp / "state/first-apps.done"
        assert marker.is_file()

        # 幂等：标记存在时不再调用 flatpak
        (tmp / "flatpak.log").unlink()
        result, calls, installed = run(tmp)
        assert result.returncode == 0 and not calls, calls

    with tempfile.TemporaryDirectory(prefix="m2-apps-") as raw:
        tmp = Path(raw)
        fixture(tmp)
        result, calls, installed = run(tmp, INSTALLED="org.mozilla.firefox\nio.github.flattool.Warehouse")
        assert result.returncode == 0 and installed == [], installed

    with tempfile.TemporaryDirectory(prefix="m2-apps-") as raw:
        tmp = Path(raw)
        fixture(tmp)
        result, calls, installed = run(tmp, FAIL_APP="Warehouse")
        assert result.returncode == 1, result
        assert not (tmp / "state/first-apps.done").exists(), "失败不能写完成标记"
        assert "未能安装" in result.stderr

    with tempfile.TemporaryDirectory(prefix="m2-apps-") as raw:
        tmp = Path(raw)
        fixture(tmp)
        result, calls, installed = run(tmp, REMOTE_STATUS="1")
        assert result.returncode == 1, result
        assert not installed, "remote 落不了库时不能假装装上了"
        assert "flathub" in result.stderr

    # 首启接线：install-external.sh 跑的 first-desktop.sh 必须登记 local.d 任务
    first = (PLATFORM / "first-desktop.sh").read_text()
    assert 'install -m 755 /opt/ordo/config/platform/m2/first-apps.sh /usr/local/sbin/ordo-first-apps' in first
    assert "/etc/local.d/70-ordo-first-apps.start" in first
    # 顺序只对真实依赖成立：先把 ordo-first-apps 落盘，再写 exec 它的 local.d
    # 入口。greetd 的 rc-update 与首启应用没有依赖（local.d 在 boot 时独立跑），
    # 拿它当锚点只是把「运行级注册的排版顺序」误当成契约，故改锚到 hook 本身。
    assert first.index("first-apps.sh") < first.index("70-ordo-first-apps.start")
    assert "exec /usr/local/sbin/ordo-first-apps" in first
    print("P1-04 first-boot apps: ok")


if __name__ == "__main__":
    main()
