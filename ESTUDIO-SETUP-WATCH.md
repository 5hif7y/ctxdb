# Estudio: installers `setup` de agentes y `obsidian-export --watch`

Fecha: 2026-10-22
Repositorio: `/home/shifty/AI-DEV/engram-port/ctxdb`
Referencia Go: `/home/shifty/AI-DEV/engram-port/engram`

> **Estado:** implementado. Se agregaron la skill portable, `ctxdb setup`
> (print-only + `--install-skill`) y `obsidian-export --watch`. Además,
> `ctxdb setup pi` es la excepción práctica: instala la skill en el agent dir de
> Pi y registra `ctxdb` en `~/.pi/agent/mcp.json` con exposición directa.

---

## 1. Resumen ejecutivo

La idea de usar `ctxdb` de forma **agnóstica mediante una skill** es la de mayor
valor y menor coste. Recomiendo:

1. **Sí:** crear una skill portable `ctxdb-memory` (`SKILL.md`) que use los
   nombres lógicos `mem_*` y tenga fallback a CLI. Es el punto agnóstico real.
2. **No:** portar los 14 installers de agentes de Engram. Son ~2.9k LOC de
   implementación y ~10.6k con tests; dependen de JSONC, TOML, marketplaces,
   npm, hooks y plugins que `ctxdb` no tiene. El coste y el riesgo superan el
   beneficio.
3. **Sí, pero después:** un `ctxdb setup --print` mínimo que solo imprima el
   snippet MCP y la ruta de la skill. Sin escribir configuración por defecto.
4. **Sí, con condiciones:** `obsidian-export --watch`, porque el export
   incremental ya existe y el watcher de Go son ~100 LOC de polling. Antes hay
   que hacer atómica la escritura del estado y definir el comportamiento ante
   señales/procesos concurrentes.

Prioridad recomendada:

```text
1. Skill portable + documentación       (alto valor / bajo coste)
2. setup --print / setup --install-skill (valor medio / bajo coste)
3. obsidian-export --watch               (valor medio / bajo coste)
4. Installers por agente                 (solo si hay demanda real)
```

Si solo se puede hacer una cosa: **la skill**.

---

## 2. Qué hace el `setup` de Go (evidencia)

El paquete `internal/setup` de Engram contiene:

| Archivo | LOC |
|---|---:|
| `setup.go` | 1.951 |
| `registry.go` | 416 |
| `agents.go` | 369 |
| `opencode_jsonc.go` | 210 |
| Implementación total | ~2.946 |
| Paquete completo con tests | ~10.578 |

Agentes soportados actualmente: `opencode`, `pi`, `claude-code`, `gemini-cli`,
`codex`, `antigravity-cli`, `windsurf`, `qwen`, `kiro`, `cursor`,
`vscode-copilot`, `kilocode`, `commandcode`, `kimi`.

No es solo “escribir un JSON con el comando MCP”. Según el código:

- **OpenCode:** copia un plugin TypeScript embebido, parchea `ENGRAM_BIN`,
  registra MCP en JSONC preservando comentarios/comas/formato, y toca
  `tui.json(c)`.
- **Pi:** ejecuta `pi install npm:gentle-engram@...`, modifica
  `settings.json`, resuelve `mise`/Node y advierte sobre `mcp.json`.
- **Claude Code:** ejecuta el marketplace/plugin de Claude, registra MCP vía
  `claude mcp add`, modifica el allowlist de permisos y verifica el plugin.
- **Codex:** escribe TOML (`config.toml`), instala un plugin de marketplace,
  escribe archivos de instrucciones y un marker para hooks de Windows.
- **Gemini/Antigravity/Windsurf/Qwen/Kiro/Cursor/VS Code/Kilo/CommandCode/Kimi:**
  cada uno tiene su ruta, su formato (`mcpServers`, `servers`, `mcp`), su
  archivo de instrucciones y su estilo (`markerBlock` o `wholeFile`).
- **Windows:** rutas, hooks, Git Bash/PowerShell, pins de ejecutable.
- **Resolución del binario:** Homebrew, mise, rutas absolutas, fallbacks.

Además, el `setup` de Go instala o configura:

- hooks de sesión/compactación;
- plugins que auto-arrancan `engram serve`;
- captura pasiva específica del host;
- binding de `session_id` del host;
- instrucciones de Memory Protocol en archivos de sistema/reglas.

`ctxdb` **no tiene** esas capas de plugin/hooks. Portar solo la escritura de
archivos MCP produciría un `setup` que promete más de lo que el binario hace.

### Conclusión sobre `setup`

Portar los installers completos no es beneficioso ahora:

