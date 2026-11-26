#!/usr/bin/env python3
"""P1-06：M2 平台声明不得降级，验收脚本必须自己说明为什么红。

回归两个真实故障：
  1. install-hardware.sh 在每次首启都把 m2-native 改回 m2 —— @ordo-m2 包集与 AGX 渲染等待
     随之失效，speakersafetyd/upower 只是“装了没声明”，一次 depclean 就可能被摘掉；
  2. verify-hardware.sh 的 gpu() 每个失败分支都静默 return —— 交付报告只有一个“异常”，
     没人知道是没渲染节点、没 eglinfo 还是 Mesa 走了软渲染。
"""
import os
from pathlib import Path
import re
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]
PLATFORM = REPO / "config/platform/m2"

INSTALL_STUB = r'''#!/bin/sh
# 只实现被测脚本用到的最小子集（BSD install 没有 -D，且这里要落进临时根）
mode=644
while [ "$#" -gt 0 ]; do
    case "$1" in
        -Dm*) mode=${1#-Dm}; shift; mkdir -p "${2%/*}" && cp "$1" "$2" && chmod "$mode" "$2"; exit $? ;;
        -dm*) mode=${1#-dm}; shift; mkdir -p "$1" && chmod "$mode" "$1"; exit $? ;;
        -d) shift
            [ "$1" = -m ] && { shift; mode=$1; shift; }
            mkdir -p "$1" && chmod "$mode" "$1"; exit $? ;;
        -m) mode=$1; shift; cp "$1" "$2" && chmod "$mode" "$2"; exit $? ;;
        *) break ;;
    esac
done
exit 1
'''


def run_install_hardware(tmp, platform, raw=None):
    root = tmp / "root"
    for path in ("etc/ordo", "etc/portage/package.use", "etc/portage/package.accept_keywords",
                 "etc/portage/sets", "etc/init.d", "usr/local/bin", "var/lib/portage"):
        (root / path).mkdir(parents=True, exist_ok=True)
    if raw is not None:
        (root / "etc/ordo/platform").write_text(raw)
    elif platform is not None:
        (root / "etc/ordo/platform").write_text(platform + "\n")
    bins = tmp / "bin"
    bins.mkdir(exist_ok=True)
    for name, body in {
        "install": INSTALL_STUB,
        "portageq": "#!/bin/sh\nexit 1\n",
        "rc-update": "#!/bin/sh\nexit 0\n",
        # 让 world_sets 分支在非 root 的测试机上也能被执行
        "id": '#!/bin/sh\n[ "$1" = -u ] && { echo 0; exit 0; }\nexec /usr/bin/id "$@"\n',
    }.items():
        tool = bins / name
        tool.write_text(body)
        tool.chmod(0o755)
    script = (PLATFORM / "install-hardware.sh").read_text()
    # 单趟重写系统前缀：macOS 的临时根位于 /var/folders 下，若先插入根再
    # 依次 str.replace("/var/", ...)，已插入的根会被二次套根，脚本就写到
    # $root/$root/etc/... 而不是 $root/etc/...。re.sub 不会重扫替换文本。
    script = re.sub(r"/(etc|usr|var|run)/", lambda m: f"{root}/{m.group(1)}/", script)
    script = script.replace('here=$(dirname "$(readlink -f "$0")")', f'here={PLATFORM}')
    runner = tmp / "run.sh"
    runner.write_text("set -eu\n" + script)
    env = {"PATH": f"{bins}:{os.environ['PATH']}"}
    subprocess.run(["sh", str(runner)], check=True, env=env)
    return root


def platform_contract():
    with tempfile.TemporaryDirectory(prefix="m2-platform-") as raw:
        tmp = Path(raw)
        # 1) m2-native 不得被降级
        root = run_install_hardware(tmp / "a", "m2-native")
        assert (root / "etc/ordo/platform").read_text().strip() == "m2-native"
        # 2) 缺失时补写 m2
        root = run_install_hardware(tmp / "b", None)
        assert (root / "etc/ordo/platform").read_text().strip() == "m2"
        # 3) 已是 m2 时保持 m2
        root = run_install_hardware(tmp / "c", "m2")
        assert (root / "etc/ordo/platform").read_text().strip() == "m2"
        # 4) 已存在的 marker 一律不改写：带注释/多行的 m2-native 仍是 native。
        #    旧实现把整份文件与 "m2-native" 做字符串比较，注释行会让它判成
        #    “非 native”并静默降级成 m2；还原旧实现这条用例变红（B3）。
        annotated = "m2-native\n# 原生包集由 install-native.sh 写入\n"
        root = run_install_hardware(tmp / "d", None, raw=annotated)
        assert (root / "etc/ordo/platform").read_text() == annotated, \
            "已存在的平台标记被改写（m2-native 会被降级）"
        # 其它平台的标记同样不能被本脚本改成 m2：写错比写不出更糟。
        root = run_install_hardware(tmp / "e", "vm")
        assert (root / "etc/ordo/platform").read_text().strip() == "vm"


