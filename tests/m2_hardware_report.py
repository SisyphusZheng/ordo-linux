#!/usr/bin/env python3
"""P1-06 / B4：M2 硬件验收报告的格式契约必须被 doctor 三态消费。

生产者是 verify-hardware.sh --session-report，消费者是 scripts/doctor。
这里锁定两者之间的格式：最后一行 `exit=0|1|2`；报告缺失、为空、末行不可识别
一律无法判定（2）；任何情况下 2 都不能被当成通过。
"""
import os
from pathlib import Path
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]
PLATFORM = REPO / "config/platform/m2"
PRODUCER = PLATFORM / "verify-hardware.sh"
CONTRACT = PLATFORM / "hardware-report.md"
DOCTOR = REPO / "scripts/doctor"


def contract_document():
    text = CONTRACT.read_text()
    for token in ("m2-hardware.log", "exit=<0|1|2>", "2 不等于通过", "skip"):
        assert token in text, token


def producer_contract():
    """真实生产者输出必须满足格式（round-trip）。"""
    with tempfile.TemporaryDirectory(prefix="m2-report-") as raw:
        root = Path(raw)
        compatible = root / "compatible"
        compatible.write_bytes(b"apple,j413\0apple,t8112\0")
        script = root / "verify"
        script.write_text(PRODUCER.read_text().replace(
            "/proc/device-tree/compatible", str(compatible)))
        timeout = root / "timeout"
        timeout.write_text(
            '#!/bin/sh\n[ "$#" = 3 ] && [ "$1" = 45 ] && [ "$2" = sh ] || exit 88\nexit "$RESULT"\n')
        timeout.chmod(0o755)
        for result, expected in ((0, 0), (1, 1), (2, 2), (124, 2)):
            env = {**os.environ, "PATH": f"{root}:{os.environ['PATH']}",
                   "XDG_STATE_HOME": str(root), "RESULT": str(result)}
            run = subprocess.run(["sh", str(script), "--session-report"], env=env)
            assert run.returncode == expected, (result, run.returncode)
            log = root / "ordo/m2-hardware.log"
            assert log.is_file(), "失败/超时也必须落盘"
            lines = [line for line in log.read_text().splitlines() if line.strip()]
            assert lines[-1] == f"exit={expected}", lines[-1]
            assert log.stat().st_mode & 0o777 == 0o600, oct(log.stat().st_mode & 0o777)
        # 非 J413 机器不产生报告
        compatible.write_bytes(b"linux,dummy-virt\0")
        (root / "ordo/m2-hardware.log").unlink()
        env = {**os.environ, "PATH": f"{root}:{os.environ['PATH']}",
               "XDG_STATE_HOME": str(root), "RESULT": "0"}
        assert subprocess.run(["sh", str(script), "--session-report"], env=env).returncode == 2
        assert not (root / "ordo/m2-hardware.log").exists()


def doctor_contract():
    """执行 doctor 里真正的读取段，三态映射必须逐项成立。"""
    text = DOCTOR.read_text()
    start = text.index("# 13.5) M2 硬件自检报告")
    end = text.index("# 唯一栈守门")
    with tempfile.TemporaryDirectory(prefix="m2-doctor-") as raw:
        tmp = Path(raw)
        compatible = tmp / "compatible"
        compatible.write_bytes(b"apple,j413\0apple,t8112\0")
        state = tmp / "state"
        block = text[start:end].replace("/proc/device-tree/compatible", str(compatible))
        block = block.replace("${XDG_STATE_HOME:-${HOME:-}/.local/state}", str(state))
        runner = tmp / "run.sh"
        runner.write_text(
            "set -u\nn_ok=0; n_bad=0; n_skip=0\n"
            "ok() { n_ok=$((n_ok+1)); }\n"
            "bad() { n_bad=$((n_bad+1)); }\n"
            "skip() { n_skip=$((n_skip+1)); }\n"
            + block +
            "printf '%s %s %s\\n' \"$n_ok\" \"$n_bad\" \"$n_skip\"\n")
        log = state / "ordo/m2-hardware.log"

        def run(content=None, j413=True):
            if log.exists():
                log.unlink()
            if content is not None:
                log.parent.mkdir(parents=True, exist_ok=True)
                log.write_text(content)
            compatible.write_bytes(
                b"apple,j413\0apple,t8112\0" if j413 else b"linux,dummy-virt\0")
            output = subprocess.check_output(["sh", str(runner)], text=True)
            return tuple(int(value) for value in output.split())

        assert run() == (0, 0, 1), "报告缺失必须 skip"
        assert run("diag\nexit=0\n") == (1, 0, 0), "exit=0 通过"
        assert run("diag\nexit=1\n") == (0, 1, 0), "exit=1 异常"
        assert run("diag\nexit=2\n") == (0, 0, 1), "exit=2 待验，不是通过"
        for broken in ("", "diag\n", "exit=9\n", "exit=0\nstale\n"):
            assert run(broken) == (0, 0, 1), f"无法识别的报告必须 skip：{broken!r}"
        assert run("diag\nexit=0\n", j413=False) == (0, 0, 0), "非 J413 不做这项检查"


contract_document()
producer_contract()
doctor_contract()
print("P1-06 hardware report contract: ok")