- alto coste inicial;
- alto coste de mantenimiento (los formatos de los agentes cambian);
- riesgo de corromper configuración del usuario;
- necesidad de tests con `HOME` aislado y fixtures por agente;
- duplica instrucciones que una skill ya puede dar de forma portable;
- varios formatos requieren parsers que Odin stdlib no trae (JSONC y TOML).

Un setup parcial también tiene un problema de expectativas: el usuario cree que
“ya está todo instalado”, pero faltan hooks, sesiones o compactación.

---

## 3. La alternativa agnóstica: skill + MCP

Una skill bajo el estándar Agent Skills es un directorio con `SKILL.md` y
frontmatter. Pi, Claude Code y otros clientes soportan este formato; la ruta más
portable es:

```text
~/.agents/skills/ctxdb/SKILL.md
.proyecto/.agents/skills/ctxdb/SKILL.md
```

La skill puede usar los nombres lógicos de las herramientas:

```text
mem_save, mem_search, mem_context, mem_get_observation,
mem_session_start, mem_session_end, mem_session_summary,
mem_session_finalize, mem_capture_passive, mem_judge, ...
```

No debe hardcodear el prefijo del servidor (`mcp__ctxdb__...`) porque cada host
expone los nombres de forma distinta. El servidor MCP de `ctxdb` ya se llama
`ctxdb` y expone 27 herramientas `mem_*`.

### Qué debe contener la skill

- Cuándo guardar: decisiones, bugfixes, descubrimientos, patrones,
  preferencias, confirmaciones/rechazos del usuario.
- Formato de `mem_save`: título, tipo, scope, `topic_key`, contenido
  What/Why/Where/Learned.
- Regla de upsert por `topic_key`.
- Cuándo buscar: pedidos de recall, primer mensaje del proyecto, trabajo
  potencialmente repetido.
- Cierre de sesión: `mem_session_summary` y, si el host lo permite,
  `mem_session_finalize`.
- Compactación: guardar el resumen antes de continuar.
- Privacidad: no guardar secretos; `<private>` se redacta, pero no abusar.
- Si MCP no está disponible: fallback a CLI (`ctxdb search/context/save`) solo
  si hay shell; no inventar resultados.
- No mostrar bookkeeping de memoria al usuario; la respuesta final va después
  de las operaciones de memoria.

### Por qué esto es realmente agnóstico

La skill es el contrato estable. El MCP es el transporte. El registro MCP es
la única parte específica de cada cliente, y es un snippet pequeño que se puede
copiar una vez. No hace falta un installer por agente para eso.

Riesgo a documentar: si el usuario tiene Engram y ctxdb registrados a la vez,
ambos exponen `mem_save`/`mem_search`. Hay que registrar `ctxdb` con nombre
`ctxdb` y advertir de la ambigüedad; no sobrescribir la entrada `engram`.

---

## 4. Un `setup` mínimo que sí tiene sentido

En vez de 14 installers, un contrato pequeño:

```sh
ctxdb setup                  # lista agentes/snippets
ctxdb setup generic          # imprime JSON/TOML/CLI, no escribe nada
ctxdb setup claude-code      # imprime el snippet y las instrucciones
ctxdb setup --print          # alias explícito, sin side effects
```

Principios:

- **`--print` por defecto:** no tocar `$HOME`.
- **Sin plugins, hooks, npm ni marketplaces.**
- **Sin JSONC/TOML** en la primera versión; solo snippets impresos.
- **Nombre de servidor `ctxdb`**, comando `ctxdb mcp` (no `--tools=agent`).
- **Ruta absoluta del ejecutable** en el snippet cuando sea posible
  (`os.get_executable_path`), para evitar problemas de PATH.
- **`--install-skill [dir]`** opcional: copia únicamente `SKILL.md` a
  `~/.agents/skills/ctxdb/` o al directorio indicado. Es la parte agnóstica.
- Si más adelante se escribe configuración: backup, escritura atómica,
  preservar claves ajenas, idempotencia y `--dry-run`.

Esto da el 80% del beneficio de `setup` con ~10-15% del coste y sin los riesgos
de los installers completos.

---

## 5. `obsidian-export --watch`

### Lo que hace Go

`internal/obsidian/watcher.go` tiene 101 LOC. No usa `fsnotify` ni eventos del
sistema: hace **polling** con un ticker.

Comportamiento:

- primera exportación inmediata;
- siguientes cada `--interval` (default 10m, mínimo 1m);
- errores se loguean y el loop continúa;
- `--graph-config` solo se aplica en el primer ciclo;
- SIGINT/SIGTERM cancelan y salen limpio;
- cada ciclo llama al mismo `Export()` incremental.

Está documentado en `docs/beta/obsidian-brain.md` y presente en
`cmd/engram/main.go`.

### Estado actual de ctxdb

`obsidian.Export` ya es incremental e idempotente:

