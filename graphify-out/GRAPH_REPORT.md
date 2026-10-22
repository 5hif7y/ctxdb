# Graph Report - ctxdb  (2026-10-22)

## Corpus Check
- 8 files · ~9,334 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 33 file(s) not represented in the graph (top: .odin 31, (none) 2)

## Summary
- 120 nodes · 138 edges · 8 communities
- Extraction: 99% EXTRACTED · 1% INFERRED · 0% AMBIGUOUS · INFERRED: 2 edges (avg confidence: 0.95)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `004c1642`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- ctxdb
- Estudio: installers `setup` de agentes y `obsidian-export --watch`
- smoke.py
- RESUMEN-1 — Port de Engram a Odin (`ctxdb`)
- 5. Funcionalidad implementada
- RESUMEN-2 — Skill portable, setup por agente y `setup pi`
- ctxdb persistent memory
- main

## God Nodes (most connected - your core abstractions)
1. `main()` - 12 edges
2. `5. Funcionalidad implementada` - 12 edges
3. `RESUMEN-1 — Port de Engram a Odin (`ctxdb`)` - 11 edges
4. `RESUMEN-2 — Skill portable, setup por agente y `setup pi`` - 11 edges
5. `ctxdb persistent memory` - 10 edges
6. `Estudio: installers `setup` de agentes y `obsidian-export --watch`` - 9 edges
7. `ctxdb` - 8 edges
8. `mcp()` - 7 edges
9. `5. `obsidian-export --watch`` - 6 edges
10. `2. `ctxdb setup pi`` - 6 edges

## Surprising Connections (you probably didn't know these)
- `Status` --references--> `mcp()`  [INFERRED]
  README.md → scripts/smoke.py
- `2. Qué hace el `setup` de Go (evidencia)` --references--> `mcp()`  [INFERRED]
  ESTUDIO-SETUP-WATCH.md → scripts/smoke.py

## Import Cycles
- None detected.

## Communities (8 total, 0 thin omitted)

### Community 0 - "ctxdb"
Cohesion: 0.14
Nodes (12): Deferred / not yet ported, Deliberate differences, Implemented, Parity with Engram (Go), Build, ctxdb, Design notes, Layout (+4 more)

### Community 1 - "Estudio: installers `setup` de agentes y `obsidian-export --watch`"
Cohesion: 0.09
Nodes (21): 1. Resumen ejecutivo, 2. Qué hace el `setup` de Go (evidencia), 3. La alternativa agnóstica: skill + MCP, 4. Un `setup` mínimo que sí tiene sentido, 5. `obsidian-export --watch`, 6. Matriz de decisión, 7. Plan propuesto por fases, 8. Veredicto (+13 more)

### Community 2 - "smoke.py"
Cohesion: 0.14
Nodes (4): main(), mcp(), run(), tool_text()

### Community 3 - "RESUMEN-1 — Port de Engram a Odin (`ctxdb`)"
Cohesion: 0.13
Nodes (14): 10. Cómo continuar, 1. Objetivo, 2. Estado general, 3. Estructura del repositorio, 4. Decisiones técnicas importantes, 6. Build y verificación, 7. Variables de entorno, 8. Compatibilidad y límites conocidos (+6 more)

### Community 4 - "5. Funcionalidad implementada"
Cohesion: 0.17
Nodes (12): 5. Funcionalidad implementada, Conflict scan semántico con LLM, Consolidación, Export / import / mantenimiento, HTTP, MCP, Núcleo local, Obsidian (+4 more)

### Community 5 - "RESUMEN-2 — Skill portable, setup por agente y `setup pi`"
Cohesion: 0.12
Nodes (16): 10. Cómo seguir, 1. Resultado de esta fase, 2. `ctxdb setup pi`, 3. `setup` para otros agentes, 4. Skill portable, 5. `obsidian-export --watch`, 6. Archivos principales, 7. Verificación (+8 more)

### Community 6 - "ctxdb persistent memory"
Cohesion: 0.18
Nodes (10): Compaction, Consolidation and conflicts, ctxdb persistent memory, Delivery guarantee, Passive capture, Save format, Session close, Tool discovery (+2 more)

### Community 9 - "main"
Cohesion: 1.00
Nodes (3): main(), drain(), send()

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `mcp()` connect `smoke.py` to `ctxdb`, `Estudio: installers `setup` de agentes y `obsidian-export --watch``?**
  _High betweenness centrality (0.190) - this node is a cross-community bridge._
- **Should `ctxdb` be split into smaller, more focused modules?**
  _Cohesion score 0.14285714285714285 - nodes in this community are weakly interconnected._
- **Why does `2. Qué hace el `setup` de Go (evidencia)` connect `Estudio: installers `setup` de agentes y `obsidian-export --watch`` to `smoke.py`?**
  _High betweenness centrality (0.131) - this node is a cross-community bridge._
- **Should `Estudio: installers `setup` de agentes y `obsidian-export --watch`` be split into smaller, more focused modules?**
  _Cohesion score 0.09090909090909091 - nodes in this community are weakly interconnected._
- **Should `smoke.py` be split into smaller, more focused modules?**
  _Cohesion score 0.14153846153846153 - nodes in this community are weakly interconnected._
- **Should `RESUMEN-1 — Port de Engram a Odin (`ctxdb`)` be split into smaller, more focused modules?**
  _Cohesion score 0.13333333333333333 - nodes in this community are weakly interconnected._
- **Should `RESUMEN-2 — Skill portable, setup por agente y `setup pi`` be split into smaller, more focused modules?**
  _Cohesion score 0.11764705882352941 - nodes in this community are weakly interconnected._