def world_set_contract():
    with tempfile.TemporaryDirectory(prefix="m2-platform-") as raw:
        tmp = Path(raw)
        root = run_install_hardware(tmp, "m2-native")
        world_sets = (root / "var/lib/portage/world_sets").read_text().splitlines()
        assert world_sets.count("@ordo-m2") == 1, world_sets
        assert (root / "etc/portage/sets/ordo-m2").is_file()
        assert not (root / "etc/portage/sets/ordo-m2").read_text().startswith("#")


def gpu_reasons():
    """gpu() 的每个失败出口都必须打印原因，且退出码保持 1/2 三态。"""
    text = (PLATFORM / "verify-hardware.sh").read_text()
    body = text[text.index("gpu() {"):text.index("\naudio() {", text.index("gpu() {"))]
    with tempfile.TemporaryDirectory(prefix="m2-gpu-") as raw:
        tmp = Path(raw)
        (tmp / "drm").mkdir()
        (tmp / "dev").mkdir()
        (tmp / "proc").mkdir()
        (tmp / "timeout").write_text('#!/bin/sh\nexit 1\n')
        (tmp / "timeout").chmod(0o755)
        body = (body.replace("/sys/class/drm", str(tmp / "drm"))
                    .replace("/dev/dri/", f"{tmp}/dev/")
                    .replace("/proc/", f"{tmp}/proc/")
                    # 临时目录里造不出字符设备：把「渲染节点必须是字符设备」的
                    # 判断改成普通文件判断，其余逻辑（驱动绑定、EGL、环境）照跑。
                    .replace('[ ! -c "$render" ]', '[ ! -f "$render" ]'))
        script = "set -u\n" + body + "\nv=${WAYLAND_DISPLAY:-}; export WAYLAND_DISPLAY=${v:-wayland-0}; gpu"

        def run(env=None):
            return subprocess.run(["sh", "-c", script], capture_output=True, text=True,
                                  env={**os.environ, "PATH": f"{tmp}:{os.environ['PATH']}", **(env or {})})

        # 没有 asahi 渲染节点：红，并且说清楚是 AGX 没接管
        result = run()
        assert result.returncode == 1, result
        assert "原因" in result.stderr and "asahi" in result.stderr

        # 有节点但没有 eglinfo：无法判定（2），不是通过
        node = tmp / "drm/renderD129/device"
        node.mkdir(parents=True)
        (node / "driver").symlink_to("/drivers/asahi")
        (tmp / "dev/renderD129").write_bytes(b"")
        result = run()
        assert result.returncode == 2, result
        assert "eglinfo" in result.stderr

        # eglinfo 可用但 Mesa 走软渲染：红，并落下 EGL 关键行
        eglinfo = tmp / "eglinfo"
        eglinfo.write_text("""#!/bin/sh
cat <<'EGL'
Wayland platform:
EGL driver name: swrast
EGL vendor string: Mesa
EGL
""")
        eglinfo.chmod(0o755)
        result = run()
        assert result.returncode == 1, result
        assert "EGL driver name: swrast" in result.stderr

        # EGL 正确但 Umbriel 没拿到渲染节点：红，原因指向 WLR_RENDER_DRM_DEVICE
        eglinfo.write_text("""#!/bin/sh
printf 'Wayland platform:\\nEGL driver name: asahi\\n'
""")
        eglinfo.chmod(0o755)
        pgrep = tmp / "pgrep"
        pgrep.write_text("#!/bin/sh\necho 4242\n")
        pgrep.chmod(0o755)
        environ = tmp / "proc/4242"
        environ.mkdir(parents=True)
        (environ / "environ").write_bytes(b"PATH=/bin\0WLR_RENDER_DRM_DEVICE=/dev/dri/renderD999\0")
        result = run()
        assert result.returncode == 1, result
        assert "WLR_RENDER_DRM_DEVICE" in result.stderr

        # 全部对上：绿
        (environ / "environ").write_bytes(b"PATH=/bin\0WLR_RENDER_DRM_DEVICE=" + str(tmp / "dev/renderD129").encode() + b"\0")
        result = run()
        assert result.returncode == 0, result


platform_contract()
world_set_contract()
gpu_reasons()
print("P1-06 platform contract: ok")
