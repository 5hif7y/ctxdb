# Graph Report - ctxdb  (2026-10-22)

## Corpus Check
- 6 files · ~7,383 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 33 file(s) not represented in the graph (top: .odin 31, (none) 2)

## Summary
- 92 nodes · 112 edges · 7 communities
- Extraction: 98% EXTRACTED · 2% INFERRED · 0% AMBIGUOUS · INFERRED: 2 edges (avg confidence: 0.95)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `533f4aa3`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- ctxdb
- Estudio: installers `setup` de agentes y `obsidian-export --watch`
- smoke.py
- RESUMEN-1 — Port de Engram a Odin (`ctxdb`)
- 5. Funcionalidad implementada
- tui_smoke.py
- 7. Plan propuesto por fases

## God Nodes (most connected - your core abstractions)
1. `main()` - 12 edges
2. `5. Funcionalidad implementada` - 12 edges
3. `RESUMEN-1 — Port de Engram a Odin (`ctxdb`)` - 11 edges
4. `Estudio: installers `setup` de agentes y `obsidian-export --watch`` - 9 edges
5. `ctxdb` - 8 edges
6. `mcp()` - 7 edges
7. `5. `obsidian-export --watch`` - 6 edges
8. `7. Plan propuesto por fases` - 5 edges
9. `4. Decisiones técnicas importantes` - 5 edges
10. `run()` - 4 edges

## Surprising Connections (you probably didn't know these)
- `2. Qué hace el `setup` de Go (evidencia)` --references--> `mcp()`  [INFERRED]
  ESTUDIO-SETUP-WATCH.md → scripts/smoke.py
- `Status` --references--> `mcp()`  [INFERRED]
  README.md → scripts/smoke.py

## Import Cycles
- None detected.

## Communities (7 total, 0 thin omitted)

### Community 0 - "ctxdb"
Cohesion: 0.15
Nodes (11): Deferred / not yet ported, Deliberate differences, Implemented, Parity with Engram (Go), Build, ctxdb, Design notes, Layout (+3 more)

### Community 1 - "Estudio: installers `setup` de agentes y `obsidian-export --watch`"
Cohesion: 0.12
Nodes (16): 1. Resumen ejecutivo, 2. Qué hace el `setup` de Go (evidencia), 3. La alternativa agnóstica: skill + MCP, 4. Un `setup` mínimo que sí tiene sentido, 5. `obsidian-export --watch`, 6. Matriz de decisión, 8. Veredicto, Beneficio (+8 more)

### Community 2 - "smoke.py"
Cohesion: 0.20
Nodes (5): Status, main(), mcp(), run(), tool_text()

### Community 3 - "RESUMEN-1 — Port de Engram a Odin (`ctxdb`)"
Cohesion: 0.13
Nodes (14): 10. Cómo continuar, 1. Objetivo, 2. Estado general, 3. Estructura del repositorio, 4. Decisiones técnicas importantes, 6. Build y verificación, 7. Variables de entorno, 8. Compatibilidad y límites conocidos (+6 more)

### Community 4 - "5. Funcionalidad implementada"
Cohesion: 0.17
Nodes (12): 5. Funcionalidad implementada, Conflict scan semántico con LLM, Consolidación, Export / import / mantenimiento, HTTP, MCP, Núcleo local, Obsidian (+4 more)

### Community 5 - "tui_smoke.py"
Cohesion: 0.18
Nodes (3): main(), drain(), send()

### Community 6 - "7. Plan propuesto por fases"
Cohesion: 0.40
Nodes (5): 7. Plan propuesto por fases, Fase 1 — Skill (sin cambios de binario), Fase 2 — `setup` mínimo, Fase 3 — Watch, Fase 4 — Installers específicos (solo si se justifica)

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `mcp()` connect `smoke.py` to `Estudio: installers `setup` de agentes y `obsidian-export --watch``?**
  _High betweenness centrality (0.325) - this node is a cross-community bridge._
- **Should `Estudio: installers `setup` de agentes y `obsidian-export --watch`` be split into smaller, more focused modules?**
  _Cohesion score 0.11764705882352941 - nodes in this community are weakly interconnected._
- **Why does `Estudio: installers `setup` de agentes y `obsidian-export --watch`` connect `Estudio: installers `setup` de agentes y `obsidian-export --watch`` to `7. Plan propuesto por fases`?**
  _High betweenness centrality (0.244) - this node is a cross-community bridge._
- **Should `RESUMEN-1 — Port de Engram a Odin (`ctxdb`)` be split into smaller, more focused modules?**
  _Cohesion score 0.13333333333333333 - nodes in this community are weakly interconnected._
- **Why does `2. Qué hace el `setup` de Go (evidencia)` connect `Estudio: installers `setup` de agentes y `obsidian-export --watch`` to `smoke.py`?**
  _High betweenness centrality (0.225) - this node is a cross-community bridge._