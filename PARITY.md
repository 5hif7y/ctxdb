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
| Relations / judgments | ✅ core | `mem_judge`, `mem_judge_many`, `mem_compare`, conflict list/show/stats, lexical candidate scan |
| Semantic conflict scan | ✅ | locked prompt, `claude`/`opencode` external runner, dry-run/apply, CLI + HTTP |
| TUI | ✅ core | dashboard, search, recent, detail, timeline, sessions, session detail; ANSI/termios |
| Agent skill / setup | ✅ minimal | portable `SKILL.md`, print-only MCP snippets, optional skill install; no per-agent config writes |
| Consolidation | ✅ core | preview/confirm merge, provenance footer, internal fingerprint |
| Passive capture | ✅ core | Key Learnings / Aprendizajes numbered and bullet parsing |
| Session finalization | ✅ | summary observation + ended session + local finalization journal |
| Export / import | ✅ core | Engram backup shape 0.2.0; stale/duplicate handling |
| Local git sync | ✅ core | gzipped content-addressed chunks + manifest + synced-chunk tracking; cloud mutations deferred |
| Compatibility / migrate-copy | ✅ | read-only inspection and `VACUUM INTO` copy migration |
| Obsidian export | ✅ | incremental state, markdown notes/frontmatter, session/topic hubs, graph.json preserve/force/skip, polling `--watch` |
| HTTP serve API | ✅ subset | local JSON routes for sessions, observations, search, context, prompts, stats, export/import, conflicts, review, passive, consolidate |
| Project maintenance | ✅ core | merge variants, prune empty projects, delete session/prompt/project |
| Context | ✅ | sessions, prompts, pinned, recent unpinned observations |
| Timeline | ✅ | before/after/session/total |
| Prompts | ✅ | add, recent, FTS/LIKE search |
| Stats / projects | ✅ | global and per-project counts |
| Pin / review / delete | ✅ | soft/hard delete, review list and mark-reviewed |
| CLI | ✅ subset | see README |
| MCP stdio | ✅ | 27 tools, newline JSON-RPC, tool schemas |

## Deferred / not yet ported

| Area | Why deferred |
|---|---|
| Cloud sync mutations / delivery | Local chunk sync works, but mutation ledgers, deferred relations, tombstones and cloud acknowledgements are not ported |
| Cloud transport/autosync | Depends on the cloud backend, Postgres, and auth; out of this phase |
| Full per-agent installers | The print-only setup and portable skill cover the agnostic path; plugin/marketplace/npm installers are intentionally not ported |
| TUI cloud/setup screens | Local memory screens only; cloud/setup UI remains out of scope |
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
- `mem_update`/`mem_delete` accept IDs directly; the Go implementation
  additionally requires `expected_project` on public MCP calls. Ownership
  assertions remain a hardening item.
- Consolidation fingerprints are internally consistent but are not byte-for-byte
  identical to the Go v2 fingerprint.
- Conflict scan uses local FTS similarity unless `--semantic` is set; the
  semantic path shells out to an external agent CLI.
- The Obsidian state file uses string observation IDs (Go uses numeric keys);
  the vault layout and hub names match, but the state file is not interchangeable.
- `setup` is print-only and skill-oriented, unlike Go's per-agent installers.
  It never rewrites host configuration files.
- Obsidian `--watch` is a polling loop (default 10m, minimum 1m). It applies
  `--force` and graph config only on the first cycle and runs one exporter per
  vault.
- The HTTP API implements the local route subset and does not implement cloud
  auth/dashboard routes.
- Python scripts are auxiliary tests only. They are never invoked by the binary.
