package store

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:path/filepath"
import "core:strings"

import "../sqlite"
import "../util"

SESSION_OWNERSHIP_SHARED :: "shared"
SESSION_OWNERSHIP_PROJECT_OWNED :: "project_owned"
MANUAL_SESSION_PREFIX :: "manual-save-"

valid_session_ownership :: proc(mode: string) -> bool {
	return mode == SESSION_OWNERSHIP_SHARED || mode == SESSION_OWNERSHIP_PROJECT_OWNED
}

validate_session_id :: proc(id: string) -> string {
	if strings.trim_space(id) == "" {
		return "session id is required"
	}
	if len(id) > 512 {
		return "session id is too long"
	}
	return ""
}

// CreateSession registers a session idempotently. Existing identity, project,
// and directory are preserved unless they are blank.
CreateSession :: proc(s: ^STORE, id, project_arg, directory, mode: string) -> string {
	if err := validate_session_id(id); err != "" {
		return err
	}
	if !valid_session_ownership(mode) {
		return cat("invalid session ownership mode: ", mode)
	}
	project_name, _ := util.NormalizeProject(project_arg)
	if strings.trim_space(project_name) == "" {
		return ERR_PROJECT_REQUIRED
	}
	existing, _, found := session_ownership(s, id)
	if found {
		if mode == SESSION_OWNERSHIP_PROJECT_OWNED && existing != "" && existing != project_name {
			return cat("session project mismatch: session belongs to ", existing, ", not ", project_name)
		}
	}
	stmt, err := sqlite.prepare(s.db, `
		INSERT INTO sessions (id, project, ownership_mode, directory, started_at, local_creation_project)
		VALUES (?, ?, ?, ?, datetime('now'), ?)
		ON CONFLICT(id) DO UPDATE SET
		  project = CASE WHEN ifnull(trim(sessions.project), '') = '' THEN excluded.project ELSE sessions.project END,
		  ownership_mode = CASE WHEN ifnull(trim(sessions.ownership_mode), '') = '' THEN excluded.ownership_mode ELSE sessions.ownership_mode END,
		  directory = CASE WHEN trim(sessions.directory) = '' THEN excluded.directory ELSE sessions.directory END`)
	if err != "" {
		return err
	}
	defer sqlite.finalize(&stmt)
	_ = sqlite.bind_text(&stmt, 1, id)
	_ = sqlite.bind_text(&stmt, 2, project_name)
	_ = sqlite.bind_text(&stmt, 3, mode)
	_ = sqlite.bind_text(&stmt, 4, directory)
	_ = sqlite.bind_text(&stmt, 5, project_name)
	if _, serr := sqlite.step(&stmt); serr != "" {
		return serr
	}
	return ""
}

session_ownership :: proc(s: ^STORE, id: string) -> (project_name: string, mode: string, found: bool) {
	stmt, err := sqlite.prepare(s.db, "SELECT ifnull(project,''), ifnull(ownership_mode,'') FROM sessions WHERE id = ?")
	if err != "" {
		return "", "", false
	}
	defer sqlite.finalize(&stmt)
	_ = sqlite.bind_text(&stmt, 1, id)
	has_row, serr := sqlite.step(&stmt)
	if serr != "" || !has_row {
		return "", "", false
	}
	return sqlite.column_text(&stmt, 0), sqlite.column_text(&stmt, 1), true
}

fallback_session_id :: proc(project_name: string) -> string {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, transmute([]u8)project_name)
	digest: [32]u8
	sha2.final(&ctx, digest[:])
	encoded, _ := hex.encode(digest[:])
	return cat("manual-fallback-", string(encoded))
}

