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
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
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

        # ── Sessions, passive capture, finalization ─────────────────────────
        run(binary, data_dir, "session", "start", "passive-sess", "--project", "ctxdb")
        responses = mcp(
            binary,
            data_dir,
            [
                {
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "tools/call",
                    "params": {
                        "name": "mem_capture_passive",
                        "arguments": {
                            "session_id": "passive-sess",
                            "content": "## Key Learnings\n1. WAL mode improves concurrent database access for readers and writers.\n",
                        },
                    },
                },
                {
                    "jsonrpc": "2.0",
                    "id": 2,
                    "method": "tools/call",
                    "params": {
                        "name": "mem_session_finalize",
                        "arguments": {
                            "session_id": "passive-sess",
                            "project": "ctxdb",
                            "summary": "Goal: passive test\n## Key Learnings\n1. Finalization is atomic with its summary observation.\n",
                        },
                    },
                },
            ],
        )
        assert '"saved":1' in tool_text(responses[0]).replace(" ", ""), tool_text(responses[0])
        assert "summary_id" in tool_text(responses[1]), tool_text(responses[1])
        with sqlite3.connect(data_dir / "engram.db") as db:
            assert db.execute(
                "select count(*) from observations where session_id='passive-sess' and type='learning'"
            ).fetchone()[0] == 1
            assert db.execute(
                "select ended_at is not null from sessions where id='passive-sess'"
            ).fetchone()[0] == 1
            assert db.execute(
                "select count(*) from session_finalizations where session_id='passive-sess'"
            ).fetchone()[0] == 1

        # ── Consolidation ──────────────────────────────────────────────────
        run(binary, data_dir, "save", "Merge A", "alpha content", "--type", "discovery")
        run(binary, data_dir, "save", "Merge B", "beta content", "--type", "discovery")
        with sqlite3.connect(data_dir / "engram.db") as db:
            merge_ids = [r[0] for r in db.execute(
                "select id from observations where title in ('Merge A','Merge B') and deleted_at is null order by id"
            )]
        assert len(merge_ids) == 2
        preview = mcp(
            binary,
            data_dir,
            [{"jsonrpc": "2.0", "id": 1, "method": "tools/call",
              "params": {"name": "mem_consolidate", "arguments": {"ids": merge_ids}}}],
        )
        plan = json.loads(tool_text(preview[0]))
        assert plan["plan"]["fingerprint"]
        applied = mcp(
            binary,
            data_dir,
            [{"jsonrpc": "2.0", "id": 2, "method": "tools/call",
              "params": {"name": "mem_consolidate", "arguments": {
                  "ids": merge_ids, "confirm": True, "fingerprint": plan["plan"]["fingerprint"]}}}],
        )
        assert "survivor" in tool_text(applied[0]), tool_text(applied[0])
        with sqlite3.connect(data_dir / "engram.db") as db:
            assert db.execute(
                "select count(*) from observations where id in (?,?) and deleted_at is null",
                merge_ids,
            ).fetchone()[0] == 0

        # ── Relations / conflicts ──────────────────────────────────────────
        run(binary, data_dir, "conflicts", "scan", "--project", "ctxdb", "--apply", "--limit", "20")
        with sqlite3.connect(data_dir / "engram.db") as db:
            live = [r[0] for r in db.execute(
                "select id from observations where deleted_at is null order by id limit 2"
            )]
        assert len(live) == 2
        compare = run(binary, data_dir, "conflicts", "compare", str(live[0]), str(live[1]),
                      "related", "0.8", "--reason", "smoke comparison")
        rel_id = json.loads(compare)["sync_id"]
        assert rel_id
        shown = json.loads(run(binary, data_dir, "conflicts", "show", rel_id))
        assert shown["judgment_status"] == "judged", shown
        assert json.loads(run(binary, data_dir, "conflicts", "stats", "--project", "ctxdb"))["by_relation"]

        # ── Export / import ────────────────────────────────────────────────
        export_path = data_dir / "export.json"
        run(binary, data_dir, "export", str(export_path), "--all")
        assert export_path.exists()
        imported_dir = Path(tempfile.mkdtemp(prefix="ctxdb-import-"))
        try:
            run(binary, imported_dir, "import", str(export_path))
            out = run(binary, imported_dir, "stats")
            assert "Observations:" in out
            with sqlite3.connect(imported_dir / "engram.db") as db:
                assert db.execute("select count(*) from observations").fetchone()[0] > 0
                assert db.execute("select count(*) from memory_relations").fetchone()[0] > 0
        finally:
            shutil.rmtree(imported_dir, ignore_errors=True)

        # ── Local git-style sync chunks ───────────────────────────────────
        sync_dir = Path(tempfile.mkdtemp(prefix="ctxdb-sync-"))
        sync_target = Path(tempfile.mkdtemp(prefix="ctxdb-sync-target-"))
        try:
            out = run(binary, data_dir, "sync", "--dir", str(sync_dir), "--all")
            exported = json.loads(out)
            assert exported["chunk_id"], exported
            assert list(sync_dir.rglob("*.jsonl.gz"))
            status = json.loads(run(binary, data_dir, "sync", "--status", "--dir", str(sync_dir)))
            assert status["manifest_chunks"] >= 1
            run(binary, sync_target, "sync", "--import", "--dir", str(sync_dir))
            with sqlite3.connect(sync_target / "engram.db") as db:
                assert db.execute("select count(*) from observations").fetchone()[0] > 0
        finally:
            shutil.rmtree(sync_dir, ignore_errors=True)
            shutil.rmtree(sync_target, ignore_errors=True)

        # ── Obsidian export ────────────────────────────────────────────────
        vault = Path(tempfile.mkdtemp(prefix="ctxdb-vault-"))
        try:
            run(binary, data_dir, "obsidian-export", "--vault", str(vault), "--all")
            assert len(list(vault.rglob("*.md"))) > 0
        finally:
            shutil.rmtree(vault, ignore_errors=True)

        # ── Delete subcommands ─────────────────────────────────────────────
        run(binary, data_dir, "session", "start", "empty-sess", "--project", "ctxdb")
        run(binary, data_dir, "delete", "session", "empty-sess")
        run(binary, data_dir, "prompt", "save", "manual-save-ctxdb", "temporary prompt")
        run(binary, data_dir, "delete", "prompt", "1")
        run(binary, data_dir, "save", "Other project item", "body", "--project", "otherproj")
        run(binary, data_dir, "delete", "project", "otherproj", "--hard")

        # ── HTTP API ───────────────────────────────────────────────────────
        sock = socket.socket()
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
        sock.close()
        env = dict(os.environ)
        env["ENGRAM_DATA_DIR"] = str(data_dir)
        server = subprocess.Popen(
            [str(binary), "serve", str(port)],
            cwd=ROOT,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            base = f"http://127.0.0.1:{port}"
            deadline = time.time() + 8
            while time.time() < deadline:
                try:
                    with urllib.request.urlopen(base + "/health", timeout=1) as response:
                        health = json.loads(response.read())
                    break
                except (urllib.error.URLError, ConnectionError):
                    time.sleep(0.1)
            else:
                raise AssertionError("HTTP server did not become ready")
            assert health["status"] == "ok"
            with urllib.request.urlopen(base + "/stats", timeout=2) as response:
                assert "total_observations" in json.loads(response.read())
            request = urllib.request.Request(
                base + "/observations",
                data=json.dumps({
                    "session_id": "manual-save-ctxdb",
                    "type": "discovery",
                    "title": "HTTP save",
                    "content": "saved through the HTTP API",
                }).encode(),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(request, timeout=2) as response:
                assert json.loads(response.read())["status"] == "saved"
            with urllib.request.urlopen(base + "/search?q=HTTP&all_projects=true", timeout=2) as response:
                assert len(json.loads(response.read())) >= 1
            with urllib.request.urlopen(base + "/conflicts?project=ctxdb", timeout=2) as response:
                assert isinstance(json.loads(response.read()), list)
        finally:
            server.terminate()
            try:
                server.wait(timeout=3)
            except subprocess.TimeoutExpired:
                server.kill()

        print("smoke: OK")
        return 0
    finally:
        if args.keep:
            print(f"kept: {data_dir}")
        else:
            shutil.rmtree(data_dir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
