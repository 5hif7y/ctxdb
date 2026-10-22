# RESUMEN-2 — Skill portable, setup por agente y `setup pi`

Fecha: 2026-10-22
Repositorio: `/home/shifty/AI-DEV/engram-port/ctxdb`
Rama: `main`

Este resumen cubre la fase posterior a `RESUMEN-1`: skill portable,
`ctxdb setup`, `obsidian-export --watch` y, especialmente, el caso real de Pi.

---

## 1. Resultado de esta fase

Se implementó:

1. `skills/ctxdb/SKILL.md`: skill Agent Skills portable.
2. `ctxdb setup`: snippets MCP print-only para la mayoría de agentes.
3. `ctxdb setup --install-skill`: instalación atómica de la skill.
4. `ctxdb setup pi`: excepción práctica para Pi; escribe la skill y el
   `mcp.json` del usuario.
5. `obsidian-export --watch`: export periódico con estado atómico y parada
   limpia.
6. Tests black-box para setup, skill, Pi y watch.

El caso Pi quedó instalado y verificado en esta máquina.

---

## 2. `ctxdb setup pi`

### Qué hace

Sin flags:

```sh
./ctxdb setup pi
```

Escribe:

```text
~/.pi/agent/mcp.json
~/.pi/agent/skills/ctxdb/SKILL.md
```

Si `PI_CODING_AGENT_DIR` está definido y es absoluto, usa ese directorio como
agent dir. Ejemplo:

```sh
PI_CODING_AGENT_DIR=/tmp/pi-agent ./ctxdb setup pi
```

### Entrada MCP que escribe

```json
{
  "mcpServers": {
    "ctxdb": {
      "command": "/ruta/absoluta/a/ctxdb",
      "args": ["mcp"],
      "description": "Persistent project memory: save/search observations, sessions, prompts, conflicts, and context.",
      "exposure": "direct"
    }
  }
}
```

Se eligió `exposure: "direct"` para que el modelo vea los `mem_*` directamente
y la skill pueda invocarlos sin pasar por `codemode` o `tool_search`.

### Garantías

- Preserva otras claves top-level de `mcp.json` (`autoEnableCodemode`, etc.).
- Preserva otros servidores en `mcpServers`.
- Escritura atómica con temporal + `rename`.
- Si el JSON existente es inválido, falla sin sobrescribirlo.
- `--print` muestra el plan y no escribe nada.
- `--force` permite reemplazar una skill con contenido distinto.
- La skill se instala en `<agent-dir>/skills/ctxdb/SKILL.md` por defecto.
- `--skill-dir` permite indicar otro padre de skills.

### Flags

```sh
./ctxdb setup pi --print
./ctxdb setup pi --force
./ctxdb setup pi --skill-dir ~/.agents/skills
```

### Verificación real

Se ejecutó en esta máquina:

```sh
./ctxdb setup pi
pi mcp list --json
```

Resultado:

```json
{
  "name": "ctxdb",
  "state": "connected",
  "exposure": "direct",
  "tools": ["mem_save", "mem_search", "... 27 tools ..."]
}
```

`pi mcp list` reportó `errors: []`.

Para que la sesión activa de Pi cargue el servidor y la skill:

```text
/reload
```

o reiniciar Pi. La skill también se puede forzar con:

```text
/skill:ctxdb
```

Si el binario `ctxdb` se mueve, hay que volver a ejecutar `./ctxdb setup pi`
para actualizar la ruta absoluta de `mcp.json`.

---

## 3. `setup` para otros agentes

Sigue siendo print-only para no reescribir configuración ajena:

```sh
./ctxdb setup                  # lista targets
./ctxdb setup generic          # mcpServers JSON
./ctxdb setup claude-code      # comando claude mcp add
./ctxdb setup opencode         # mcp local JSON/JSONC
./ctxdb setup codex            # bloque TOML
./ctxdb setup vscode-copilot   # servers JSON
```

Targets: `generic`, `claude-code`, `opencode`, `codex`, `gemini-cli`,
`cursor`, `windsurf`, `qwen`, `kiro`, `kilocode`, `kimi`,
`vscode-copilot`, `antigravity-cli`, `pi`.

