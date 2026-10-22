# RESUMEN-1 — Port de Engram a Odin (`ctxdb`)

Fecha de este resumen: 2026-10-22

> **Actualización posterior:** se implementaron la skill portable,
> `ctxdb setup` (print-only + `--install-skill`) y `obsidian-export --watch`.
> Ver `ESTUDIO-SETUP-WATCH.md` y el commit de esa fase. Las secciones que
> listan setup/watch como pendientes son históricas.
Repositorio: `/home/shifty/AI-DEV/engram-port/ctxdb`
Remoto: `git@github.com:5hif7y/ctxdb.git`
Rama: `main`
Último commit: `9948201 feat: port TUI, semantic LLM scan, and incremental Obsidian export`

---

## 1. Objetivo

Portear **Engram** (implementación Go en `/home/shifty/AI-DEV/engram-port/engram`)
a **Odin** en el repositorio `ctxdb`, prefiriendo Odin puro. Se permiten scripts
auxiliares en Python siempre que **no sean scripting embebido** en el binario.

El resultado es un binario Odin `ctxdb` que abre la misma base SQLite local
(`~/.engram/engram.db` o `ENGRAM_DATA_DIR`), con CLI, MCP, HTTP, TUI, sync local,
export/import, Obsidian y funcionalidades locales de memoria.

---

## 2. Estado general

El port cubre **todo el núcleo local** y las tres funcionalidades pedidas
adicionales:

1. TUI interactiva.
2. Conflict scan semántico vía LLM externo.
3. Export Obsidian incremental con graph layout.

Quedan fuera únicamente las piezas de infraestructura cloud/Postgres/auth,
los instaladores `setup` de agentes y el modo `obsidian-export --watch`.

Commits realizados:

```text
9948201 feat: port TUI, semantic LLM scan, and incremental Obsidian export
07126a3 feat: complete local Engram feature surface
b1f06bb feat: port Engram memory core to Odin
```

El árbol está limpio y `origin/main` está actualizado.

---

## 3. Estructura del repositorio

```text
main.odin                 CLI, dispatch de comandos, helpers de salida
project/detect.odin       Detección de proyecto (git/config/ENGRAM_PROJECT/dir)
store/                    Núcleo SQLite y reglas de memoria
  store.odin              Config, Open/Close, helpers generales
  schema.odin             DDL compatible, migraciones aditivas, FTS rebuild
  types.odin              Structs y tipos públicos
  observations.odin       Save/get/update/delete, dedupe, topic upsert, timeline
  search.odin             FTS5 trigram, LIKE fallback, ranking compuesto
  sessions.odin           Sesiones, leases, manual sessions
  prompts.odin            Prompts y búsqueda
  projects.odin           Contexto, stats, proyectos, suggest topic key
  relations.odin          Relaciones, judge, compare, scan léxico, candidates
  consolidate.odin        Consolidación atómica con fingerprint
  passive.odin            Extracción de Key Learnings / Aprendizajes
  session_finalize.odin   Finalize atómico + journal local
  export.odin             Export/import JSON backup 0.2.0
  maintenance.odin        Deletes, merge/prune, sync chunk tracking
  compat.odin             compatibility read-only y migrate-copy
sqlite/sqlite.odin        Bindings SQLite3 + wrapper de statements
mcp/mcp.odin              Servidor MCP stdio, 27 herramientas
server/server.odin        API HTTP JSON local sobre core:net
obsidian/export.odin      Export Obsidian incremental, hubs, graph.json
llm/llm.odin              Runner semántico externo claude/opencode
tui/                      TUI ANSI/termios
sync/sync.odin            Sync local git-style: chunks gzip + manifest
util/text.odin            Normalización, redacción, hashes, truncado
scripts/smoke.py          Test black-box CLI/MCP/HTTP/etc.
scripts/tui_smoke.py      Test PTY de la TUI
```

Documentación:

- `README.md`: build, uso, requisitos, diseño.
- `PARITY.md`: paridad con Engram y pendientes.
- `graphify-out/`: índice Graphify actualizado (no reconoce `.odin`; cobertura limitada).

---

## 4. Decisiones técnicas importantes

### SQLite