- lee `.engram-sync-state.json`;
- crea/actualiza/elimina notas;
- regenera session/topic hubs;
- respeta `preserve|force|skip` para `graph.json`.

Falta solo el loop. El coste de portarlo es bajo.

### Riesgos/cuidados antes de implementarlo

1. **Estado no atómico:** `write_state` escribe directo con
   `os.write_entire_file_from_string`. Un corte a mitad puede corromper el
   estado. En watch conviene escribir a un temporal y hacer `os.rename`.
2. **Procesos concurrentes:** dos watchers (o un watcher + un one-shot) pueden
   competir por el estado y las notas. Mínimo: documentar un solo watcher.
   Mejor: lock en `engram/.engram-export.lock` con `{.Create, .Excl}`.
3. **Señales:** en POSIX se puede usar `posix.sigaction` con un flag atómico.
   En Windows haría falta un handler de consola o aceptar Ctrl+C por defecto.
   Si se implementa, hacerlo por plataforma y probarlo.
4. **Scope:** con `--project`, un export con scope no puede retirar notas de
   observaciones hard-deleted o de otros proyectos. Para watch conviene
   recomendar `--all` o documentar la limitación.
5. **Ruido:** loguear solo cambios/errores, no cada ciclo. Go loguea cada ciclo;
   ctxdb puede ser más silencioso.
6. **Hubs:** se regeneran en cada ciclo. Es correcto, pero conviene comparar
   contenido para no reescribir archivos idénticos y no generar churn en
   Obsidian.

### Beneficio

- Vault vivo sin cron/systemd.
- Es la última pieza de paridad Obsidian.
- El modo one-shot + timer ya cubre el caso “actualizar cada X”; watch es
  comodidad, no una capacidad nueva.

### Conclusión sobre watch

**Sí, vale la pena**, después de endurecer el estado. Es una funcionalidad
pequeña, alineada con el diseño actual y fácil de testear. No es urgente.

---

## 6. Matriz de decisión

| Opción | Coste | Beneficio | Riesgo | Recomendación |
|---|---:|---:|---:|---|
| Skill portable `ctxdb-memory` | Bajo | Alto | Bajo | Hacer ahora |
| `setup --print` genérico | Bajo | Medio | Bajo | Hacer ahora/después de la skill |
| `setup --install-skill` | Bajo | Medio | Bajo | Opcional |
| Installers completos 14 agentes | Alto | Medio | Alto | No portar |
| Installers para 2-3 agentes | Medio | Medio | Medio | Solo con demanda y tests |
| `obsidian-export --watch` | Bajo-Medio | Medio | Bajo | Hacer después de atomicidad |

---

## 7. Plan propuesto por fases

### Fase 1 — Skill (sin cambios de binario)

- `skills/ctxdb/SKILL.md` con frontmatter Agent Skills.
- Documentar instalación en `~/.agents/skills/ctxdb/` o `.agents/skills/`.
- Añadir snippet MCP genérico a `README.md`/`PARITY.md`.
- Tests: validación de frontmatter y que la skill no mencione rutas absolutas
  ni prefijos de servidor.

### Fase 2 — `setup` mínimo

- Comando `ctxdb setup [agent]` con `--print` por defecto.
- Snippets para `generic`, `claude-code`, `opencode`, `codex`,
  `gemini-cli`, `cursor`, `vscode-copilot`.
- `--install-skill [dir]` copia solo la skill.
- Sin escritura de configuración de agentes en esta fase.
- Tests con `HOME` temporal y verificación de que `--print` no crea archivos.

### Fase 3 — Watch

- Parsear `--watch` y `--interval` en `run_obsidian_export`.
- Rechazar `--interval` sin `--watch`; default 10m; mínimo 1m.
- Estado atómico (temp + rename).
- Loop con primera exportación inmediata, errores no fatales.
- `graph-config` solo en el primer ciclo.
- Señales POSIX; documentar Windows si no se implementa handler.
- Tests: dos ciclos con cambios, error transitorio, parada limpia.

### Fase 4 — Installers específicos (solo si se justifica)

- Empezar por agentes con JSON simple (`mcpServers`), no JSONC/TOML.
- Nunca instalar plugins/hooks/npm.
- `--dry-run`, backup, escritura atómica, preservar claves.
- No sobrescribir el servidor `engram` de Go.

---

## 8. Veredicto

La intuición del usuario es correcta: **la skill es la capa agnóstica**. Los
installers por agente son la capa cara, frágil y específica; no conviene
portarlos completos. Un `setup --print` + skill cubre el caso de uso real.

`obsidian-export --watch` sí es beneficioso y barato, pero debe hacerse con
estado atómico y control de concurrencia. No es un requisito para usar ctxdb de
forma agnóstica.

Orden recomendado:

```text
skill → setup --print → watch → installers específicos (si hay demanda)
```
