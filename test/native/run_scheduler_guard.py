#!/usr/bin/env python3
"""Run potentially deadlocking scheduler tests with bounded fresh processes."""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent
cases = sys.argv[1:] or ['pending', 'callback', 'cleanup', 'prelocked', 'shadow']
for case in cases:
    with tempfile.TemporaryFile(mode='w+') as log:
        process = subprocess.Popen(['Rscript', '--vanilla', str(root / 'managed_scheduler_guard.R'), case],
                                   stdout=log, stderr=subprocess.STDOUT)
        try:
            status = process.wait(timeout=60)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
            log.seek(0)
            raise RuntimeError(f'{case}: timeout (possible deadlock)\n{log.read()}')
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
        log.seek(0)
        output = log.read()
        if status or f'PASS scheduler guard: {case}' not in output:
            raise RuntimeError(f'{case}: exit {status}\n{output}')
        print(output, flush=True)
