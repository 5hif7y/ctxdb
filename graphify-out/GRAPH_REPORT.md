# Graph Report - ctxdb  (2026-10-22)

## Corpus Check
- 3 files · ~2,758 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 25 file(s) not represented in the graph (top: .odin 23, (none) 2)

## Summary
- 34 nodes · 48 edges · 5 communities (3 shown, 2 thin omitted)
- Extraction: 98% EXTRACTED · 2% INFERRED · 0% AMBIGUOUS · INFERRED: 1 edges (avg confidence: 0.95)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `b1f06bbe`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- ctxdb
- mcp
- Parity with Engram (Go)
- main

## God Nodes (most connected - your core abstractions)
1. `main()` - 12 edges
2. `ctxdb` - 8 edges
3. `mcp()` - 6 edges
4. `run()` - 4 edges
5. `Parity with Engram (Go)` - 4 edges
6. `tool_text()` - 2 edges
7. `Status` - 2 edges
8. `Auxiliary smoke test for the Odin ctxdb port. This script is deliberately…` - 1 edges
9. `Implemented` - 1 edges
10. `Deferred / not yet ported` - 1 edges

## Surprising Connections (you probably didn't know these)
- `Status` --references--> `mcp()`  [INFERRED]
  README.md → scripts/smoke.py

## Import Cycles
- None detected.

## Communities (5 total, 2 thin omitted)

### Community 0 - "ctxdb"
Cohesion: 0.29
Nodes (7): Build, ctxdb, Design notes, Layout, Requirements, Test, Use

### Community 1 - "mcp"
Cohesion: 0.40
Nodes (3): Status, mcp(), run()

### Community 3 - "Parity with Engram (Go)"
Cohesion: 0.33
Nodes (4): Deferred / not yet ported, Deliberate differences, Implemented, Parity with Engram (Go)

## Knowledge Gaps
- **2 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `ctxdb` connect `ctxdb` to `mcp`, `Parity with Engram (Go)`?**
  _High betweenness centrality (0.574) - this node is a cross-community bridge._
- **Why does `mcp()` connect `mcp` to `smoke.py`, `main`?**
  _High betweenness centrality (0.521) - this node is a cross-community bridge._
- **Why does `Status` connect `mcp` to `ctxdb`?**
  _High betweenness centrality (0.492) - this node is a cross-community bridge._