// ResolveManualSession returns the deterministic manual-save session for a
// project. A project-owned identity conflict falls back to a hash namespace.
ResolveManualSession :: proc(s: ^STORE, project_arg, directory: string) -> (string, string) {
	project_name, _ := util.NormalizeProject(project_arg)
	id := cat(MANUAL_SESSION_PREFIX, project_name)
	err := CreateSession(s, id, project_name, directory, SESSION_OWNERSHIP_PROJECT_OWNED)
	if err == "" {
		return id, ""
	}
	id = fallback_session_id(project_name)
	if ferr := CreateSession(s, id, project_name, directory, SESSION_OWNERSHIP_PROJECT_OWNED); ferr != "" {
		return "", ferr
	}
	return id, ""
}

// StartSession registers a runtime session or renews its local lease. Ended
// sessions are terminal.
StartSession :: proc(s: ^STORE, id, project_arg, directory, mode: string) -> string {
	if err := validate_session_id(id); err != "" {
		return err
	}
	if !valid_session_ownership(mode) {
		return cat("invalid session ownership mode: ", mode)
	}
	project_name, _ := util.NormalizeProject(project_arg)
	if strings.trim_space(project_name) == "" {
		return ERR_PROJECT_REQUIRED
	}
	stmt, err := sqlite.prepare(s.db, `
		INSERT INTO sessions (id, project, ownership_mode, directory, started_at, runtime_lease_expires_at, local_creation_project)
		VALUES (?, ?, ?, ?, datetime('now'), datetime('now', '+30 minutes'), ?)
		ON CONFLICT(id) DO UPDATE SET
		  project = CASE WHEN ifnull(trim(sessions.project), '') = '' THEN excluded.project ELSE sessions.project END,
		  ownership_mode = CASE WHEN ifnull(trim(sessions.ownership_mode), '') = '' THEN excluded.ownership_mode ELSE sessions.ownership_mode END,
		  directory = CASE WHEN trim(sessions.directory) = '' THEN excluded.directory ELSE sessions.directory END,
		  runtime_lease_expires_at = excluded.runtime_lease_expires_at
		WHERE sessions.ended_at IS NULL`)
	if err != "" {
		return err
	}
	defer sqlite.finalize(&stmt)
	_ = sqlite.bind_text(&stmt, 1, id)
	_ = sqlite.bind_text(&stmt, 2, project_name)
	_ = sqlite.bind_text(&stmt, 3, mode)
	_ = sqlite.bind_text(&stmt, 4, directory)
	_ = sqlite.bind_text(&stmt, 5, project_name)
	if _, serr := sqlite.step(&stmt); serr != "" {
		return serr
	}
	if sqlite.changes(s.db) == 0 {
		return "session already ended"
	}
	return ""
}

EndSession :: proc(s: ^STORE, id, summary: string) -> string {
	if err := validate_session_id(id); err != "" {
		return err
	}
	stmt, err := sqlite.prepare(s.db, "UPDATE sessions SET ended_at = datetime('now'), summary = ? WHERE id = ?")
	if err != "" {
		return err
	}
	defer sqlite.finalize(&stmt)
	_ = bind_nullable(&stmt, 1, summary)
	_ = sqlite.bind_text(&stmt, 2, id)
	if _, serr := sqlite.step(&stmt); serr != "" {
		return serr
	}
	return ""
}

GetSession :: proc(s: ^STORE, id: string) -> (Session, string) {
	stmt, err := sqlite.prepare(s.db, `
		SELECT id, ifnull(project,''), ifnull(ownership_mode,''), directory,
		       started_at, ifnull(ended_at,''), ifnull(summary,''), ifnull(runtime_lease_expires_at,'')
		FROM sessions WHERE id = ?`)
	if err != "" {
		return {}, err
	}
	defer sqlite.finalize(&stmt)
	_ = sqlite.bind_text(&stmt, 1, id)
	has_row, serr := sqlite.step(&stmt)
	if serr != "" {
		return {}, serr
	}
	if !has_row {
		return {}, ERR_SESSION_NOT_FOUND
	}
	sess: Session
	sess.id = sqlite.column_text(&stmt, 0)
	sess.project = sqlite.column_text(&stmt, 1)
	sess.ownership_mode = sqlite.column_text(&stmt, 2)
	sess.directory = sqlite.column_text(&stmt, 3)
	sess.started_at = sqlite.column_text(&stmt, 4)
	sess.ended_at = sqlite.column_text(&stmt, 5)
	sess.summary = sqlite.column_text(&stmt, 6)
	sess.runtime_lease_expires = sqlite.column_text(&stmt, 7)
	return sess, ""
}

