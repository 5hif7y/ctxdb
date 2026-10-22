---
name: ctxdb
description: Persistent project memory with ctxdb MCP tools. Use when starting work, recalling past decisions or bugs, saving durable findings, or closing and compacting a session.
---

# ctxdb persistent memory

`ctxdb` stores project-scoped decisions, discoveries, bug fixes, conventions,
and session summaries in a local SQLite database. Treat it as durable project
memory, not as a scratchpad.

## Tool discovery

Use the `mem_*` tools that your host actually exposes. The names in this skill
are logical names; the host may expose them with a server prefix. Do not assume
a particular prefix and do not call a tool that is not registered.

If the memory tools are unavailable, use the `ctxdb` CLI only when a shell is
available:

```sh
ctxdb search "<query>"
ctxdb context
ctxdb save "<title>" "<content>" --type <type> [--topic <key>]
```

Do not invent memory results. If neither MCP nor the CLI is available, continue
the task and say that persistent memory was unavailable.

## When to save

Call `mem_save` immediately, without waiting for the user to ask, after:

- an architecture or design decision;
- a convention, workflow, or tool choice with tradeoffs;
- a bug fix, including the root cause;
- a non-obvious discovery, gotcha, or edge case;
- a configuration or environment change;
- a user preference, constraint, confirmation, or rejection;
- a clear direction chosen after comparing options.

Do not save secrets, credentials, tokens, or private user data.

## Save format

Use a short, searchable title and structured content:

```text
What: one sentence describing what was done
Why: the motivation, bug, request, or tradeoff
Where: files, modules, or paths affected
Learned: gotchas and surprises (omit when empty)
```

Pass:

- `type`: `decision`, `architecture`, `bugfix`, `pattern`, `config`,
  `discovery`, `preference`, or `learning`;
- `scope`: `project` by default; use `personal` or `global` only when the
  knowledge really applies outside the project;
- `topic_key`: a stable key for an evolving topic, for example
  `architecture/auth-model`.

If the same topic evolves, call `mem_save` again with the same `topic_key` so
the observation is updated instead of duplicated. If unsure, call
`mem_suggest_topic_key` first. If you already know the exact observation ID,
use `mem_update` for a targeted correction.

## When to search

When the user asks to remember, recall, or resume past work:

1. Call `mem_context` first for recent session context.
2. If needed, call `mem_search` with focused keywords.
3. Use `mem_get_observation` to read the full untruncated observation.

Search proactively when:

- starting work that may have been done before;
- the first user message references a project, feature, or problem;
- the user mentions a topic you have no context on.

If the project is ambiguous, call `mem_current_project` or `mem_list_projects`
instead of guessing. Do not write to a foreign project by inventing its name.

## Session close

Before saying the work is done or ending a session, call
`mem_session_summary` with:

```text
## Goal
## Instructions
## Discoveries
## Accomplished
## Next Steps
## Relevant Files
```

If the host has an exact active session and the tool is available, prefer
`mem_session_finalize` to persist the summary and close the session atomically.
Do not invent or reuse a session ID. If the session is already closed, report
that instead of retrying with a different ID.

## Compaction

If the context is compacted or reset, first persist the compacted summary with
`mem_session_summary`, then call `mem_context` to recover additional context.
Only after that continue the task.

## Passive capture

When a task or subtask produces durable learnings, a `## Key Learnings:` section
is useful, but it is not a guarantee of capture. Use `mem_save` as the primary
path. You may call `mem_capture_passive` for text that already contains a
learning section.

## Consolidation and conflicts

Do not consolidate observations unless the user explicitly asks. Call
`mem_consolidate` without `confirm` first, show the preview, and apply only with
the returned fingerprint and explicit confirmation.

Record a relation only when the user asks you to compare or judge memories. Use
the locked vocabulary: `related`, `compatible`, `scoped`, `conflicts_with`,
`supersedes`, `not_conflict`.

## Delivery guarantee

Memory operations are internal bookkeeping, never the user-facing answer.
Complete the required memory work before composing the final reply. If memory
work fails, still answer the user and mention the failure once; do not expose
raw database paths, SQL, or internal tool payloads.
