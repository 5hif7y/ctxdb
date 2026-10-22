#!/usr/bin/env python3
"""Auxiliary smoke test for the Odin ctxdb port.

This script is deliberately outside the Odin binary: it drives the CLI and the
stdio MCP surface as a black box, then inspects the resulting SQLite database
with Python's stdlib. No scripting is embedded in ctxdb.

Usage:
    python3 scripts/smoke.py [--binary ./ctxdb] [--keep]
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run(binary: Path, data_dir: Path, *args: str, check: bool = True) -> str:
    env = dict(os.environ)
    env["ENGRAM_DATA_DIR"] = str(data_dir)
    proc = subprocess.run(
        [str(binary), *args],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        timeout=30,
    )
    if check and proc.returncode != 0:
        raise AssertionError(
            f"command failed ({proc.returncode}): {args}\n"
            f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
        )
    return proc.stdout


def mcp(binary: Path, data_dir: Path, requests: list[dict]) -> list[dict]:
    env = dict(os.environ)
    env["ENGRAM_DATA_DIR"] = str(data_dir)
    payload = "".join(json.dumps(r) + "\n" for r in requests)
    proc = subprocess.run(
        [str(binary), "mcp"],
        cwd=ROOT,
        env=env,
        input=payload,
        text=True,
        capture_output=True,
        timeout=30,
    )
    if proc.returncode != 0:
        raise AssertionError(f"mcp failed: {proc.stderr}")
    responses = [json.loads(line) for line in proc.stdout.splitlines() if line.strip()]
    assert len(responses) == len(requests), (len(responses), len(requests), proc.stdout)
    return responses


def tool_text(response: dict) -> str:
    return response["result"]["content"][0]["text"]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default=str(ROOT / "ctxdb"))
    parser.add_argument("--keep", action="store_true")
    args = parser.parse_args()
    binary = Path(args.binary).resolve()
    if not binary.exists():
        raise SystemExit(f"binary not found: {binary} (run `make build`)")

    data_dir = Path(tempfile.mkdtemp(prefix="ctxdb-smoke-"))
    try:
        print(f"data dir: {data_dir}")

        # CLI save + topic upsert.
        out = run(binary, data_dir, "save", "Auth middleware", "**What**: JWT auth", "--type", "architecture", "--topic", "architecture/auth")
        assert "Memory saved: #1" in out, out
        out = run(binary, data_dir, "save", "Auth middleware", "**What**: JWT auth v2", "--type", "architecture", "--topic", "architecture/auth")
        assert "Memory saved: #1" in out, out

        # Exact dedupe without topic_key.
        run(binary, data_dir, "save", "Dedupe test", "same body", "--type", "discovery")
        run(binary, data_dir, "save", "Dedupe test", "same body", "--type", "discovery")

        out = run(binary, data_dir, "search", "auth")
        assert "Auth middleware" in out and "Found" in out, out

        out = run(binary, data_dir, "context")
        assert "## Memory from Previous Sessions" in out, out
        assert "Recent Observations" in out, out

        out = run(binary, data_dir, "stats")
        assert "Observations:" in out and "ctxdb" in out, out

        # Topic upsert revision and dedupe metadata.
        with sqlite3.connect(data_dir / "engram.db") as db:
            row = db.execute(
                "select revision_count from observations where topic_key='architecture/auth' and deleted_at is null"
            ).fetchone()
            assert row and row[0] == 2, row
            row = db.execute(
                "select duplicate_count from observations where title='Dedupe test' and deleted_at is null"
            ).fetchone()
            assert row and row[0] == 2, row

            tables = {
                r[0]
                for r in db.execute("select name from sqlite_master where type in ('table','view')")
            }
            for required in ("sessions", "observations", "observations_fts", "user_prompts", "prompts_fts"):
                assert required in tables, (required, sorted(tables))
            columns = {r[1] for r in db.execute("pragma table_info(observations)")}
            for required in ("review_after", "topic_key", "normalized_hash", "pinned", "deleted_at"):
                assert required in columns, (required, sorted(columns))

        # MCP surface.
        responses = mcp(
            binary,
            data_dir,
            [
                {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
                {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
                {
                    "jsonrpc": "2.0",
                    "id": 3,
                    "method": "tools/call",
                    "params": {"name": "mem_search", "arguments": {"query": "auth"}},
                },
                {
                    "jsonrpc": "2.0",
                    "id": 4,
                    "method": "tools/call",
                    "params": {"name": "mem_get_observation", "arguments": {"id": 1}},
                },
            ],
        )
        assert responses[0]["result"]["serverInfo"]["name"] == "ctxdb"
        tool_names = {t["name"] for t in responses[1]["result"]["tools"]}
        assert {"mem_save", "mem_search", "mem_context", "mem_session_start"} <= tool_names
        assert "Auth middleware" in tool_text(responses[2])
        assert "JWT auth" in tool_text(responses[3])

        # Soft delete hides from search, hard delete removes the row.
        run(binary, data_dir, "delete", "2")
        out = run(binary, data_dir, "search", "Dedupe test")
        assert "No memories found" in out, out
        run(binary, data_dir, "delete", "2", "--hard")
        with sqlite3.connect(data_dir / "engram.db") as db:
            assert db.execute("select count(*) from observations where id=2").fetchone()[0] == 0

        print("smoke: OK")
        return 0
    finally:
        if args.keep:
            print(f"kept: {data_dir}")
        else:
            shutil.rmtree(data_dir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