RecentSessions :: proc(s: ^STORE, project_arg: string, limit_arg: int) -> ([]SessionSummary, string) {
	project_name, _ := util.NormalizeProject(project_arg)
	limit := limit_arg
	if limit <= 0 {
		limit = 5
	}
	sql := `
		SELECT s.id, ifnull(s.project,''), s.started_at, ifnull(s.ended_at,''), ifnull(s.summary,''),
		       COUNT(o.id) as observation_count
		FROM sessions s
		LEFT JOIN observations o ON o.session_id = s.id AND o.deleted_at IS NULL
		WHERE 1=1`
	if project_name != "" {
		sql = cat(sql, " AND LOWER(s.project) = ?")
	}
	sql = cat(sql, " GROUP BY s.id ORDER BY MAX(datetime(COALESCE(o.created_at, s.started_at))) DESC, s.id DESC LIMIT ?")
	stmt, err := sqlite.prepare(s.db, sql)
	if err != "" {
		return nil, err
	}
	defer sqlite.finalize(&stmt)
	idx := 1
	if project_name != "" {
		_ = sqlite.bind_text(&stmt, idx, project_name)
		idx += 1
	}
	_ = sqlite.bind_int(&stmt, idx, i64(limit))
	out := make([dynamic]SessionSummary)
	for {
		has_row, serr := sqlite.step(&stmt)
		if serr != "" {
			delete(out)
			return nil, serr
		}
		if !has_row {
			break
		}
		ss: SessionSummary
		ss.id = sqlite.column_text(&stmt, 0)
		ss.project = sqlite.column_text(&stmt, 1)
		ss.started_at = sqlite.column_text(&stmt, 2)
		ss.ended_at = sqlite.column_text(&stmt, 3)
		ss.summary = sqlite.column_text(&stmt, 4)
		ss.observation_count = int(sqlite.column_int(&stmt, 5))
		append(&out, ss)
	}
	return exact_slice(out), ""
}

// ActiveSessionForDirectory resolves an un-ended runtime session for a project
// and exact directory, then falls back to a manual-save session.
ActiveSessionForDirectory :: proc(s: ^STORE, project_arg, directory: string) -> (string, string) {
	project_name, _ := util.NormalizeProject(project_arg)
	stmt, err := sqlite.prepare(s.db, `
		SELECT id FROM sessions
		WHERE LOWER(project) = ? AND directory = ? AND ended_at IS NULL
		ORDER BY datetime(started_at) DESC LIMIT 1`)
	if err == "" {
		defer sqlite.finalize(&stmt)
		_ = sqlite.bind_text(&stmt, 1, project_name)
		_ = sqlite.bind_text(&stmt, 2, directory)
		has_row, serr := sqlite.step(&stmt)
		if serr == "" && has_row {
			return sqlite.column_text(&stmt, 0), ""
		}
	}
	return ResolveManualSession(s, project_name, directory)
}

// SessionDirectory returns the stored directory for a session.
SessionDirectory :: proc(s: ^STORE, id: string) -> (string, string) {
	sess, err := GetSession(s, id)
	if err != "" {
		return "", err
	}
	return sess.directory, ""
}

// NormalizeDirectory is a small helper used when registering sessions.
NormalizeDirectory :: proc(dir: string) -> string {
	if dir == "" {
		return ""
	}
	abs, err := filepath.abs(dir)
	if err == nil {
		return abs
	}
	return dir
}
