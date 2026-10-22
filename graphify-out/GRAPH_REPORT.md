# Graph Report - ctxdb  (2026-10-22)

## Corpus Check
- 7 files · ~8,139 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 33 file(s) not represented in the graph (top: .odin 31, (none) 2)

## Summary
- 103 nodes · 122 edges · 10 communities (8 shown, 2 thin omitted)
- Extraction: 98% EXTRACTED · 2% INFERRED · 0% AMBIGUOUS · INFERRED: 2 edges (avg confidence: 0.95)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `0a120e23`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- ctxdb
- Estudio: installers `setup` de agentes y `obsidian-export --watch`
- smoke.py
- RESUMEN-1 — Port de Engram a Odin (`ctxdb`)
- 5. Funcionalidad implementada
- ctxdb persistent memory
- 5. `obsidian-export --watch`
- mcp
- main

## God Nodes (most connected - your core abstractions)
1. `main()` - 12 edges
2. `5. Funcionalidad implementada` - 12 edges
3. `RESUMEN-1 — Port de Engram a Odin (`ctxdb`)` - 11 edges
4. `ctxdb persistent memory` - 10 edges
5. `Estudio: installers `setup` de agentes y `obsidian-export --watch`` - 9 edges
6. `ctxdb` - 8 edges
7. `mcp()` - 7 edges
8. `5. `obsidian-export --watch`` - 6 edges
9. `7. Plan propuesto por fases` - 5 edges
10. `4. Decisiones técnicas importantes` - 5 edges

## Surprising Connections (you probably didn't know these)
- `2. Qué hace el `setup` de Go (evidencia)` --references--> `mcp()`  [INFERRED]
  ESTUDIO-SETUP-WATCH.md → scripts/smoke.py
- `Status` --references--> `mcp()`  [INFERRED]
  README.md → scripts/smoke.py

## Import Cycles
- None detected.

## Communities (10 total, 2 thin omitted)

### Community 0 - "ctxdb"
Cohesion: 0.15
Nodes (11): Deferred / not yet ported, Deliberate differences, Implemented, Parity with Engram (Go), Build, ctxdb, Design notes, Layout (+3 more)

### Community 1 - "Estudio: installers `setup` de agentes y `obsidian-export --watch`"
Cohesion: 0.12
Nodes (15): 1. Resumen ejecutivo, 2. Qué hace el `setup` de Go (evidencia), 3. La alternativa agnóstica: skill + MCP, 4. Un `setup` mínimo que sí tiene sentido, 6. Matriz de decisión, 7. Plan propuesto por fases, 8. Veredicto, Conclusión sobre `setup` (+7 more)

### Community 3 - "RESUMEN-1 — Port de Engram a Odin (`ctxdb`)"
Cohesion: 0.13
Nodes (14): 10. Cómo continuar, 1. Objetivo, 2. Estado general, 3. Estructura del repositorio, 4. Decisiones técnicas importantes, 6. Build y verificación, 7. Variables de entorno, 8. Compatibilidad y límites conocidos (+6 more)

### Community 4 - "5. Funcionalidad implementada"
Cohesion: 0.17
Nodes (12): 5. Funcionalidad implementada, Conflict scan semántico con LLM, Consolidación, Export / import / mantenimiento, HTTP, MCP, Núcleo local, Obsidian (+4 more)

### Community 6 - "ctxdb persistent memory"
Cohesion: 0.18
Nodes (10): Compaction, Consolidation and conflicts, ctxdb persistent memory, Delivery guarantee, Passive capture, Save format, Session close, Tool discovery (+2 more)

### Community 7 - "5. `obsidian-export --watch`"
Cohesion: 0.33
Nodes (6): 5. `obsidian-export --watch`, Beneficio, Conclusión sobre watch, Estado actual de ctxdb, Lo que hace Go, Riesgos/cuidados antes de implementarlo

### Community 8 - "mcp"
Cohesion: 0.40
Nodes (3): Status, mcp(), run()

### Community 9 - "main"
Cohesion: 1.00
Nodes (3): main(), drain(), send()

## Knowledge Gaps
- **2 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `mcp()` connect `mcp` to `Estudio: installers `setup` de agentes y `obsidian-export --watch``, `smoke.py`?**
  _High betweenness centrality (0.258) - this node is a cross-community bridge._
- **Should `Estudio: installers `setup` de agentes y `obsidian-export --watch`` be split into smaller, more focused modules?**
  _Cohesion score 0.125 - nodes in this community are weakly interconnected._
- **Why does `Estudio: installers `setup` de agentes y `obsidian-export --watch`` connect `Estudio: installers `setup` de agentes y `obsidian-export --watch`` to `5. `obsidian-export --watch``?**
  _High betweenness centrality (0.194) - this node is a cross-community bridge._
- **Should `RESUMEN-1 — Port de Engram a Odin (`ctxdb`)` be split into smaller, more focused modules?**
  _Cohesion score 0.13333333333333333 - nodes in this community are weakly interconnected._
- **Why does `2. Qué hace el `setup` de Go (evidencia)` connect `Estudio: installers `setup` de agentes y `obsidian-export --watch`` to `mcp`?**
  _High betweenness centrality (0.179) - this node is a cross-community bridge._