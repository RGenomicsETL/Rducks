#!/usr/bin/env python3
"""Run managed-stream configuration tests in bounded fresh processes."""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent
cases = sys.argv[1:] or ['closed', 'untouched', 'prelocked', 'rducks-calls']
for case in cases:
    with tempfile.TemporaryFile(mode='w+') as log:
        process = subprocess.Popen(['Rscript', '--vanilla', str(root / 'managed_stream_configuration.R'), case],
                                   stdout=log, stderr=subprocess.STDOUT)
        try:
            status = process.wait(timeout=120)
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
        if status or f'PASS managed stream configuration: {case}' not in output:
            raise RuntimeError(f'{case}: exit {status}\n{output}')
        print(output, flush=True)
