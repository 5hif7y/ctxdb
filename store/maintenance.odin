// Local maintenance operations: destructive deletes and project curation.
package store

import "core:strings"

import "../sqlite"
import "../util"

Delete_Project_Result :: struct {
	project:               string `json:"project"`,
	hard_delete:           bool   `json:"hard_delete"`,
	observations_deleted:  int    `json:"observations_deleted"`,
	prompts_deleted:       int    `json:"prompts_deleted"`,
	sessions_deleted:      int    `json:"sessions_deleted"`,
}

Merge_Result :: struct {
	canonical:            string   `json:"canonical"`,
	sources:              []string `json:"sources"`,
	observations_updated: int      `json:"observations_updated"`,
	sessions_updated:     int      `json:"sessions_updated"`,
	prompts_updated:      int      `json:"prompts_updated"`,
}

Prune_Result :: struct {
	project:          string `json:"project"`,
	prompts_deleted:  int    `json:"prompts_deleted"`,
	sessions_deleted: int    `json:"sessions_deleted"`,
}

DeleteSession :: proc(s: ^STORE, id: string) -> string {
	if err := validate_session_id(id); err != "" {
		return err
	}
	if err := sqlite.exec(s.db, "BEGIN IMMEDIATE"); err != "" {
		return err
	}
	stmt, err := sqlite.prepare(s.db, "SELECT ifnull(project,'') FROM sessions WHERE id = ?")
	if err != "" {
		_ = sqlite.exec(s.db, "ROLLBACK")
		return err
	}
	_ = sqlite.bind_text(&stmt, 1, id)
	has, serr := sqlite.step(&stmt)
	sqlite.finalize(&stmt)
	if serr != "" {
		_ = sqlite.exec(s.db, "ROLLBACK")
		return serr
	}
	if !has {
		_ = sqlite.exec(s.db, "ROLLBACK")
		return cat("session not found: ", id)
	}
	count, cerr := count_where(s, "observations", "session_id = ?", id)
	if cerr != "" {
		_ = sqlite.exec(s.db, "ROLLBACK")
		return cerr
	}
	if count > 0 {
		_ = sqlite.exec(s.db, "ROLLBACK")
		return "session has observations; delete or consolidate them first"
	}
	if prompt_err := exec_param(s.db, "DELETE FROM user_prompts WHERE session_id = ?", id); prompt_err != "" {
		_ = sqlite.exec(s.db, "ROLLBACK")
		return prompt_err
	}
	if del_err := exec_param(s.db, "DELETE FROM sessions WHERE id = ?", id); del_err != "" {
		_ = sqlite.exec(s.db, "ROLLBACK")
		return del_err
	}
	if commit_err := sqlite.exec(s.db, "COMMIT"); commit_err != "" {
		_ = sqlite.exec(s.db, "ROLLBACK")
		return commit_err
	}
	return ""
}

DeletePrompt :: proc(s: ^STORE, id: i64) -> string {
	if err := sqlite.exec(s.db, "BEGIN IMMEDIATE"); err != "" {
		return err
	}
	stmt, err := sqlite.prepare(s.db, "SELECT ifnull(sync_id,''), session_id, ifnull(project,''), ifnull(source_inbox_id,'') FROM user_prompts WHERE id = ?")
	if err != "" {
		_ = sqlite.exec(s.db, "ROLLBACK")
		return err
	}
	_ = sqlite.bind_int(&stmt, 1, id)
	has, serr := sqlite.step(&stmt)
	if serr != "" || !has {
		sqlite.finalize(&stmt)
		_ = sqlite.exec(s.db, "ROLLBACK")
		return "prompt not found"
	}
	sync_id := sqlite.column_text(&stmt, 0)
	session_id := sqlite.column_text(&stmt, 1)
	project_name := sqlite.column_text(&stmt, 2)
	inbox := sqlite.column_text(&stmt, 3)
	sqlite.finalize(&stmt)
	if project_name == "" {
		project_name, _ = session_project(s, session_id)
	}
	project_name, _ = util.NormalizeProject(project_name)
	tomb, terr := sqlite.prepare(s.db, `
		INSERT OR REPLACE INTO prompt_tombstones (sync_id, session_id, project, source_inbox_id, deleted_at)
		VALUES (?, ?, ?, ?, datetime('now'))`)
	if terr != "" {
		_ = sqlite.exec(s.db, "ROLLBACK")
		return terr
	}
	_ = sqlite.bind_text(&tomb, 1, sync_id)
	_ = bind_nullable(&tomb, 2, session_id)
	_ = bind_nullable(&tomb, 3, project_name)
	_ = bind_nullable(&tomb, 4, inbox)
	_, tde := sqlite.step(&tomb)
	sqlite.finalize(&tomb)
	if tde != "" {
		_ = sqlite.exec(s.db, "ROLLBACK")
		return tde
	}
	if del_err := exec_int(s.db, "DELETE FROM user_prompts WHERE id = ?", id); del_err != "" {
		_ = sqlite.exec(s.db, "ROLLBACK")
		return del_err
	}
	if commit_err := sqlite.exec(s.db, "COMMIT"); commit_err != "" {
		_ = sqlite.exec(s.db, "ROLLBACK")
		return commit_err
	}
	return ""
}

