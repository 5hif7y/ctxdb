# Graph Report - ctxdb  (2026-10-22)

## Corpus Check
- 4 files · ~3,296 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 29 file(s) not represented in the graph (top: .odin 27, (none) 2)

## Summary
- 42 nodes · 63 edges · 7 communities (3 shown, 4 thin omitted)
- Extraction: 98% EXTRACTED · 2% INFERRED · 0% AMBIGUOUS · INFERRED: 1 edges (avg confidence: 0.95)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `07126a34`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- ctxdb
- mcp
- Parity with Engram (Go)
- main
- main

## God Nodes (most connected - your core abstractions)
1. `main()` - 12 edges
2. `ctxdb` - 8 edges
3. `mcp()` - 6 edges
4. `run()` - 4 edges
5. `Parity with Engram (Go)` - 4 edges
6. `main()` - 3 edges
7. `tool_text()` - 2 edges
8. `drain()` - 2 edges
9. `send()` - 2 edges
10. `Status` - 2 edges

## Surprising Connections (you probably didn't know these)
- `Status` --references--> `mcp()`  [INFERRED]
  README.md → scripts/smoke.py

## Import Cycles
- None detected.

## Communities (7 total, 4 thin omitted)

### Community 0 - "ctxdb"
Cohesion: 0.25
Nodes (8): Build, ctxdb, Design notes, Layout, Requirements, Status, Test, Use

### Community 3 - "Parity with Engram (Go)"
Cohesion: 0.33
Nodes (4): Deferred / not yet ported, Deliberate differences, Implemented, Parity with Engram (Go)

### Community 6 - "main"
Cohesion: 1.00
Nodes (3): main(), drain(), send()

## Knowledge Gaps
- **4 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `ctxdb` connect `ctxdb` to `Parity with Engram (Go)`?**
  _High betweenness centrality (0.487) - this node is a cross-community bridge._
- **Why does `mcp()` connect `mcp` to `ctxdb`, `smoke.py`, `main`?**
  _High betweenness centrality (0.478) - this node is a cross-community bridge._
- **Why does `Status` connect `ctxdb` to `mcp`?**
  _High betweenness centrality (0.444) - this node is a cross-community bridge._