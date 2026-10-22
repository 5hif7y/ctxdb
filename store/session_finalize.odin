// Atomic session finalization: summary observation + terminal session + journal.
package store

import "core:strings"

import "../sqlite"
import "../util"

Finalize_Session_Params :: struct {
	session_id: string,
	project:    string,
	summary:    string,
}

Finalize_Session_Result :: struct {
	summary_id:        i64    `json:"summary_id"`,
	summary_sync_id:   string `json:"summary_sync_id"`,
	already_finalized: bool   `json:"already_finalized"`,
}

FinalizeSession :: proc(s: ^STORE, p: Finalize_Session_Params) -> (Finalize_Session_Result, string) {
	if err := validate_session_id(p.session_id); err != "" {
		return {}, err
	}
	project_name, _ := util.NormalizeProject(p.project)
	if project_name == "" {
		return {}, ERR_PROJECT_REQUIRED
	}
	summary, _ := util.TruncateContent(util.StripPrivateTags(p.summary), s.cfg.max_observation_length)
	if strings.trim_space(summary) == "" {
		return {}, ERR_CONTENT_REQUIRED
	}

	if err := sqlite.exec(s.db, "BEGIN IMMEDIATE"); err != "" {
		return {}, err
	}

	stmt, err := sqlite.prepare(s.db, "SELECT ifnull(project,''), ifnull(ended_at,''), ifnull(summary,'') FROM sessions WHERE id = ?")
	if err != "" {
		_ = sqlite.exec(s.db, "ROLLBACK")
		return {}, err
	}
	_ = sqlite.bind_text(&stmt, 1, p.session_id)
	has, serr := sqlite.step(&stmt)
	if serr != "" {
		sqlite.finalize(&stmt)
		_ = sqlite.exec(s.db, "ROLLBACK")
		return {}, serr
	}
	if !has {
		sqlite.finalize(&stmt)
		_ = sqlite.exec(s.db, "ROLLBACK")
		return {}, ERR_SESSION_NOT_FOUND
	}
	owner := sqlite.column_text(&stmt, 0)
	ended := sqlite.column_text(&stmt, 1)
	prior_summary := sqlite.column_text(&stmt, 2)
	sqlite.finalize(&stmt)
	owner, _ = util.NormalizeProject(owner)
	if owner != project_name {
		_ = sqlite.exec(s.db, "ROLLBACK")
		return {}, "session ownership mismatch"
	}

	// Already finalized: preserve the original summary identity on retries.
	stmt, err = sqlite.prepare(s.db, "SELECT summary_id, summary_sync_id FROM session_finalizations WHERE session_id = ?")
	if err == "" {
		_ = sqlite.bind_text(&stmt, 1, p.session_id)
		has_fin, ferr := sqlite.step(&stmt)
		if ferr == "" && has_fin {
			result := Finalize_Session_Result{
				summary_id = sqlite.column_int(&stmt, 0),
				summary_sync_id = sqlite.column_text(&stmt, 1),
				already_finalized = true,
			}
			sqlite.finalize(&stmt)
			_ = sqlite.exec(s.db, "COMMIT")
			return result, ""
		}
		sqlite.finalize(&stmt)
	}
	if ended != "" {
		_ = sqlite.exec(s.db, "ROLLBACK")
		return {}, "session already ended"
	}

	sync_id := util.NewSyncID("obs")
	title := cat("Session summary: ", project_name)
	ins, ierr := sqlite.prepare(s.db, `
		INSERT INTO observations
			(sync_id, session_id, type, title, content, tool_name, project, scope,
			 normalized_hash, revision_count, duplicate_count, last_seen_at, updated_at)
		VALUES (?, ?, 'session_summary', ?, ?, NULL, ?, 'project', ?, 1, 1, datetime('now'), datetime('now'))`)
	if ierr != "" {
		_ = sqlite.exec(s.db, "ROLLBACK")
		return {}, ierr
	}
	_ = sqlite.bind_text(&ins, 1, sync_id)
	_ = sqlite.bind_text(&ins, 2, p.session_id)
	_ = sqlite.bind_text(&ins, 3, title)
	_ = sqlite.bind_text(&ins, 4, summary)
	_ = bind_nullable(&ins, 5, project_name)
	_ = sqlite.bind_text(&ins, 6, util.HashNormalized(summary))
	_, step_err := sqlite.step(&ins)
	sqlite.finalize(&ins)
	if step_err != "" {
		_ = sqlite.exec(s.db, "ROLLBACK")
		return {}, step_err
	}
	summary_id := sqlite.last_insert_rowid(s.db)

	end_stmt, eerr := sqlite.prepare(s.db, "UPDATE sessions SET ended_at = datetime('now'), summary = ? WHERE id = ?")
	if eerr != "" {
		_ = sqlite.exec(s.db, "ROLLBACK")
		return {}, eerr
	}
	_ = bind_nullable(&end_stmt, 1, prior_summary)
	_ = sqlite.bind_text(&end_stmt, 2, p.session_id)
	_, end_err := sqlite.step(&end_stmt)
	sqlite.finalize(&end_stmt)
	if end_err != "" {
		_ = sqlite.exec(s.db, "ROLLBACK")
		return {}, end_err
	}

	fin_stmt, ferr := sqlite.prepare(s.db, "INSERT INTO session_finalizations (session_id, summary_id, summary_sync_id) VALUES (?, ?, ?)")
	if ferr != "" {
		_ = sqlite.exec(s.db, "ROLLBACK")
		return {}, ferr
	}
	_ = sqlite.bind_text(&fin_stmt, 1, p.session_id)
	_ = sqlite.bind_int(&fin_stmt, 2, summary_id)
	_ = sqlite.bind_text(&fin_stmt, 3, sync_id)
	_, fin_err := sqlite.step(&fin_stmt)
	sqlite.finalize(&fin_stmt)
	if fin_err != "" {
		_ = sqlite.exec(s.db, "ROLLBACK")
		return {}, fin_err
	}

	if commit_err := sqlite.exec(s.db, "COMMIT"); commit_err != "" {
		_ = sqlite.exec(s.db, "ROLLBACK")
		return {}, commit_err
	}
	return Finalize_Session_Result{summary_id = summary_id, summary_sync_id = sync_id}, ""
}