DeleteProject :: proc(s: ^STORE, project_arg: string, hard: bool) -> (Delete_Project_Result, string) {
	project_name, _ := util.NormalizeProject(project_arg)
	result := Delete_Project_Result{project = project_name, hard_delete = hard}
	if project_name == "" {
		return result, "project name must not be empty"
	}
	if err := sqlite.exec(s.db, "BEGIN IMMEDIATE"); err != "" {
		return result, err
	}
	sessions, _ := count_where(s, "sessions", "project = ?", project_name)
	observations, _ := count_where(s, "observations", "project = ?", project_name)
	if sessions == 0 && observations == 0 {
		_ = sqlite.exec(s.db, "ROLLBACK")
		return result, "project not found"
	}
	if hard {
		result.observations_deleted = exec_changes(s.db, "DELETE FROM observations WHERE project = ?", project_name)
	} else {
		result.observations_deleted = exec_changes(s.db, `
			UPDATE observations SET deleted_at = datetime('now'), updated_at = datetime('now')
			WHERE project = ? AND deleted_at IS NULL`, project_name)
	}
	result.prompts_deleted = exec_changes(s.db, "DELETE FROM user_prompts WHERE project = ?", project_name)
	if hard {
		result.sessions_deleted = exec_changes(s.db, `
			DELETE FROM sessions WHERE project = ?
			  AND NOT EXISTS (SELECT 1 FROM observations WHERE observations.session_id = sessions.id)
			  AND NOT EXISTS (SELECT 1 FROM user_prompts WHERE user_prompts.session_id = sessions.id)`, project_name)
	}
	if err := sqlite.exec(s.db, "COMMIT"); err != "" {
		_ = sqlite.exec(s.db, "ROLLBACK")
		return result, err
	}
	return result, ""
}

MergeProjects :: proc(s: ^STORE, sources: []string, canonical_arg: string) -> (Merge_Result, string) {
	canonical, _ := util.NormalizeProject(canonical_arg)
	result := Merge_Result{canonical = canonical}
	source_names := make([dynamic]string)
	if canonical == "" {
		return result, "canonical project is required"
	}
	if err := sqlite.exec(s.db, "BEGIN IMMEDIATE"); err != "" {
		return result, err
	}
	for src in sources {
		source := strings.trim_space(src)
		if source == "" {
			continue
		}
		normalized, _ := util.NormalizeProject(source)
		if normalized == canonical && source == canonical {
			continue
		}
		append(&source_names, source)
		result.observations_updated += exec_changes_pair(s.db, "UPDATE observations SET project = ? WHERE LOWER(project) = ?", canonical, normalized)
		result.sessions_updated += exec_changes_pair(s.db, "UPDATE sessions SET project = ? WHERE LOWER(project) = ?", canonical, normalized)
		result.prompts_updated += exec_changes_pair(s.db, "UPDATE user_prompts SET project = ? WHERE LOWER(project) = ?", canonical, normalized)
	}
	if err := sqlite.exec(s.db, "COMMIT"); err != "" {
		_ = sqlite.exec(s.db, "ROLLBACK")
		delete(source_names)
		return result, err
	}
	result.sources = exact_slice(source_names)
	return result, ""
}

PruneProject :: proc(s: ^STORE, project_arg: string) -> (Prune_Result, string) {
	project_name, _ := util.NormalizeProject(project_arg)
	result := Prune_Result{project = project_name}
	if project_name == "" {
		return result, "project name must not be empty"
	}
	observations, _ := count_where(s, "observations", "LOWER(project) = ?", project_name)
	if observations > 0 {
		return result, "project still has observations — cannot prune"
	}
	if err := sqlite.exec(s.db, "BEGIN IMMEDIATE"); err != "" {
		return result, err
	}
	result.prompts_deleted = exec_changes(s.db, "DELETE FROM user_prompts WHERE LOWER(project) = ?", project_name)
	result.sessions_deleted = exec_changes(s.db, "DELETE FROM sessions WHERE LOWER(project) = ?", project_name)
	if err := sqlite.exec(s.db, "COMMIT"); err != "" {
		_ = sqlite.exec(s.db, "ROLLBACK")
		return result, err
	}
	return result, ""
}

