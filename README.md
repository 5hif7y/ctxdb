# ctxdb

`ctxdb` is an incremental **Odin port of Engram's local memory core**. It keeps
Engram's local-first contract: sessions, observations, prompts, FTS5 search,
topic-key upserts, deduplication, review dates, soft deletes, a CLI, and a
stdio MCP server over one SQLite database.

The project prefers pure Odin:

- Odin standard library for arguments, environment, files, JSON, text, hashing,
  process I/O, and the MCP transport.
- Direct `foreign import` bindings to the **system SQLite** library for
  persistence and FTS5. Odin's standard library does not ship SQLite, and
  vendoring a SQLite amalgamation would contradict the single-binary,
  no-embedded-scripting goal.
- Python is used only for auxiliary black-box tests under `scripts/`. No Python
  (or any other language) is embedded in the binary.

## Status

This is a **phase-1 vertical slice**, not yet feature-complete with the Go
implementation. The implemented surface is listed in [PARITY.md](PARITY.md).

Implemented now:

- SQLite schema compatible with Engram's core tables and FTS5 indexes/triggers.
- Project detection: explicit project, `ENGRAM_PROJECT`, `.engram/config.json`,
  Git origin remote / repository root, single child repository, directory
  basename.
- Sessions, observations, prompts, topic upserts, exact dedupe, review dates,
  pin/unpin, soft/hard delete, timeline, context rendering, stats, projects.
- CLI: `save`, `search`, `get`, `context`, `timeline`, `stats`, `projects`,
  `delete`, `session`, `prompt`, `init`, `doctor`, `mcp`.
- MCP stdio: `initialize`, `tools/list`, `tools/call`, and 20 memory tools
  including save/search/context/session/prompt/review/pin/timeline/update/delete.

Deferred (see PARITY.md): cloud sync and autosync, HTTP server, TUI, Obsidian
export, setup installers, relation/conflict scanning, consolidation, passive
capture, and full replay-ledger parity.

## Requirements

- Odin `dev-2026-10` or compatible.
- System SQLite 3 with FTS5 and the `trigram` tokenizer. On Debian/Ubuntu:

  ```sh
  sudo apt install libsqlite3-dev sqlite3
  ```

  Verify FTS5 trigram support:

  ```sh
  sqlite3 :memory: "CREATE VIRTUAL TABLE t USING fts5(x, tokenize='trigram');"
  ```

## Build

```sh
make build
./ctxdb version
```

or directly:

```sh
odin build . -out:ctxdb
```

## Use

The data directory defaults to `~/.engram` and uses the same `engram.db`
filename as the Go implementation. A nonblank `ENGRAM_DATA_DIR` must be an
absolute path.

```sh
export ENGRAM_DATA_DIR="$HOME/.engram"

./ctxdb init my-project
./ctxdb save "JWT auth middleware" "**What**: ..." --type architecture --topic architecture/auth
./ctxdb search "auth"
./ctxdb context
./ctxdb timeline 1
./ctxdb stats
./ctxdb projects list
```

MCP stdio (newline-delimited JSON-RPC):

```sh
./ctxdb mcp --project my-project
```

Example request:

```json
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"mem_search","arguments":{"query":"auth"}}}
```

## Test

```sh
make test
```

`scripts/smoke.py` drives the built binary as a black box and asserts CLI,
MCP, schema, dedupe, topic-revision, search, context, and delete behavior. It
uses only Python's standard library.

## Layout

```text
main.odin              CLI entry point and command dispatch
project/detect.odin    project identity resolution (Git config read directly)
store/                 SQLite schema, sessions, observations, search, prompts
sqlite/                minimal SQLite3 bindings and statement wrapper
mcp/                   stdio MCP server and tool contract
util/                  normalization, redaction, hashing, truncation
scripts/smoke.py       auxiliary black-box test (not embedded)
```

## Design notes

- **One writer path:** the store opens one SQLite connection per process and
  serializes writes with `BEGIN IMMEDIATE`. FTS triggers mirror the Go schema.
- **Compatibility:** `migrate()` creates missing tables/indexes and adds missing
  core columns to older stores. It does not drop data.
- **Redaction:** `<private>...</private>` content is replaced by `[REDACTED]`
  before persistence, as in Engram.
- **Replay safety:** `mem_save` accepts an optional `operation_id`; the
  `observation_save_operations` ledger returns an identical replay and rejects
  a changed payload.
- **Known limitation:** Unicode NFC normalization for project names is not
  implemented in phase 1 (Odin's standard library does not provide Unicode
  normalization tables). ASCII case folding, trimming, and separator collapsing
  behave like Engram.
- **Git identity:** `.git/config` and `.git` worktree files are parsed directly
  instead of spawning `git`, keeping identity resolution dependency-free.
