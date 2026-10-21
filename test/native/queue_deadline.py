#!/usr/bin/env python3
"""Run the production queue synchronization code without loading R or DuckDB.

Only the surrounding types/counters, native interrupt sink, and clock are test doubles. Each function
under test is extracted from the extension source at test time, so this catches
changes to the actual admission/wait/completion implementation. The clock shim
advances CLOCK_MONOTONIC to test the 30-second deadline without a long sleep;
condition-variable waits still use the real clock.
Managed sources also test owner admission, cancellation, and drain isolation.
"""

import argparse
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile


FUNCTIONS = (
    "rducks_queue_lock", "rducks_queue_unlock", "rducks_queue_signal_all",
    "rducks_queue_cancel_generation", "rducks_queue_cancel_requested",
    "rducks_queue_interrupted_error", "rducks_queue_now_us",
    "rducks_queue_wait_timed_us", "rducks_queue_wait_timed",
    "rducks_queue_error_copy", "rducks_queue_push_locked",
    "rducks_queue_remove_pending_locked", "rducks_queue_pop_locked", "rducks_queue_pop_request",
    "rducks_queue_submit_request",
    "rducks_queue_finish_request",
)

MANAGED_FUNCTIONS = (
    "rducks_queue_signal_all_locked", "rducks_queue_request_cancelled",
    "rducks_queue_stop_owner", "rducks_queue_pop_owner_request",
)


def extract(source, name):
    match = re.search(r"^static [^\n]+\b" + name + r"\(", source, re.M)
    if not match:
        raise RuntimeError("Production queue function not found: " + name)
    end = source.index("\n}", match.start()) + 2
    return source[match.start():end]


def main():
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=root / "tools/ext/src/rducks_worker_queue.c")
    parser.add_argument("--storm-only", action="store_true", help="Only run the notification-storm regression")
    args = parser.parse_args()
    source = args.source.read_text()
    managed = "static int rducks_queue_request_cancelled(" in source
    functions = list(FUNCTIONS)
    owner_source = ""
    if managed:
        # Compile the real atomic owner predicate too; only its surrounding
        # connection and interrupt target are replaced by native test state.
        owner_source = extract(args.source.with_name("rducks_runtime.c").read_text(),
                               "rducks_query_owner_stopping") + "\n"
        index = functions.index("rducks_queue_submit_request")
        functions[index:index] = MANAGED_FUNCTIONS
    with tempfile.TemporaryDirectory(prefix="rducks-queue-test-") as directory:
        build = Path(directory)
        (build / "queue_under_test.h").write_text(owner_source + "\n".join(extract(source, name) for name in functions))
        binary = build / "queue_deadline"
        command = shlex.split(os.environ.get("CC", "cc"))
        command += ["-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-pthread"]
        if managed:
            command += ["-DRDUCKS_TEST_MANAGED_QUEUE=1"]
        command += shlex.split(os.environ.get("CFLAGS", ""))
        command += ["-I", str(build), str(root / "test/native/queue_deadline.c"), "-o", str(binary)]
        command += shlex.split(os.environ.get("LDFLAGS", ""))
        subprocess.run(command, check=True)
        subprocess.run([str(binary)] + (["--storm-only"] if args.storm_only else []), check=True, timeout=15)


if __name__ == "__main__":
    main()
