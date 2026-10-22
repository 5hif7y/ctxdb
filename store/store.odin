package store

import "core:os"
import "core:path/filepath"
import "core:strings"

import "../sqlite"
import "../project"

cat :: proc(parts: ..string) -> string {
	return strings.concatenate(parts)
}

// exact_slice copies a dynamic array into an exactly-sized slice and releases
// the original buffer. Callers can then use delete(slice) safely.
exact_slice :: proc(arr: [dynamic]$T) -> []T {
	out := make([]T, len(arr))
	copy(out, arr[:])
	delete(arr)
	return out
}

DATA_DIR_ENV :: "ENGRAM_DATA_DIR"
DB_FILENAME :: "engram.db"

DefaultConfig :: proc() -> (Config, string) {
	data_dir := ""
	if raw := os.get_env_alloc(DATA_DIR_ENV, context.allocator); strings.trim_space(raw) != "" {
		dir := strings.trim_space(raw)
		if !filepath.is_abs(dir) {
			return {}, "engram: ENGRAM_DATA_DIR must be an absolute path"
		}
		data_dir = dir
	} else {
		home, err := os.user_home_dir(context.allocator)
		if err != nil {
			return {}, "engram: determine home directory"
		}
		defer delete(home)
		data_dir, _ = filepath.join({home, ".engram"})
	}
	return Config{
		data_dir = data_dir,
		max_observation_length = DEFAULT_MAX_OBSERVATION_LENGTH,
		max_context_results = DEFAULT_MAX_CONTEXT_RESULTS,
		max_search_results = DEFAULT_MAX_SEARCH_RESULTS,
		dedupe_window_minutes = DEFAULT_DEDUPE_WINDOW_MINUTES,
	}, ""
}

FallbackConfig :: proc(data_dir: string) -> Config {
	return Config{
		data_dir = data_dir,
		max_observation_length = DEFAULT_MAX_OBSERVATION_LENGTH,
		max_context_results = DEFAULT_MAX_CONTEXT_RESULTS,
		max_search_results = DEFAULT_MAX_SEARCH_RESULTS,
		dedupe_window_minutes = DEFAULT_DEDUPE_WINDOW_MINUTES,
	}
}

Open :: proc(cfg: Config) -> (^STORE, string) {
	if cfg.data_dir == "" {
		return nil, "engram: data directory is required"
	}
	if !filepath.is_abs(cfg.data_dir) {
		return nil, "engram: data directory must be absolute"
	}
	if _, stat_err := os.stat(cfg.data_dir, context.allocator); stat_err != nil {
		if err := os.make_directory_all(cfg.data_dir); err != nil {
			return nil, cat("engram: create data dir: ", os.error_string(err))
		}
	}
	db_path, _ := filepath.join({cfg.data_dir, DB_FILENAME})

	db := new(sqlite.DB)
	opened, err := sqlite.open(db_path)
	if err != "" {
		free(db)
		return nil, err
	}
	db^ = opened

	s := new(STORE)
	s.db = db
	s.cfg = cfg
	s.path = strings.clone(db_path)

	// Pragmas are safe on existing stores and are required for concurrent
	// CLI/MCP/server access. SQLite returns a row for journal_mode.
	_ = sqlite.exec(db, "PRAGMA journal_mode=WAL")
	_ = sqlite.exec(db, "PRAGMA busy_timeout=5000")
	_ = sqlite.exec(db, "PRAGMA foreign_keys=ON")
	_ = sqlite.exec(db, "PRAGMA synchronous=NORMAL")

	if merr := migrate(s); merr != "" {
		Close(s)
		return nil, merr
	}
	return s, ""
}

Close :: proc(s: ^STORE) {
	if s == nil {
		return
	}
	if s.db != nil {
		sqlite.close(s.db)
		free(s.db)
	}
	if s.path != "" {
		delete(s.path)
	}
	free(s)
}

SQLiteVersion :: proc() -> string {
	return sqlite.libversion()
}

DataDir :: proc(s: ^STORE) -> string {
	return s.cfg.data_dir
}

DBPath :: proc(s: ^STORE) -> string {
	return s.path
}

now :: proc(s: ^STORE) -> string {
	return Now(s.db)
}

// session_project resolves the project of an existing session. Writes with a
// blank project inherit the session owner in Engram.
session_project :: proc(s: ^STORE, session_id: string) -> (string, string) {
	if session_id == "" {
		return "", ""
	}
	stmt, err := sqlite.prepare(s.db, "SELECT ifnull(project,'') FROM sessions WHERE id = ?")
	if err != "" {
		return "", err
	}
	defer sqlite.finalize(&stmt)
	if berr := sqlite.bind_text(&stmt, 1, session_id); berr != "" {
		return "", berr
	}
	has_row, serr := sqlite.step(&stmt)
	if serr != "" {
		return "", serr
	}
	if !has_row {
		return "", ""
	}
	return sqlite.column_text(&stmt, 0), ""
}

// resolve_write_project mirrors the store rule: an explicit observation
// project wins; otherwise the session's project is inherited.
resolve_write_project :: proc(s: ^STORE, session_id, project_name: string) -> (string, string) {
	if strings.trim_space(project_name) != "" {
		return project_name, ""
	}
	return session_project(s, session_id)
}

// project_exists checks observations, sessions, prompts, and enrollment.
ProjectExists :: proc(s: ^STORE, name: string) -> (bool, string) {
	query := `
SELECT 1 FROM (
  SELECT project FROM observations WHERE LOWER(project) = ? AND deleted_at IS NULL
  UNION ALL
  SELECT project FROM sessions WHERE LOWER(project) = ?
  UNION ALL
  SELECT project FROM user_prompts WHERE LOWER(project) = ?
  UNION ALL
  SELECT project FROM sync_enrolled_projects WHERE LOWER(project) = ?
) LIMIT 1`
	stmt, err := sqlite.prepare(s.db, query)
	if err != "" {
		return false, err
	}
	defer sqlite.finalize(&stmt)
	for i in 1 ..= 4 {
		if berr := sqlite.bind_text(&stmt, i, name); berr != "" {
			return false, berr
		}
	}
	has_row, serr := sqlite.step(&stmt)
	if serr != "" {
		return false, serr
	}
	return has_row, ""
}

// ResolveCurrentProject applies the CLI/MCP read/write resolver.
ResolveCurrentProject :: proc(s: ^STORE, explicit: string, directory: string) -> (string, string) {
	result, err := project.Resolve(explicit, directory)
	if err != "" {
		return "", err
	}
	if result.project == "" {
		return "", ERR_PROJECT_REQUIRED
	}
	return result.project, ""
}