`--install-skill` instala la skill portable en:

```text
~/.agents/skills/ctxdb/SKILL.md
```

o en el padre indicado con `--skill-dir`.

---

## 4. Skill portable

Archivo: `skills/ctxdb/SKILL.md`.

- Frontmatter Agent Skills con `name: ctxdb`.
- Usa nombres lógicos `mem_*`; no hardcodea `mcp__ctxdb__...`.
- Define guardado proactivo, búsqueda, sesión, compactación y captura pasiva.
- Incluye fallback a CLI.
- Prohíbe guardar secretos y exige no inventar resultados.
- Exige confirmación para consolidación.
- Explica el vocabulario de relaciones.

Instalación manual alternativa:

```sh
mkdir -p ~/.agents/skills/ctxdb
cp skills/ctxdb/SKILL.md ~/.agents/skills/ctxdb/SKILL.md
```

---

## 5. `obsidian-export --watch`

```sh
./ctxdb obsidian-export --vault ~/vault --all --watch
./ctxdb obsidian-export --vault ~/vault --all --watch --interval 10m
```

- Primera exportación inmediata.
- Intervalo por defecto 10m; mínimo 1m.
- Errores no fatales.
- `--graph-config` y `--force` solo en el primer ciclo.
- `SIGINT`/`SIGTERM` con salida limpia en POSIX.
- Estado `.engram-sync-state.json` escrito con temporal + `rename`.
- Un exporter por vault; no hay lock entre procesos.

---

## 6. Archivos principales

```text
skills/ctxdb/SKILL.md          skill portable
setup/setup.odin               snippets, skill install, Pi installer
obsidian/watch.odin            loop de export periódico
obsidian/watch_signal_posix.odin  SIGINT/SIGTERM
obsidian/watch_signal_other.odin  fallback Windows
main.odin                      comandos setup y flags de watch
scripts/smoke.py               tests de setup/skill/Pi/watch
README.md                      uso y diseño
PARITY.md                      paridad actualizada
ESTUDIO-SETUP-WATCH.md         análisis previo a la implementación
```

---

## 7. Verificación

Comandos ejecutados:

```sh
make check
make test
```

`make test` incluye:

- setup print-only;
- instalación de skill y `--force`;
- `setup` no escribe en `$HOME` por defecto;
- `setup pi` escribe `mcp.json` y skill;
- preserva `autoEnableCodemode` y otros servidores;
- `setup pi --print` no escribe;
- watch con primera exportación y `SIGINT`;
- ausencia de `.tmp` residual;
- TUI por PTY.

También se verificó manualmente:

- segundo ciclo de watch;
- `graph.json` preservado en el segundo ciclo;
- `SIGTERM`;
- `pi mcp list --json` con `state: connected` y 27 tools.

---

## 8. Commits de la fase

```text
0a120e2 feat: add portable agent skill, print-only setup, and Obsidian watch
004c164 chore: update graphify index
```

La implementación de `setup pi` y este resumen están en el commit actual
de `main`.

---

## 9. Estado actual y pendientes

Hecho:

- skill portable;
- setup print-only para hosts;
- `setup pi` real con MCP + skill;
- watch de Obsidian;
- tests.

Pendiente / fuera de alcance:

- cloud/Postgres/auth/autosync;
- installers completos para los otros 13 agentes (plugins, hooks, npm,
  marketplaces);
- lock entre procesos para múltiples exporters de Obsidian;
- pantallas TUI de cloud/setup;
- `doctor repair` completo;
- NFC Unicode en nombres de proyecto;
- formato de timestamps locales.

---

## 10. Cómo seguir

1. En una sesión nueva de Pi, ejecutar `/reload` o reiniciar.
2. Verificar `/mcp` o `pi mcp list`.
3. Cargar la skill con `/skill:ctxdb` si no se activa sola.
4. Usar `ctxdb setup pi` otra vez si se mueve el binario.
5. Para cambios: `make check && make test`.
