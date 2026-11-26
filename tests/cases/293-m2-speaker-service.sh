#!/bin/sh
set -eu
cd "$(dirname "$(readlink -f "$0")")/../.."

python3 - <<'PY'
import os
from pathlib import Path
import subprocess
import tempfile

source = Path('config/platform/m2/speakersafetyd.conf').read_text()
with tempfile.TemporaryDirectory(prefix='m2-speaker-') as raw:
    tmp = Path(raw)
    compatible = tmp / 'compatible'
    config = tmp / 'speakersafetyd.conf'
    config.write_text(source.replace('/proc/device-tree/compatible', str(compatible)).replace(
        '/sys/class/sound', f'{tmp}/sound').replace('/dev/snd', f'{tmp}/snd').replace(
        '/run/speakersafetyd', f'{tmp}/runtime').replace('[ -c ', '[ -f '))
    card = tmp / 'sound/card0'
    card.mkdir(parents=True)
    (card / 'id').write_text('AppleJ413\n')
    sound = tmp / 'snd'
    sound.mkdir()
    (sound / 'controlC0').touch()
    sense = sound / 'pcmC0D2c'
    polls = tmp / 'polls'
    ready = tmp / 'runtime'
    service = r'''
        eerror() { printf '%s\n' "$*" >&2; }
        checkpath() {
            [ "$1 $2 $3 $4 $5" = '-d -m 0750 -o speakersafetyd:audio' ] || return 1
            mkdir -p "$6"
        }
        runuser() {
            [ "$1 $2 $3" = '-u speakersafetyd --' ] || return 1
            [ "${DENY_AUDIO:-0}" = 0 ] || return 1
            shift 3
            "$@"
        }
        sleep() {
            [ "$1" = 0.2 ] || return 1
            printf x >> "$FIXTURE/polls"
            if [ "${LATE_ALSA:-0}" = 1 ]; then touch "$FIXTURE/snd/pcmC0D2c"; fi
        }
        . "$1"
        start_pre
    '''

    def start(**overrides):
        polls.unlink(missing_ok=True)
        return subprocess.run(['sh', '-c', service, 'test', config], capture_output=True,
                              env={'PATH': os.environ['PATH'], 'FIXTURE': raw, **overrides})

    compatible.write_bytes(b'linux,dummy-virt\0')
    assert start().returncode == 1 and not ready.exists() and not polls.exists()
    compatible.write_bytes(b'apple,j413\0apple,t8112\0')
    assert start(LATE_ALSA='1').returncode == 0 and ready.is_dir() and polls.read_text() == 'x'
    assert start().returncode == 0 and not polls.exists(), 'A ready card does not delay boot'
    assert start(DENY_AUDIO='1').returncode == 1 and len(polls.read_text()) == 100
    sense.unlink()
    assert start().returncode == 1 and len(polls.read_text()) == 100
PY
