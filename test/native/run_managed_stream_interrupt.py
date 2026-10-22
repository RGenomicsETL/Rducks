#!/usr/bin/env python3
"""SIGINT integration checks for the managed driver, each in a fresh R process.

Run after installing Rducks and duckdb-r with off-main guard capability v2.
R_LIBS_USER is inherited. A timeout is a test failure, and the child is always
reaped. No compiler or implementation-derived test substitute is used here.
"""
from pathlib import Path
import os
import signal
import subprocess
import sys
import tempfile
import time


def run_case(mode: str) -> None:
    script = Path(__file__).with_name("managed_stream_interrupt.R")
    with tempfile.TemporaryDirectory(prefix="rducks-interrupt-") as tmp:
        ready = Path(tmp) / "ready"
        with (Path(tmp) / "output").open("w+") as output:
            process = subprocess.Popen(
                ["Rscript", "--vanilla", str(script), mode, str(ready)],
                stdout=output, stderr=subprocess.STDOUT,
            )
            try:
                deadline = time.monotonic() + 30
                while not ready.exists():
                    if process.poll() is not None:
                        raise RuntimeError(f"{mode}: R exited before reaching the interrupt phase")
                    if time.monotonic() >= deadline:
                        raise TimeoutError(f"{mode}: query did not reach the interrupt phase")
                    time.sleep(0.01)
                # Native-mode readiness is emitted by a prepare-time callback;
                # callback modes emit it while holding a live output allocation.
                time.sleep(0.15)
                if process.poll() is not None:
                    raise RuntimeError(f"{mode}: R exited before SIGINT was sent")
                os.kill(process.pid, signal.SIGINT)
                status = process.wait(timeout=15)
                output.seek(0)
                log = output.read()
                if status != 0 or f"PASS managed stream interrupt: {mode}" not in log:
                    raise RuntimeError(f"{mode}: R exited {status}\n{log}")
                print(log.strip())
            except Exception:
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=5)
                output.seek(0)
                sys.stderr.write(output.read())
                raise


if __name__ == "__main__":
    if os.name == "nt":
        raise SystemExit("SIGINT subprocess tests currently require POSIX")
    for case in ("native", "scalar", "callback", "coalesced"):
        run_case(case)
