#!/bin/sh
set -eu
cd "$(dirname "$(readlink -f "$0")")/../.."

python3 - <<'PY'
import hashlib
import io
import os
from pathlib import Path
import re
import socket
import subprocess
import tarfile
import tempfile

platform = Path('config/platform/m2')
env_source = Path('config/desktop/ordo-session-env').read_text()
with tempfile.TemporaryDirectory(prefix='m2-', dir='/tmp') as raw:
    tmp = Path(raw)
    session = tmp / 'env'
    compatible = tmp / 'compatible'
    profile = tmp / 'platform'
    session.write_text(env_source.replace('/usr/lib', f'{tmp}/lib').replace(
        '/sys/class/drm', f'{tmp}/drm').replace('/dev/dri/', f'{tmp}/dev/').replace(
        '/proc/device-tree/compatible', str(compatible)).replace('/etc/ordo/platform', str(profile)))
    mesa = tmp / 'lib64/dri/asahi_dri.so'
    mesa.parent.mkdir(parents=True)
    driver = tmp / 'drm/renderD129/device/driver'
    driver.parent.mkdir(parents=True)
    render = tmp / 'dev/renderD129'
    render.parent.mkdir()
    render.touch()
    polls = tmp / 'polls'
    for name, contents in {
        'modinfo': 'test "$1" = asahi && test "${ASAHI_MODULE_AVAILABLE:-0}" = 1',
        'sleep': r'''
test "$1" = 0.1 || exit 1
printf x >> "$FIXTURE/polls"
if [ "${LATE_AGX:-0}" = 1 ]; then
    ln -s /drivers/asahi "$FIXTURE/drm/renderD129/device/driver"
fi
''',
    }.items():
        path = tmp / name
        path.write_text(f'#!/bin/sh\n{contents}\n')
        path.chmod(0o755)
    with socket.socket(socket.AF_UNIX) as dbus:
        dbus.bind(str(tmp / 'bus'))
        def evaluate(**overrides):
            return subprocess.check_output([
                'sh', '-c', '. "$1"; printf "%s|%s|%s" "$WLR_RENDERER" '
                '"${WLR_RENDER_DRM_DEVICE:-}" "${WLR_RENDERER_ALLOW_SOFTWARE:-}"; '
                '[ "${ORDO_ASAHI_RENDER_NODE_TIMEOUT:-}" = "${EXPECT_TIMEOUT:-}" ]',
                'test', session,
            ], env={'XDG_RUNTIME_DIR': raw, 'DBUS_SESSION_BUS_ADDRESS': f'unix:path={tmp}/bus',
                    'PATH': f'{tmp}:{os.environ["PATH"]}', 'FIXTURE': raw, **overrides}, text=True)

        driver.symlink_to('/drivers/asahi')
        assert evaluate() == 'pixman||1', 'AGX without the Mesa driver must use the fallback'
        mesa.touch()
        assert evaluate() == f'gles2|{render}|', 'Asahi GPU must provide the libwlroots render node'
        assert evaluate(WLR_RENDERER='pixman') == 'pixman||1', 'An explicit software renderer is honored'
        assert evaluate(WLR_RENDER_DRM_DEVICE='/other') == 'gles2|/other|', 'Render-device overrides are honored'
        driver.unlink()
        driver.symlink_to('/drivers/virtio_gpu')
        assert evaluate() == 'pixman||1', 'A non-Apple driver must not select Asahi rendering'
        driver.unlink()
        profile.write_text('m2-native\n')
        compatible.write_bytes(b'linux,dummy-virt\0')
        assert evaluate(ASAHI_MODULE_AVAILABLE='1') == 'pixman||1' and not polls.exists()
        compatible.write_bytes(b'apple,j413\0apple,t8112\0')
        assert evaluate() == 'pixman||1' and not polls.exists(), 'A kernel without AGX must not wait'
        assert evaluate(ASAHI_MODULE_AVAILABLE='1', WLR_RENDERER='pixman') == 'pixman||1' and not polls.exists()
        assert evaluate(ASAHI_MODULE_AVAILABLE='1', LATE_AGX='1') == f'gles2|{render}|'
        assert polls.read_text() == 'x', 'The late node must be selected on the next poll'
        polls.unlink()
        driver.unlink()
        assert evaluate(ASAHI_MODULE_AVAILABLE='1', EXPECT_TIMEOUT='1') == 'pixman||1'
        assert len(polls.read_text()) == 40, 'A failed native probe must time out'

    gdbus = tmp / 'gdbus'
    gdbus.write_text('''#!/bin/sh
while [ "$#" -gt 0 ]; do
    case "$1" in
        *.GetMaxBrightness) printf '%s\n' "$MOCK_MAX"; exit ;;
        *.GetBrightness) printf '(%s,)\n' "$MOCK_CURRENT"; exit ;;
        *.SetBrightness) printf '%s' "$2" > "$MOCK_SET"; exit ;;
    esac
    shift
done
exit 1
''')
    gdbus.chmod(0o755)

    changed = tmp / 'brightness'
    def change(direction, current, maximum):
        changed.unlink(missing_ok=True)
        result = subprocess.run(['sh', platform / 'keyboard-light.sh', direction], env={
            'PATH': f'{tmp}:{os.environ["PATH"]}', 'MOCK_CURRENT': str(current), 'MOCK_MAX': maximum,
            'MOCK_SET': str(changed),
        }, text=True, capture_output=True)
        return result.returncode, changed.read_text() if changed.exists() else None

    assert change('up', 20, '(100,)') == (0, '30')
    assert change('up', 98, '(100,)') == (0, '100')
    assert change('down', 2, '(100,)') == (0, '0')
    assert change('up', 20, 'no-device') == (2, None)

    compatible.write_bytes(b'linux,dummy-virt\0')
    verify = (platform / 'verify-hardware.sh').read_text().replace('/proc/device-tree/compatible', str(compatible))
    vm = subprocess.run(['sh', '-c', verify], capture_output=True)
    assert vm.returncode == 2, 'A virtual machine cannot pass physical hardware acceptance'

    audio = verify.split('\naudio() {', 1)[1].split('\nkeyboard() {', 1)[0]
    fake_commands = {
        'pgrep': 'exit "$DAEMON_STATUS"',
        'amixer': r'''
    case "$3" in
        controls) printf "%s\n" "numid=42,iface=MIXER,name='Speaker Volume Unlock'" ;;
        cget) printf '  : values=%s\n' "$LOCK_STATE" ;;
    esac
''',
        'pw-dump': r'''
    printf '%s\n' '"node.name": "audio_effect.j413-convolver"' \
        '"node.name": "effect_output.j413-mic"'
''',
    }
    for program, body in fake_commands.items():
        (tmp / program).write_text(f'#!/bin/sh\n{body}\n')
        (tmp / program).chmod(0o755)
    for daemon, unlock, want in [(0, '1', 0), (0, '0', 1), (1, '1', 1)]:
        result = subprocess.run(['sh', '-c', '\naudio() {' + audio + '\naudio'], env={
            'PATH': f'{tmp}:{os.environ["PATH"]}', 'DAEMON_STATUS': str(daemon), 'LOCK_STATE': unlock,
        })
        assert result.returncode == want

    # OpenZFS forwards only its KERNEL_* options to the module probe builds.
    source = tmp / 'source'
    source.mkdir()
    build = tmp / 'build'
    release = '7.0.9-asahi-2-ordo-agx'
    release_file = build / 'include/config/kernel.release'
    release_file.parent.mkdir(parents=True)
    release_file.write_text(release + '\n')
    (build / 'Module.symvers').write_text('symbols\n')
    boot = build / 'stage/boot'
    boot.mkdir(parents=True)
    (boot / f'vmlinuz-{release}').write_bytes(b'image')
    (build / f'stage/lib/modules/{release}').mkdir(parents=True)
    zfs = tmp / 'zfs'
    zfs.write_text('#!/bin/sh\nprintf "%s\\n" zfs-2.4.4-r0-gentoo\n')
    zfs.chmod(0o755)
    distfile = tmp / 'zfs-2.4.4.tar.gz'
    with tarfile.open(distfile, 'w:gz') as archive:
        files = {
            'META': b'Release:       1\n',
            'configure': b'''#!/bin/sh
printf '%s %s %s %s %s\n' "$TEST_JOBS" "$CC" "$KERNEL_CC" "$KERNEL_LD" "$KERNEL_LLVM" > "$PROBE"
cat META >> "$PROBE"
exit 23
''',
        }
        for name, data in files.items():
            entry = tarfile.TarInfo('zfs-2.4.4/' + name)
            entry.mode = 0o755 if name == 'configure' else 0o644
            entry.size = len(data)
            archive.addfile(entry, io.BytesIO(data))
    fake_repo = tmp / 'repo'
    finish = fake_repo / 'dev/m2/gpu/finish.sh'
    finish.parent.mkdir(parents=True)
    (fake_repo / 'config').mkdir()
    (fake_repo / 'config/check-build').write_text('exit 0\n')
    source_script = Path('dev/m2/gpu/finish.sh').read_text()
    finish.write_text(re.sub(r'\b[0-9a-f]{64}\b', hashlib.sha256(distfile.read_bytes()).hexdigest(), source_script))
    probe = tmp / 'probe'
    configured = subprocess.run(['sh', finish, source, build, distfile, '1'], env={
        'PATH': f'{tmp}:{os.environ["PATH"]}', 'KERNEL_LD': 'ld', 'PROBE': str(probe),
    }, capture_output=True)
    assert configured.returncode == 23, configured.stderr.decode()
    assert probe.read_text().splitlines() == ['1 clang clang ld 1', 'Release:       r0-gentoo']
    assert list(build.glob('ordo-zfs.*/zfs-2.4.4/configure')), 'a failed probe must preserve its logs'
PY

for script in config/platform/m2/install-hardware.sh config/platform/m2/verify-hardware.sh \
              config/platform/m2/keyboard-light.sh dev/m2/gpu/rebuild.sh dev/m2/gpu/finish.sh; do
    sh -n "$script"
done
