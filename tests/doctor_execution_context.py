from pathlib import Path
import os
import shutil
import subprocess
import tempfile


def executable(path, content):
    path.write_text(content)
    path.chmod(0o755)


with tempfile.TemporaryDirectory() as directory:
    root = Path(directory).resolve()
    for subdir in ("scripts", "config", "bin", "boot", "login/.config/umbriel"):
        (root / subdir).mkdir(parents=True)
    configs = root / "config"
    (configs / "dataset").write_text("POOL=rpool\nDATASET=rpool/root/ordo\nHOME_DATASET=rpool/home\n")
    (configs / "world.sh").write_text("ordo_platform() { printf 'vm\\n'; }\nordo_world() { cat \"$1/world\"; }\n")
    (configs / "world").write_text("sys-apps/reference\n")
    (configs / "forbidden-world").touch()
    (root / "world").write_bytes((configs / "world").read_bytes())
    login = root / "login/.config"
    (login / "umbriel/config.toml").write_text("[general]\n")

    for name in ("sh", "awk", "sed", "grep", "sort", "comm", "mktemp", "rm", "cat", "dirname",
                 "basename", "readlink", "tr", "wc", "head", "tail", "cut", "printf", "id"):
        command = shutil.which(name)
        if command:
            (root / "bin" / name).symlink_to(command)
    executable(root / "bin/findmnt", """#!/bin/sh
case "$*" in
    '-no SOURCE /') printf 'rpool/root/ordo\n' ;;
    '-no FSTYPE --target /boot')
        printf '%s\n' "$TEST_BOOT_FS"
        exit "$TEST_BOOT_RC" ;;
    *) exit 1 ;;
esac
""")
    executable(root / "bin/umbriel", """#!/bin/sh
[ "$*" = 'config validate' ] && [ "$XDG_CONFIG_HOME" = "$TEST_LOGIN" ] &&
    [ "${TEST_UMBRIEL_RC:-0}" -eq 0 ]
""")
    executable(root / "bin/getent", f"""#!/bin/sh
[ "$*" = 'passwd ordo' ] && printf 'ordo:x:1000:1000::%s:/bin/sh\n' '{root / "login"}'
""")
    executable(root / "bin/pgrep", "#!/bin/sh\nexit 0\n")

    lib = Path("scripts/lib.sh").read_text().replace("/etc/ordo", str(root / "etc-ordo"))
    executable(root / "scripts/lib.sh", lib)
    common = {"/var/lib/portage/world": str(root / "world"),
              "/etc/portage/sets/ordo-core": str(root / "absent-set")}
    config = Path("scripts/ordo-config").read_text()
    doctor = (Path("scripts/doctor").read_text()
              .replace("[ ! -d /boot ]", f'[ ! -d "{root / "boot"}" ]')
              .replace("$CONF_DIR/forbidden-world", "$CONF_DIR/absent-for-doctor"))
    for name, script in (("ordo-config", config), ("doctor", doctor)):
        for text, replacement in common.items():
            script = script.replace(text, replacement)
        executable(root / "scripts" / name, script)

    env = {key: value for key, value in os.environ.items() if key not in {
        "HOME", "XDG_CONFIG_HOME", "XDG_RUNTIME_DIR", "SUDO_USER", "DOAS_USER",
        "ORDO_CONF_DIR", "ORDO_CONFIG", "POOL", "DATASET", "HOME_DATASET",
    }}
    env.update(PATH=str(root / "bin"), TEST_BOOT_FS="zfs", TEST_BOOT_RC="0", TEST_LOGIN=str(login))

    def run(name, *args, **extra):
        return subprocess.run([str(root / "scripts" / name), *args], env={**env, **extra},
                              capture_output=True, text=True)

    headless = run("ordo-config", "verify")
    assert headless.returncode == 2, headless
    assert "无法确定桌面配置目录" in headless.stdout
    assert "有效 world 与声明一致" in headless.stdout
    assert "配置无效" not in headless.stdout

    for context in ({"XDG_CONFIG_HOME": str(login)}, {"HOME": str(root / "root"), "DOAS_USER": "ordo"}):
        result = run("ordo-config", "verify", **context)
        assert result.returncode == 0 and "Umbriel 配置有效" in result.stdout, result
    invalid = run("ordo-config", "verify", XDG_CONFIG_HOME=str(login), TEST_UMBRIEL_RC="1")
    assert invalid.returncode == 1 and "Umbriel 配置无效" in invalid.stdout, invalid

    health = run("doctor")
    assert "/boot 在数据集内（zfs" in health.stdout, health
    assert "配置无法判定" in health.stdout and "配置漂移" not in health.stdout, health
    assert "MAKEOPTS" in health.stdout and "HOME" not in health.stderr, health
    fat = run("doctor", TEST_BOOT_FS="vfat")
    assert "/boot 挂载在 ESP" in fat.stdout, fat
    other = run("doctor", TEST_BOOT_FS="ext4")
    assert "/boot 的文件系统为 ext4" in other.stdout and "/boot 在数据集内" not in other.stdout, other
    failed_probe = run("doctor", TEST_BOOT_RC="1")
    assert "无法读取 /boot 挂载类型" in failed_probe.stdout and "/boot 在数据集内" not in failed_probe.stdout, failed_probe
