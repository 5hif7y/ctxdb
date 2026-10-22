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

This is an incremental port. The local memory surface is implemented; cloud
transport, per-agent installers and some legacy migrations remain deferred.
See [PARITY.md](PARITY.md).

Implemented now:

- SQLite schema compatible with Engram's core tables and FTS5 indexes/triggers.
- Project detection: explicit project, `ENGRAM_PROJECT`, `.engram/config.json`,
  Git origin remote / repository root, single child repository, directory
  basename.
- Sessions, observations, prompts, topic upserts, exact dedupe, review dates,
  pin/unpin, soft/hard delete, timeline, context rendering, stats, projects.
- Relations/conflict judgments: FTS candidate scan, `mem_judge`, `mem_compare`,
  conflict list/show/stats, and project-scoped relation persistence.
- Semantic conflict scan through an external `claude` or `opencode` CLI
  (`ENGRAM_AGENT_CLI`), with the locked Engram relation prompt.
- Interactive terminal UI (`tui`) for dashboard, search, recent observations,
  detail/timeline, sessions and session detail.
- Portable Agent Skills memory protocol and a print-only `setup` command that
  prints MCP snippets and installs the skill without rewriting agent config.
- Consolidation: preview/confirm merge with provenance footer and fingerprint.
- Passive capture: Key Learnings / Aprendizajes extraction.
- Atomic session finalization with a durable local retry journal.
- Local JSON export/import, git-style gzipped sync chunks with a manifest,
  and incremental Obsidian markdown export with session/topic hubs, graph
  configuration and an optional polling watch mode.
- Local HTTP JSON API (`serve`) over the same store.
- CLI: `save`, `search`, `get`, `context`, `timeline`, `stats`, `projects`,
  `delete`, `session`, `prompt`, `export`, `import`, `conflicts`,
  `obsidian-export`, `sync`, `compatibility`, `migrate-copy`, `init`,
  `doctor`, `tui`, `setup`, `serve`, `mcp`.
- MCP stdio: `initialize`, `tools/list`, `tools/call`, and 27 memory tools.

Deferred (see PARITY.md): cloud transport/autosync and its Postgres backend,
full per-agent installers, TUI cloud/setup screens, some `doctor` repair
operations, and some legacy migration branches.

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
./ctxdb export backup.json --all
./ctxdb import backup.json
./ctxdb obsidian-export --vault ~/vault --all
./ctxdb obsidian-export --vault ~/vault --all --watch --interval 10m
./ctxdb conflicts scan --project my-project --apply
./ctxdb sync --all              # write .engram/chunks/*.jsonl.gz + manifest
./ctxdb sync --status
./ctxdb serve 7437
```

Semantic scan requires one of the external agent CLIs already installed and
authenticated. Selection uses `--runner` or `ENGRAM_AGENT_CLI`:

```sh
ENGRAM_AGENT_CLI=claude ./ctxdb conflicts scan --semantic --project my-project --apply
ENGRAM_AGENT_CLI=opencode ./ctxdb conflicts scan --semantic --project my-project --apply
```

Agent setup / skill:

```sh
./ctxdb setup                         # list targets
./ctxdb setup generic                 # print an MCP snippet, no writes
./ctxdb setup claude-code             # print the Claude CLI command
./ctxdb setup --install-skill         # install ~/.agents/skills/ctxdb/SKILL.md
./ctxdb setup opencode --install-skill --skill-dir ~/.config/opencode/skills
```

`ctxdb setup` is deliberately print-only for agent configuration. It does not
rewrite `~/.claude.json`, `opencode.json`, `config.toml`, or any other host
config. The portable skill uses logical `mem_*` names and works with any Agent
Skills client; register `ctxdb` as a separate MCP server.

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
MCP, HTTP, sync, export/import, semantic scan, consolidation, passive capture,
finalization, setup/skill, Obsidian one-shot and watch, and delete behavior.
`scripts/tui_smoke.py` drives the TUI through a PTY. Both use only Python's
standard library.

## Layout

```text
main.odin              CLI entry point and command dispatch
project/detect.odin    project identity resolution (Git config read directly)
store/                 SQLite schema, sessions, observations, search, prompts,
                       relations, consolidation, export/import, maintenance
sqlite/                minimal SQLite3 bindings and statement wrapper
mcp/                   stdio MCP server and tool contract
server/                local HTTP JSON API over core:net
obsidian/              incremental markdown vault exporter + hubs/graph/watch
llm/                   external agent CLI semantic runner
tui/                   interactive ANSI terminal UI with termios raw mode
setup/                 print-only MCP snippets + portable skill installer
skills/ctxdb/          portable Agent Skills memory protocol
util/                  normalization, redaction, hashing, truncation
scripts/smoke.py       auxiliary black-box test (not embedded)
scripts/tui_smoke.py   auxiliary PTY smoke test (not embedded)
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
- **HTTP server:** `serve` binds `127.0.0.1` by default and exposes the local
  JSON route subset used by CLI/MCP integrations. It is a local API, not the
  cloud sync transport.
- **TUI:** ANSI rendering and termios raw mode are implemented directly in
  Odin. It targets Linux terminals and polls terminal size on each frame.
- **Semantic LLM:** the runner shells out to `claude` or `opencode`; no model
  SDK or HTTP/TLS client is embedded. Timeouts are delegated to the agent CLI.
- **Agent setup:** print-only by design. The portable skill is the agnostic
  layer; each host owns its MCP registration. The installer only writes
  `SKILL.md` when `--install-skill` is requested.
- **Obsidian watch:** polling loop with an immediate first cycle, atomic state
  replacement and `SIGINT`/`SIGTERM` shutdown on POSIX. `--force` and graph
  config apply only to the first cycle. Run one exporter per vault; scoped
  exports cannot retire notes for rows outside their snapshot.
- **Known limitation:** Unicode NFC normalization for project names is not
  implemented in this port (Odin's standard library does not provide Unicode
  normalization tables). ASCII case folding, trimming, and separator collapsing
  behave like Engram.
- **Git identity:** `.git/config` and `.git` worktree files are parsed directly
  instead of spawning `git`, keeping identity resolution dependency-free.
