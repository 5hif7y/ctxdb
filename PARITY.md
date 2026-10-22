# Parity with Engram (Go)

This table tracks the Odin port's current surface. Source of truth for the Go
behavior is the `engram/` repository; when this table and the source disagree,
the source wins.

## Implemented

| Area | Status | Notes |
|---|---|---|
| Local store schema | ✅ core | Sessions, observations, prompts, FTS5 trigram, triggers, review columns, operation ledger table |
| Schema migration | ✅ additive | Creates missing core objects and columns; does not migrate every legacy branch |
| Project normalization | ⚠️ partial | lowercase/trim/collapse `--`/`__`; NFC deferred |
| Project detection | ✅ core | explicit, `ENGRAM_PROJECT`, config, git origin/root, single child, basename |
| Save observation | ✅ | redaction, truncation, scope, dedupe, topic upsert, review dates, sync id |
| Replay-safe saves | ✅ v1 ledger | same fingerprint algorithm and conflict/expiry errors |
| Search | ✅ | topic direct hit, FTS5 trigram, short-term LIKE fallback, bm25 composite rank, filters |
| Context | ✅ | sessions, prompts, pinned, recent unpinned observations |
| Timeline | ✅ | before/after/session/total |
| Prompts | ✅ | add, recent, FTS/LIKE search |
| Stats / projects | ✅ | global and per-project counts |
| Pin / review / delete | ✅ | soft/hard delete, review list and mark-reviewed |
| CLI | ✅ subset | see README |
| MCP stdio | ✅ subset | 20 tools, newline JSON-RPC, tool schemas |

## Deferred / not yet ported

| Area | Why deferred |
|---|---|
| Sync chunks / mutations | Requires export/import, chunk codec, manifest/cursors, tombstones — next phase |
| Cloud transport/autosync | Depends on sync and auth; out of phase 1 |
| HTTP `serve` API | No HTTP server in Odin core; will be implemented over `core:net` or a thin C binding |
| TUI | Bubble Tea equivalent not ported |
| Obsidian export | Separate exporter |
| Setup/plugin installers | Filesystem/agent-specific installers |
| Relations / conflicts | `memory_relations`, judge/compare/scan flows |
| Consolidation / merge / prune | Curation operations |
| Passive capture / learnings extraction | Regex-heavy heuristic; port later |
| Session finalization journal | `session_finalizations` table exists; flow not ported |
| `doctor` repair | Read-only doctor only; repair operations deferred |
| Full legacy migration matrix | Core additive columns only; Go migration branches are not all reproduced |
| Unicode NFC project names | No normalization tables in Odin stdlib; a pure-Odin table can be added later |
| Local-time formatting | CLI prints stored SQLite timestamps; Go uses `timeutil.FormatLocal` |

## Deliberate differences

- SQLite is linked from the **system** library (`system:sqlite3`) instead of a
  vendored Go driver.
- MCP results may wrap full observations in an `{"observation": …, "state": …}`
  object where the Go server returns a flatter shape. Tool names and argument
  contracts match.
- `mem_save` does not yet implement automatic prompt capture (`capture_prompt`).
- `mem_update`/`mem_delete` accept IDs directly in phase 1; the Go implementation
  additionally requires `expected_project` on public MCP calls. Ownership
  assertions are a next-phase hardening item.
- Python scripts are auxiliary tests only. They are never invoked by the binary.