// ─── Small SQL helpers ──────────────────────────────────────────────────────

count_where :: proc(s: ^STORE, table, filter: string, value: string) -> (int, string) {
	sql := cat("SELECT COUNT(*) FROM ", table, " WHERE ", filter)
	stmt, err := sqlite.prepare(s.db, sql)
	if err != "" {
		return 0, err
	}
	defer sqlite.finalize(&stmt)
	_ = sqlite.bind_text(&stmt, 1, value)
	has, serr := sqlite.step(&stmt)
	if serr != "" || !has {
		return 0, serr
	}
	return int(sqlite.column_int(&stmt, 0)), ""
}

exec_param :: proc(db: ^sqlite.DB, sql, value: string) -> string {
	stmt, err := sqlite.prepare(db, sql)
	if err != "" {
		return err
	}
	defer sqlite.finalize(&stmt)
	_ = sqlite.bind_text(&stmt, 1, value)
	_, serr := sqlite.step(&stmt)
	return serr
}

exec_int :: proc(db: ^sqlite.DB, sql: string, value: i64) -> string {
	stmt, err := sqlite.prepare(db, sql)
	if err != "" {
		return err
	}
	defer sqlite.finalize(&stmt)
	_ = sqlite.bind_int(&stmt, 1, value)
	_, serr := sqlite.step(&stmt)
	return serr
}

exec_changes :: proc(db: ^sqlite.DB, sql, value: string) -> int {
	stmt, err := sqlite.prepare(db, sql)
	if err != "" {
		return 0
	}
	defer sqlite.finalize(&stmt)
	_ = sqlite.bind_text(&stmt, 1, value)
	_, serr := sqlite.step(&stmt)
	if serr != "" {
		return 0
	}
	return sqlite.changes(db)
}

exec_changes_pair :: proc(db: ^sqlite.DB, sql, a, b: string) -> int {
	stmt, err := sqlite.prepare(db, sql)
	if err != "" {
		return 0
	}
	defer sqlite.finalize(&stmt)
	_ = sqlite.bind_text(&stmt, 1, a)
	_ = sqlite.bind_text(&stmt, 2, b)
	_, serr := sqlite.step(&stmt)
	if serr != "" {
		return 0
	}
	return sqlite.changes(db)
}

PreviewMergeProjects :: proc(s: ^STORE, sources: []string, canonical: string) -> (Merge_Result, string) {
	canonical_name, _ := util.NormalizeProject(canonical)
	result := Merge_Result{canonical = canonical_name}
	source_names := make([dynamic]string)
	for src in sources {
		source := strings.trim_space(src)
		if source == "" {
			continue
		}
		normalized, _ := util.NormalizeProject(source)
		append(&source_names, source)
		obs, _ := count_where(s, "observations", "LOWER(project) = ?", normalized)
		sess, _ := count_where(s, "sessions", "LOWER(project) = ?", normalized)
		prompts, _ := count_where(s, "user_prompts", "LOWER(project) = ?", normalized)
		result.observations_updated += obs
		result.sessions_updated += sess
		result.prompts_updated += prompts
	}
	result.sources = exact_slice(source_names)
	return result, ""
}

// ─── Sync chunk bookkeeping (local target) ──────────────────────────────────
SYNC_LOCAL_TARGET :: "local"

GetSyncedChunks :: proc(s: ^STORE, target_key: string) -> (map[string]bool, string) {
	out := make(map[string]bool)
	stmt, err := sqlite.prepare(s.db, "SELECT chunk_id FROM sync_chunks WHERE target_key = ?")
	if err != "" {
		return out, err
	}
	defer sqlite.finalize(&stmt)
	_ = sqlite.bind_text(&stmt, 1, target_key)
	for {
		has, serr := sqlite.step(&stmt)
		if serr != "" {
			return out, serr
		}
		if !has {
			break
		}
		out[sqlite.column_text(&stmt, 0)] = true
	}
	return out, ""
}

RecordSyncedChunk :: proc(s: ^STORE, target_key, chunk_id: string) -> string {
	stmt, err := sqlite.prepare(s.db, `
		INSERT OR IGNORE INTO sync_chunks (target_key, chunk_id) VALUES (?, ?)`)
	if err != "" {
		return err
	}
	defer sqlite.finalize(&stmt)
	_ = sqlite.bind_text(&stmt, 1, target_key)
	_ = sqlite.bind_text(&stmt, 2, chunk_id)
	_, serr := sqlite.step(&stmt)
	return serr
}