- Se enlaza contra la librería del sistema: `foreign import "system:sqlite3"`.
- Requiere SQLite con FTS5 y tokenizer `trigram`.
- No se vendoriza SQLite ni se embebe scripting.
- Se usa `SQLITE_TRANSIENT` al bindear texto para que SQLite copie el string y
  evitar use-after-free con temporales.
- `sqlite.exec` usa un buffer NUL-terminado propio; `sqlite.prepare` usa
  `nByte` y no retiene el buffer.

### Memoria / strings en Odin

Se encontraron y corrigieron varios pitfalls:

- `strings.replace_all` devuelve **dos** valores `(string, bool)`.
- La concatenación con `+` solo funciona con strings constantes; para runtime
  se usa `cat(...)` (`strings.concatenate`).
- Strings devueltos desde un `Builder` deben clonarse antes de destruirlo.
- `defer` en Odin está ligado al scope del bloque; no asumir semántica Go.
- `exact_slice` copia un dynamic array a un slice de tamaño exacto y libera el
  original; así `delete(slice)` es seguro.
- Evitar `delete` sobre slices que no son exactos (especialmente salidas de
  `os.process_exec`).
- Evitar `defer delete(x)` cuando `exact_slice(x)` ya libera `x` (doble free).
- No hacer `delete(command)` sobre un slice literal estático.

### Fechas

- El store usa timestamps SQLite (`datetime('now')` / `store.Now`).
- `review_after` se calcula con SQL (`datetime('now', '+N months')`).
- No se implementó formato local tipo Go `timeutil.FormatLocal`; la CLI imprime
  el timestamp almacenado.

### Proyecto

- Normalización: trim + lowercase + colapso de `--` y `__`.
- **NFC Unicode no implementado** (Odin stdlib no trae tablas de normalización).
- Git se lee directamente de `.git/config` y archivos `.git` worktree, sin
  lanzar `git`.

---

## 5. Funcionalidad implementada

### Núcleo local

- Esquema compatible con Engram: sessions, observations, user_prompts,
  memory_relations, FTS5, triggers, sync tables, ledger de operaciones, etc.
- Migraciones aditivas y reconstrucción de FTS si el índice está vacío o
  desincronizado (comparando `*_fts_docsize`).
- Sesiones: create/start/end/get, manual sessions, ownership modes.
- Observaciones: save, get, update, delete soft/hard, pin/unpin, review.
- Dedupe exacto por hash + ventana temporal.
- Topic upsert con `revision_count`.
- Redacción `<private>...</private>`.
- Truncado seguro UTF-8.
- Search: topic key directo, FTS5 trigram, fallback LIKE para términos cortos,
  ranking BM25 compuesto (pinned/recencia/estabilidad).
- Context markdown, timeline, stats, proyectos.
- Prompts: save, recent, search.
- Replay-safe saves con `observation_save_operations` y fingerprint v1.

### Relaciones / conflictos

- `memory_relations` con vocabulario bloqueado:
  `related`, `compatible`, `scoped`, `conflicts_with`, `supersedes`,
  `not_conflict`.
- `JudgeRelation`, `JudgeBySemantic`, `ListRelations`, `GetRelation`,
  `RelationStats`.
- `ScanProject` léxico por FTS.
- `FindCandidatePairs` para scan semántico sin escribir.
- CLI:
  `conflicts list|show|stats|scan|judge|compare`.
- MCP:
  `mem_judge`, `mem_judge_many`, `mem_compare`.
- HTTP:
  `/conflicts`, `/conflicts/stats`, `/conflicts/{id}`,
  `/conflicts/judge`, `/conflicts/compare`, `/conflicts/scan`.

### Consolidación

- Preview/confirm atómico.
- Fingerprint interno v2 (no byte-idéntico al Go).
- Footer `## consolidated_from`.
- Soft-delete de fuentes con `superseded_by_sync_id`.
- CLI vía MCP/HTTP; no hay comando CLI dedicado.

### Passive capture / finalize

- Extracción de `Key Learnings` / `Aprendizajes` (numeradas y bullets).
- Guardado como observaciones `learning` con dedupe por hash.
- `FinalizeSession`: observación `session_summary` + cierre de sesión +
  `session_finalizations`, atómico.

### Export / import / mantenimiento

