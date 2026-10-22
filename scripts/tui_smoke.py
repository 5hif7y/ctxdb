#!/usr/bin/env python3
"""Auxiliary PTY smoke test for the ctxdb TUI."""
from __future__ import annotations

import argparse
import os
import pty
import re
import select
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default=str(ROOT / "ctxdb"))
    args = parser.parse_args()
    binary = Path(args.binary).resolve()
    data_dir = Path(tempfile.mkdtemp(prefix="ctxdb-tui-"))
    env = dict(os.environ)
    env["ENGRAM_DATA_DIR"] = str(data_dir)
    subprocess.run(
        [str(binary), "save", "TUI observation", "TUI body", "--type", "discovery"],
        cwd=ROOT, env=env, check=True, capture_output=True, text=True,
    )
    master, slave = pty.openpty()
    proc = subprocess.Popen(
        [str(binary), "tui"], cwd=ROOT, env=env,
        stdin=slave, stdout=slave, stderr=slave, close_fds=True,
    )
    os.close(slave)
    output = b""

    def drain(seconds: float = 0.3) -> None:
        nonlocal output
        deadline = time.time() + seconds
        while time.time() < deadline:
            ready, _, _ = select.select([master], [], [], 0.05)
            if ready:
                try:
                    output += os.read(master, 65536)
                except OSError:
                    break

    def send(data: bytes, pause: float = 0.25) -> None:
        os.write(master, data)
        drain(pause)

    try:
        drain(0.5)
        send(b"j")
        send(b"\r")
        send(b"\r")
        send(b"t")
        send(b"\x1b")
        send(b"\x1b")
        send(b"q", 0.6)
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    finally:
        os.close(master)

    text = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", output.decode("utf-8", "replace"))
    checks = ["Memory dashboard", "Recent observations", "Timeline", "TUI observation"]
    missing = [item for item in checks if item not in text]
    if missing:
        print("missing TUI markers:", missing, file=sys.stderr)
        print(text[-2000:], file=sys.stderr)
        return 1
    print("tui smoke: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