- Export/import JSON backup versión `0.2.0`.
- CLI `export [file] [--project|--all]`, `import <file>`.
- `delete session|prompt|project`.
- `projects merge --from A,B --to C [--apply]`.
- `projects prune [--dry-run]`.
- `compatibility [--data-dir DIR] [--json]` (read-only).
- `migrate-copy --data-dir SRC --output-dir DST --confirm-quiescent`.

### Sync local git-style

- `ctxdb sync [--import|--status] [--project|--all] [--dir .engram]`.
- Chunks gzip content-addressed (`chunks/<sha8>.jsonl.gz`), manifest `version 2`.
- Writer gzip con bloques stored (Odin no trae compresor gzip, sí lector).
- Tracking en `sync_chunks` target `local`.
- Es un subconjunto local; **no implementa mutations/deferred/cloud ack**.

### HTTP

`ctxdb serve [port] [--project NAME]`, por defecto `127.0.0.1:7437`.

Rutas principales:
- `/health`, `/stats`, `/projects`, `/project/current`
- `/sessions`, `/sessions/recent`, `/sessions/{id}`, `/sessions/{id}/end`,
  `/sessions/{id}/finalize`
- `/observations`, `/observations/recent`, `/observations/{id}`,
  `/observations/{id}/pin`, `/observations/passive`,
  `/observations/consolidate`, `/observations/save-result`
- `/search`, `/context`, `/timeline`
- `/prompts`, `/prompts/recent`, `/prompts/search`
- `/review`, `/review/mark_reviewed`
- `/export`, `/import`
- `/conflicts`, `/conflicts/stats`, `/conflicts/{id}`, `/conflicts/judge`,
  `/conflicts/compare`, `/conflicts/scan` (incluye `semantic`)
- `/topic-keys/suggest`, `/doctor`

No implementa auth/dashboard/cloud.

### MCP

Servidor stdio con JSON-RPC newline-delimited. 27 herramientas, incluyendo:

`mem_save`, `mem_search`, `mem_get_observation`, `mem_context`,
`mem_session_start`, `mem_session_end`, `mem_session_summary`,
`mem_save_prompt`, `mem_search_prompts`, `mem_current_project`,
`mem_list_projects`, `mem_timeline`, `mem_delete`, `mem_update`, `mem_stats`,
`mem_suggest_topic_key`, `mem_pin`, `mem_unpin`, `mem_review`, `mem_doctor`,
`mem_judge`, `mem_judge_many`, `mem_compare`, `mem_consolidate`,
`mem_capture_passive`, `mem_session_finalize`, `mem_merge_projects`.

### TUI

`ctxdb tui [--project NAME]`.

Implementación propia ANSI + `termios` raw mode, sin Bubble Tea.

Pantallas:
- Dashboard (stats + menú).
- Search con input.
- Resultados.
- Recent observations.
- Detail con scroll.
- Timeline.
- Sessions.
- Session detail.

Teclas: `j/k` o flechas, `enter`, `t` (timeline), `esc`, `q`.

Archivos:
- `tui/tui.odin`
- `tui/terminal_size_linux.odin`
- `tui/terminal_size_other.odin`

Limitaciones: Linux/termios, sin pantallas cloud/setup, sin resize avanzado
(mide tamaño cada frame).

### Conflict scan semántico con LLM

`llm/llm.odin` delegatea a un CLI externo:

```sh
ENGRAM_AGENT_CLI=claude   ctxdb conflicts scan --semantic --project P --apply
ENGRAM_AGENT_CLI=opencode ctxdb conflicts scan --semantic --project P --apply
```

- Prompt canónico bloqueado (mismo vocabulario).
- Parseo envelope Claude y NDJSON OpenCode.
- Validación de relación/confianza.
- CLI flags: `--semantic`, `--runner`, `--max-semantic`, `--apply`.
- HTTP: `POST /conflicts/scan` con `"semantic": true`.
- No hay SDK ni HTTP/TLS embebido: usa el CLI del agente ya autenticado.
- Timeouts delegados al CLI externo.

### Obsidian

`ctxdb obsidian-export --vault DIR [--project|--all] [--limit N]
[--since DATE] [--force] [--graph-config preserve|force|skip]`.

Implementado:
- Notas markdown por observación con frontmatter, H1, contenido y wikilinks.
- Layout `engram/<project>/<type>/<slug>-<id>.md`.
- Estado incremental `engram/.engram-sync-state.json`.
- Reconciliación de soft/hard deletes.
- Hubs `_sessions/<session>.md`.
- Hubs `_topics/<prefix>.md` (≥2 observaciones).
- `graph.json` en `.obsidian/` con modos preserve/force/skip.
- El state file usa IDs string (Go usa map[int64]); el layout es similar pero
  el state no es intercambiable.

---

## 6. Build y verificación

Requisitos:

- Odin `dev-2026-10` o compatible.
- `libsqlite3-dev` / SQLite con FTS5 trigram.
- Python 3 solo para tests auxiliares.

Comandos:

```sh
cd /home/shifty/AI-DEV/engram-port/ctxdb
make build          # odin build . -out:ctxdb
make check          # odin check . -vet
make test           # build + smoke.py + tui_smoke.py
```

Tests existentes:

- `scripts/smoke.py`: CLI, MCP, HTTP, sync, export/import, semantic scan con
  fake `claude`, consolidación, passive, finalize, Obsidian, deletes, schema.
- `scripts/tui_smoke.py`: TUI vía PTY real; valida dashboard, recent, timeline.

Para probar semantic scan sin un LLM real, se puede crear un fake `claude`:

```sh
mkdir -p /tmp/fakebin
cat > /tmp/fakebin/claude <<'EOF'
#!/bin/sh
cat >/dev/null
printf '%s\n' '{"type":"result","result":"{\"Relation\":\"related\",\"Confidence\":0.9,\"Reasoning\":\"fake\"}","duration_ms":5,"modelUsage":{"fake-model":{}}}'
EOF
chmod +x /tmp/fakebin/claude
PATH=/tmp/fakebin:$PATH ENGRAM_AGENT_CLI=claude \
  ./ctxdb conflicts scan --semantic --project ctxdb --apply
```

---

## 7. Variables de entorno

- `ENGRAM_DATA_DIR`: directorio de datos; debe ser absoluto. Default `~/.engram`.
- `ENGRAM_PROJECT`: override de proyecto a nivel proceso.
- `ENGRAM_PORT`: puerto HTTP para `serve` (default 7437).
- `ENGRAM_AGENT_CLI`: `claude` u `opencode` para scan semántico.
- `COLUMNS` / `LINES`: fallback de tamaño TUI (en Linux se usa ioctl).

---

## 8. Compatibilidad y límites conocidos

- La base SQLite es compatible con el esquema central de Engram; se puede abrir
  una `engram.db` existente.
- No todas las ramas de migración legacy de Go están reproducidas.
- No hay NFC Unicode en nombres de proyecto.
- No hay formateo local de timestamps como Go.
- `mem_update`/`mem_delete` no exigen todavía `expected_project`.
- `mem_save` no implementa `capture_prompt`.
- Consolicación fingerprint interno != fingerprint Go.
- Conflict scan no semántico es FTS/léxico.
- Sync local no implementa mutations/deferred/tombstones/cloud.
- TUI no incluye cloud/setup.
- Obsidian no incluye `--watch` continuo.
- Graphify no interpreta `.odin`; el índice actual tiene cobertura limitada del
  código Odin.

---

## 9. Pendientes reales (fuera del alcance local)

1. Cloud: Postgres, auth, dashboard, cloudserver, cloudstore, autosync.
2. Sync mutations completas: tombstones, deferred relations, cursors, ack.
3. Instaladores `setup` para agentes.
4. Obsidian `--watch` continuo.
5. Pantallas TUI de cloud/setup.
6. Endurecimiento de ownership (`expected_project`) y prompt capture.
7. NFC Unicode en nombres de proyecto.

---

## 10. Cómo continuar

Orden recomendado:

1. Leer `README.md` y `PARITY.md`.
2. Revisar `store/schema.odin` y `store/observations.odin` antes de tocar reglas
   de persistencia.
3. Para cualquier cambio, ejecutar:
   ```sh
   make check
   make test
   ```
4. Mantener la regla de no scripting embebido: Python solo en `scripts/`.
5. Evitar los pitfalls de strings/defer/exact_slice descritos arriba.
6. Actualizar `PARITY.md` y este tipo de resumen al cerrar una fase.
