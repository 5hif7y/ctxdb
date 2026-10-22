package store

import "core:fmt"
import "core:strings"

import "../sqlite"
import "../util"

OBS_COLUMNS :: `o.id, ifnull(o.sync_id, ''), o.session_id, o.type, o.title, o.content,
	ifnull(o.tool_name, ''), ifnull(o.project, ''), o.scope, ifnull(o.topic_key, ''),
	o.revision_count, o.duplicate_count, ifnull(o.last_seen_at, ''), ifnull(o.review_after, ''),
	o.pinned, o.created_at, o.updated_at, ifnull(o.deleted_at, ''), ifnull(o.superseded_by_sync_id, '')`

review_after_months :: proc(typ: string) -> int {
	switch strings.to_lower(strings.trim_space(typ)) {
	case "config", "preference":
		return 3
	case "discovery", "pattern", "decision":
		return 6
	case "architecture", "bugfix", "policy":
		return 12
	case:
		return 0
	}
}

scan_observation :: proc(stmt: ^sqlite.STMT, offset := 0) -> Observation {
	o: Observation
	o.id = sqlite.column_int(stmt, offset + 0)
	o.sync_id = sqlite.column_text(stmt, offset + 1)
	o.session_id = sqlite.column_text(stmt, offset + 2)
	o.type = sqlite.column_text(stmt, offset + 3)
	o.title = sqlite.column_text(stmt, offset + 4)
	o.content = sqlite.column_text(stmt, offset + 5)
	o.tool_name = sqlite.column_text(stmt, offset + 6)
	o.project = sqlite.column_text(stmt, offset + 7)
	o.scope = sqlite.column_text(stmt, offset + 8)
	o.topic_key = sqlite.column_text(stmt, offset + 9)
	o.revision_count = int(sqlite.column_int(stmt, offset + 10))
	o.duplicate_count = int(sqlite.column_int(stmt, offset + 11))
	o.last_seen_at = sqlite.column_text(stmt, offset + 12)
	o.review_after = sqlite.column_text(stmt, offset + 13)
	o.pinned = sqlite.column_int(stmt, offset + 14) != 0
	o.created_at = sqlite.column_text(stmt, offset + 15)
	o.updated_at = sqlite.column_text(stmt, offset + 16)
	o.deleted_at = sqlite.column_text(stmt, offset + 17)
	o.superseded_by_sync_id = sqlite.column_text(stmt, offset + 18)
	return o
}

bind_nullable :: proc(stmt: ^sqlite.STMT, index: int, value: string) -> string {
	if value == "" {
		return sqlite.bind_null(stmt, index)
	}
	return sqlite.bind_text(stmt, index, value)
}

// AddObservation implements topic upserts, exact dedupe, review scheduling,
// and the optional operation ledger.
AddObservation :: proc(s: ^STORE, p: AddObservationParams) -> (AddObservationResult, string) {
	title := util.StripPrivateTags(p.title)
	content_stripped := util.StripPrivateTags(p.content)
	content, _ := util.TruncateContent(content_stripped, s.cfg.max_observation_length)
	if strings.trim_space(title) == "" {
		return {}, ERR_TITLE_REQUIRED
	}
	if content == "" {
		return {}, ERR_CONTENT_REQUIRED
	}

	scope := util.NormalizeScope(p.scope)
	topic_key := util.NormalizeTopicKey(p.topic_key)
	norm_hash := util.HashNormalized(content)

	project_name, perr := resolve_write_project(s, p.session_id, p.project)
	if perr != "" {
		return {}, perr
	}
	project_name, _ = util.NormalizeProject(project_name)

	fingerprint := util.ObservationFingerprint(
		p.session_id, p.type, title, content, p.tool_name,
		project_name, scope, topic_key,
	)

	result: AddObservationResult
	if err := sqlite.exec(s.db, "BEGIN IMMEDIATE"); err != "" {
		return {}, err
	}
	if err := add_observation_tx(s, s.db, p, title, content, project_name, scope, topic_key, norm_hash, fingerprint, &result); err != "" {
		_ = sqlite.exec(s.db, "ROLLBACK")
		return {}, err
	}
	if err := sqlite.exec(s.db, "COMMIT"); err != "" {
		_ = sqlite.exec(s.db, "ROLLBACK")
		return {}, err
	}
	return result, ""
}

add_observation_tx :: proc(
	s: ^STORE,
	db: ^sqlite.DB,
	p: AddObservationParams,
	title, content, project_name, scope, topic_key, norm_hash, fingerprint: string,
	result: ^AddObservationResult,
) -> string {
	// Replay check runs first inside the transaction.
	if p.operation_id != "" {
		stmt, err := sqlite.prepare(db, `
			SELECT o.id, operation.fingerprint
			FROM observation_save_operations AS operation
			LEFT JOIN observations AS o ON o.id = operation.observation_id AND o.deleted_at IS NULL
			WHERE operation.operation_id = ?`)
		if err != "" {
			return err
		}
		defer sqlite.finalize(&stmt)
		if berr := sqlite.bind_text(&stmt, 1, p.operation_id); berr != "" {
			return berr
		}
		has_row, serr := sqlite.step(&stmt)
		if serr != "" {
			return serr
		}
		if has_row {
			committed_fp := sqlite.column_text(&stmt, 1)
			committed_id := sqlite.column_int(&stmt, 0)
			if !strings.has_prefix(committed_fp, "v1:") {
				return ERR_OPERATION_EXPIRED
			}
			if committed_fp == fingerprint {
				if committed_id == 0 {
					return ERR_OPERATION_EXPIRED
				}
				result.id = committed_id
				result.replayed = true
				return ""
			}
			return ERR_OPERATION_CONFLICT
		}
	}

	// Topic upsert.
	if topic_key != "" {
		stmt, err := sqlite.prepare(db, `
			SELECT id FROM observations
			WHERE topic_key = ?
			  AND ifnull(project, '') = ifnull(?, '')
			  AND scope = ?
			  AND deleted_at IS NULL
			ORDER BY datetime(updated_at) DESC, datetime(created_at) DESC
			LIMIT 1`)
		if err != "" {
			return err
		}
		defer sqlite.finalize(&stmt)
		_ = sqlite.bind_text(&stmt, 1, topic_key)
		_ = bind_nullable(&stmt, 2, project_name)
		_ = sqlite.bind_text(&stmt, 3, scope)
		has_row, serr := sqlite.step(&stmt)
		if serr != "" {
			return serr
		}
		if has_row {
			existing_id := sqlite.column_int(&stmt, 0)
			if verr := capture_observation_version(s, db, existing_id); verr != "" {
				return verr
			}
			upd, uerr := sqlite.prepare(db, `
				UPDATE observations
				SET session_id = ?, type = ?, title = ?, content = ?, tool_name = ?,
				    topic_key = ?, normalized_hash = ?,
				    revision_count = revision_count + 1,
				    last_seen_at = datetime('now'), updated_at = datetime('now')
				WHERE id = ?`)
			if uerr != "" {
				return uerr
			}
			defer sqlite.finalize(&upd)
			_ = sqlite.bind_text(&upd, 1, p.session_id)
			_ = sqlite.bind_text(&upd, 2, p.type)
			_ = sqlite.bind_text(&upd, 3, title)
			_ = sqlite.bind_text(&upd, 4, content)
			_ = bind_nullable(&upd, 5, p.tool_name)
			_ = sqlite.bind_text(&upd, 6, topic_key)
			_ = sqlite.bind_text(&upd, 7, norm_hash)
			_ = sqlite.bind_int(&upd, 8, existing_id)
			if _, step_err := sqlite.step(&upd); step_err != "" {
				return step_err
			}
			result.id = existing_id
			return record_operation(s, db, p.operation_id, fingerprint, existing_id)
		}
	}

	// Exact dedupe inside the configured rolling window.
	window := fmt.tprintf("-%d minutes", s.cfg.dedupe_window_minutes)
	dedupe, derr := sqlite.prepare(db, `
		SELECT id FROM observations
		WHERE normalized_hash = ?
		  AND ifnull(project, '') = ifnull(?, '')
		  AND scope = ?
		  AND type = ?
		  AND title = ?
		  AND deleted_at IS NULL
		  AND datetime(created_at) >= datetime('now', ?)
		ORDER BY created_at DESC
		LIMIT 1`)
	if derr != "" {
		return derr
	}
	defer sqlite.finalize(&dedupe)
	_ = sqlite.bind_text(&dedupe, 1, norm_hash)
	_ = bind_nullable(&dedupe, 2, project_name)
	_ = sqlite.bind_text(&dedupe, 3, scope)
	_ = sqlite.bind_text(&dedupe, 4, p.type)
	_ = sqlite.bind_text(&dedupe, 5, title)
	_ = sqlite.bind_text(&dedupe, 6, window)
	has_row, serr := sqlite.step(&dedupe)
	if serr != "" {
		return serr
	}
	if has_row {
		existing_id := sqlite.column_int(&dedupe, 0)
		upd, uerr := sqlite.prepare(db, `
			UPDATE observations
			SET duplicate_count = duplicate_count + 1,
			    last_seen_at = datetime('now'), updated_at = datetime('now')
			WHERE id = ?`)
		if uerr != "" {
			return uerr
		}
		defer sqlite.finalize(&upd)
		_ = sqlite.bind_int(&upd, 1, existing_id)
		if _, step_err := sqlite.step(&upd); step_err != "" {
			return step_err
		}
		result.id = existing_id
		return record_operation(s, db, p.operation_id, fingerprint, existing_id)
	}

	// New row.
	ins, ierr := sqlite.prepare(db, `
		INSERT INTO observations
		(sync_id, session_id, type, title, content, tool_name, project, scope, topic_key,
		 normalized_hash, revision_count, duplicate_count, last_seen_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 1, datetime('now'), datetime('now'))`)
	if ierr != "" {
		return ierr
	}
	defer sqlite.finalize(&ins)
	_ = sqlite.bind_text(&ins, 1, util.NewSyncID("obs"))
	_ = sqlite.bind_text(&ins, 2, p.session_id)
	_ = sqlite.bind_text(&ins, 3, p.type)
	_ = sqlite.bind_text(&ins, 4, title)
	_ = sqlite.bind_text(&ins, 5, content)
	_ = bind_nullable(&ins, 6, p.tool_name)
	_ = bind_nullable(&ins, 7, project_name)
	_ = sqlite.bind_text(&ins, 8, scope)
	_ = bind_nullable(&ins, 9, topic_key)
	_ = sqlite.bind_text(&ins, 10, norm_hash)
	if _, step_err := sqlite.step(&ins); step_err != "" {
		return step_err
	}
	new_id := sqlite.last_insert_rowid(db)

	months := review_after_months(p.type)
	if months > 0 {
		upd, uerr := sqlite.prepare(db, "UPDATE observations SET review_after = datetime('now', ?) WHERE id = ?")
		if uerr != "" {
			return uerr
		}
		defer sqlite.finalize(&upd)
		_ = sqlite.bind_text(&upd, 1, fmt.tprintf("+%d months", months))
		_ = sqlite.bind_int(&upd, 2, new_id)
		_, _ = sqlite.step(&upd)
	}
	result.id = new_id
	return record_operation(s, db, p.operation_id, fingerprint, new_id)
}

record_operation :: proc(s: ^STORE, db: ^sqlite.DB, operation_id, fingerprint: string, observation_id: i64) -> string {
	if operation_id == "" {
		return ""
	}
	stmt, err := sqlite.prepare(db, `
		INSERT INTO observation_save_operations (operation_id, fingerprint, observation_id)
		VALUES (?, ?, ?)`)
	if err != "" {
		return err
	}
	defer sqlite.finalize(&stmt)
	_ = sqlite.bind_text(&stmt, 1, operation_id)
	_ = sqlite.bind_text(&stmt, 2, fingerprint)
	_ = sqlite.bind_int(&stmt, 3, observation_id)
	if _, step_err := sqlite.step(&stmt); step_err != "" {
		return step_err
	}
	return ""
}

capture_observation_version :: proc(s: ^STORE, db: ^sqlite.DB, observation_id: i64) -> string {
	stmt, err := sqlite.prepare(db, "SELECT ifnull(title,''), content FROM observations WHERE id = ?")
	if err != "" {
		return err
	}
	if berr := sqlite.bind_int(&stmt, 1, observation_id); berr != "" {
		sqlite.finalize(&stmt)
		return berr
	}
	has_row, serr := sqlite.step(&stmt)
	if serr != "" || !has_row {
		sqlite.finalize(&stmt)
		return serr
	}
	title := sqlite.column_text(&stmt, 0)
	content := sqlite.column_text(&stmt, 1)
	sqlite.finalize(&stmt)

	version_stmt, verr := sqlite.prepare(db, `
		INSERT INTO observation_versions (observation_id, title, content, version)
		VALUES (?, ?, ?, (SELECT ifnull(MAX(version), 0) + 1 FROM observation_versions WHERE observation_id = ?))`)
	if verr != "" {
		return verr
	}
	defer sqlite.finalize(&version_stmt)
	_ = sqlite.bind_int(&version_stmt, 1, observation_id)
	_ = sqlite.bind_text(&version_stmt, 2, title)
	_ = sqlite.bind_text(&version_stmt, 3, content)
	_ = sqlite.bind_int(&version_stmt, 4, observation_id)
	if _, step_err := sqlite.step(&version_stmt); step_err != "" {
		return step_err
	}
	return ""
}

GetObservation :: proc(s: ^STORE, id: i64) -> (Observation, string) {
	return get_observation_with_deleted(s, id, false)
}

GetObservationIncludingDeleted :: proc(s: ^STORE, id: i64) -> (Observation, string) {
	return get_observation_with_deleted(s, id, true)
}

get_observation_with_deleted :: proc(s: ^STORE, id: i64, include_deleted: bool) -> (Observation, string) {
	sql := cat("SELECT ", OBS_COLUMNS, " FROM observations o WHERE o.id = ?")
	if !include_deleted {
		sql = cat(sql, " AND o.deleted_at IS NULL")
	}
	stmt, err := sqlite.prepare(s.db, sql)
	if err != "" {
		return {}, err
	}
	defer sqlite.finalize(&stmt)
	if berr := sqlite.bind_int(&stmt, 1, id); berr != "" {
		return {}, berr
	}
	has_row, serr := sqlite.step(&stmt)
	if serr != "" {
		return {}, serr
	}
	if !has_row {
		return {}, ERR_OBSERVATION_NOT_FOUND
	}
	return scan_observation(&stmt), ""
}

recent_observations :: proc(s: ^STORE, project, scope: string, limit: int, unpinned_only: bool) -> ([]Observation, string) {
	project_name, _ := util.NormalizeProject(project)
	scope_name := util.NormalizeScope(scope)
	if scope == "" {
		scope_name = ""
	}
	limit_n := limit
	if limit_n <= 0 {
		limit_n = s.cfg.max_context_results
	}
	sql := cat("SELECT ", OBS_COLUMNS, " FROM observations o WHERE o.deleted_at IS NULL")
	if unpinned_only {
		sql = cat(sql, " AND o.pinned = 0")
	}
	if project_name != "" {
		sql = cat(sql, " AND LOWER(o.project) = ?")
	}
	if scope_name != "" {
		sql = cat(sql, " AND o.scope = ?")
	}
	sql = cat(sql, " ORDER BY datetime(o.created_at) DESC, o.id DESC LIMIT ?")
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
	if scope_name != "" {
		_ = sqlite.bind_text(&stmt, idx, scope_name)
		idx += 1
	}
	_ = sqlite.bind_int(&stmt, idx, i64(limit_n))

	out := make([dynamic]Observation)
	for {
		has_row, serr := sqlite.step(&stmt)
		if serr != "" {
			delete(out)
			return nil, serr
		}
		if !has_row {
			break
		}
		append(&out, scan_observation(&stmt))
	}
	return exact_slice(out), ""
}

RecentObservations :: proc(s: ^STORE, project, scope: string, limit: int) -> ([]Observation, string) {
	return recent_observations(s, project, scope, limit, false)
}

RecentUnpinnedObservations :: proc(s: ^STORE, project, scope: string, limit: int) -> ([]Observation, string) {
	return recent_observations(s, project, scope, limit, true)
}

PinnedObservations :: proc(s: ^STORE, project, scope: string) -> ([]Observation, string) {
	project_name, _ := util.NormalizeProject(project)
	sql := cat("SELECT ", OBS_COLUMNS, " FROM observations o WHERE o.deleted_at IS NULL AND o.pinned = 1")
	if project_name != "" {
		sql = cat(sql, " AND LOWER(o.project) = ?")
	}
	if scope != "" {
		sql = cat(sql, " AND o.scope = ?")
	}
	sql = cat(sql, " ORDER BY datetime(o.created_at) DESC, o.id DESC")
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
	if scope != "" {
		_ = sqlite.bind_text(&stmt, idx, util.NormalizeScope(scope))
	}
	out := make([dynamic]Observation)
	for {
		has_row, serr := sqlite.step(&stmt)
		if serr != "" {
			delete(out)
			return nil, serr
		}
		if !has_row {
			break
		}
		append(&out, scan_observation(&stmt))
	}
	return exact_slice(out), ""
}

PinObservation :: proc(s: ^STORE, id: i64, pinned: bool) -> string {
	stmt, err := sqlite.prepare(s.db, "UPDATE observations SET pinned = ? WHERE id = ? AND deleted_at IS NULL")
	if err != "" {
		return err
	}
	defer sqlite.finalize(&stmt)
	_ = sqlite.bind_int(&stmt, 1, pinned ? 1 : 0)
	_ = sqlite.bind_int(&stmt, 2, id)
	if _, serr := sqlite.step(&stmt); serr != "" {
		return serr
	}
	if sqlite.changes(s.db) == 0 {
		return ERR_OBSERVATION_NOT_FOUND
	}
	return ""
}

DeleteObservation :: proc(s: ^STORE, id: i64, hard: bool) -> string {
	_, gerr := GetObservationIncludingDeleted(s, id)
	if gerr != "" {
		return gerr
	}
	if hard {
		stmt, err := sqlite.prepare(s.db, "DELETE FROM observations WHERE id = ?")
		if err != "" {
			return err
		}
		defer sqlite.finalize(&stmt)
		_ = sqlite.bind_int(&stmt, 1, id)
		if _, serr := sqlite.step(&stmt); serr != "" {
			return serr
		}
		return ""
	}
	stmt, err := sqlite.prepare(s.db, "UPDATE observations SET deleted_at = datetime('now'), updated_at = datetime('now') WHERE id = ? AND deleted_at IS NULL")
	if err != "" {
		return err
	}
	defer sqlite.finalize(&stmt)
	_ = sqlite.bind_int(&stmt, 1, id)
	if _, serr := sqlite.step(&stmt); serr != "" {
		return serr
	}
	return ""
}

UpdateObservation :: proc(s: ^STORE, id: i64, p: UpdateObservationParams) -> (Observation, string) {
	obs, gerr := GetObservation(s, id)
	if gerr != "" {
		return {}, gerr
	}
	title := obs.title
	content := obs.content
	typ := obs.type
	project_name := obs.project
	scope := obs.scope
	topic_key := obs.topic_key

	has_find := false
	has_replace := false
	find := ""
	replace := ""
	if v, ok := p.find.?; ok {
		has_find = true
		find = v
	}
	if v, ok := p.replace.?; ok {
		has_replace = true
		replace = v
	}
	if has_find != has_replace {
		return {}, "find and replace must be provided together"
	}
	if _, content_set := p.content.?; has_find && content_set {
		return {}, "content cannot be combined with find and replace"
	}
	if v, ok := p.type.?; ok {
		typ = v
	}
	if v, ok := p.title.?; ok {
		stripped := util.StripPrivateTags(v)
		if strings.trim_space(stripped) == "" {
			return {}, ERR_TITLE_REQUIRED
		}
		title = stripped
	}
	if v, ok := p.content.?; ok {
		stripped := util.StripPrivateTags(v)
		if stripped == "" {
			return {}, ERR_CONTENT_REQUIRED
		}
		content, _ = util.TruncateContent(stripped, s.cfg.max_observation_length)
	}
	if has_find {
		if find == "" {
			return {}, "find text is required"
		}
		content, _ = strings.replace_all(content, find, replace)
	}
	if v, ok := p.project.?; ok {
		project_name, _ = util.NormalizeProject(v)
	}
	if v, ok := p.scope.?; ok {
		scope = util.NormalizeScope(v)
	}
	if v, ok := p.topic_key.?; ok {
		topic_key = util.NormalizeTopicKey(v)
	}

	if err := sqlite.exec(s.db, "BEGIN IMMEDIATE"); err != "" {
		return {}, err
	}
	if verr := capture_observation_version(s, s.db, id); verr != "" {
		_ = sqlite.exec(s.db, "ROLLBACK")
		return {}, verr
	}
	stmt, perr := sqlite.prepare(s.db, `
		UPDATE observations
		SET type = ?, title = ?, content = ?, project = ?, scope = ?, topic_key = ?,
		    normalized_hash = ?, updated_at = datetime('now')
		WHERE id = ? AND deleted_at IS NULL`)
	if perr != "" {
		_ = sqlite.exec(s.db, "ROLLBACK")
		return {}, perr
	}
	_ = sqlite.bind_text(&stmt, 1, typ)
	_ = sqlite.bind_text(&stmt, 2, title)
	_ = sqlite.bind_text(&stmt, 3, content)
	_ = bind_nullable(&stmt, 4, project_name)
	_ = sqlite.bind_text(&stmt, 5, scope)
	_ = bind_nullable(&stmt, 6, topic_key)
	_ = sqlite.bind_text(&stmt, 7, util.HashNormalized(content))
	_ = sqlite.bind_int(&stmt, 8, id)
	_, serr := sqlite.step(&stmt)
	sqlite.finalize(&stmt)
	if serr != "" {
		_ = sqlite.exec(s.db, "ROLLBACK")
		return {}, serr
	}
	if err := sqlite.exec(s.db, "COMMIT"); err != "" {
		_ = sqlite.exec(s.db, "ROLLBACK")
		return {}, err
	}
	return GetObservation(s, id)
}

ObservationsNeedingReview :: proc(s: ^STORE, project: string, limit: int) -> ([]Observation, string) {
	project_name, _ := util.NormalizeProject(project)
	limit_n := limit
	if limit_n <= 0 {
		limit_n = s.cfg.max_context_results
	}
	sql := cat("SELECT ", OBS_COLUMNS, ` FROM observations o
		WHERE o.deleted_at IS NULL AND o.review_after IS NOT NULL
		  AND datetime(o.review_after) <= datetime('now')`)
	if project_name != "" {
		sql = cat(sql, " AND LOWER(o.project) = ?")
	}
	sql = cat(sql, " ORDER BY datetime(o.review_after) ASC, o.id ASC LIMIT ?")
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
	_ = sqlite.bind_int(&stmt, idx, i64(limit_n))
	out := make([dynamic]Observation)
	for {
		has_row, serr := sqlite.step(&stmt)
		if serr != "" {
			delete(out)
			return nil, serr
		}
		if !has_row {
			break
		}
		append(&out, scan_observation(&stmt))
	}
	return exact_slice(out), ""
}

MarkReviewed :: proc(s: ^STORE, id: i64) -> string {
	obs, err := GetObservation(s, id)
	if err != "" {
		return err
	}
	months := review_after_months(obs.type)
	stmt, perr := sqlite.prepare(s.db, `
		UPDATE observations
		SET review_after = CASE WHEN ? > 0 THEN datetime('now', ?) ELSE NULL END,
		    updated_at = datetime('now')
		WHERE id = ? AND deleted_at IS NULL`)
	if perr != "" {
		return perr
	}
	defer sqlite.finalize(&stmt)
	_ = sqlite.bind_int(&stmt, 1, i64(months))
	_ = bind_nullable(&stmt, 2, months > 0 ? fmt.tprintf("+%d months", months) : "")
	_ = sqlite.bind_int(&stmt, 3, id)
	if _, serr := sqlite.step(&stmt); serr != "" {
		return serr
	}
	return ""
}

Timeline :: proc(s: ^STORE, observation_id: i64, before_count, after_count: int) -> (TimelineResult, string) {
	before_n := before_count
	after_n := after_count
	if before_n <= 0 {
		before_n = 5
	}
	if after_n <= 0 {
		after_n = 5
	}
	focus, ferr := GetObservation(s, observation_id)
	if ferr != "" {
		return {}, ferr
	}
	result: TimelineResult
	result.focus = focus
	if session, serr := GetSession(s, focus.session_id); serr == "" {
		result.session_info = session
	}

	before_rows, berr := timeline_entries(s, focus.session_id, observation_id, before_n, true)
	if berr != "" {
		return {}, berr
	}
	// Reverse into chronological order.
	for i, j := 0, len(before_rows) - 1; i < j; i, j = i + 1, j - 1 {
		before_rows[i], before_rows[j] = before_rows[j], before_rows[i]
	}
	result.before = before_rows

	after_rows, aerr := timeline_entries(s, focus.session_id, observation_id, after_n, false)
	if aerr != "" {
		return {}, aerr
	}
	result.after = after_rows

	stmt, cerr := sqlite.prepare(s.db, "SELECT COUNT(*) FROM observations WHERE session_id = ? AND deleted_at IS NULL")
	if cerr != "" {
		return {}, cerr
	}
	defer sqlite.finalize(&stmt)
	_ = sqlite.bind_text(&stmt, 1, focus.session_id)
	if has_row, serr := sqlite.step(&stmt); serr == "" && has_row {
		result.total_in_range = int(sqlite.column_int(&stmt, 0))
	}
	return result, ""
}

timeline_entries :: proc(s: ^STORE, session_id: string, focus_id: i64, limit: int, older: bool) -> ([]TimelineEntry, string) {
	op := ">"
	order := "ASC"
	if older {
		op = "<"
		order = "DESC"
	}
	sql := cat(`SELECT o.id, o.session_id, o.type, o.title, o.content, ifnull(o.tool_name, ''),
		ifnull(o.project, ''), o.scope, ifnull(o.topic_key, ''), o.revision_count,
		o.duplicate_count, ifnull(o.last_seen_at, ''), o.created_at, o.updated_at,
		ifnull(o.deleted_at, ''), ifnull(o.superseded_by_sync_id, '')
		FROM observations o
		WHERE o.session_id = ? AND o.id `, op, ` ? AND o.deleted_at IS NULL
		ORDER BY o.id `, order, ` LIMIT ?`)
	stmt, err := sqlite.prepare(s.db, sql)
	if err != "" {
		return nil, err
	}
	defer sqlite.finalize(&stmt)
	_ = sqlite.bind_text(&stmt, 1, session_id)
	_ = sqlite.bind_int(&stmt, 2, focus_id)
	_ = sqlite.bind_int(&stmt, 3, i64(limit))
	out := make([dynamic]TimelineEntry)
	for {
		has_row, serr := sqlite.step(&stmt)
		if serr != "" {
			delete(out)
			return nil, serr
		}
		if !has_row {
			break
		}
		e: TimelineEntry
		e.id = sqlite.column_int(&stmt, 0)
		e.session_id = sqlite.column_text(&stmt, 1)
		e.type = sqlite.column_text(&stmt, 2)
		e.title = sqlite.column_text(&stmt, 3)
		e.content = sqlite.column_text(&stmt, 4)
		e.tool_name = sqlite.column_text(&stmt, 5)
		e.project = sqlite.column_text(&stmt, 6)
		e.scope = sqlite.column_text(&stmt, 7)
		e.topic_key = sqlite.column_text(&stmt, 8)
		e.revision_count = int(sqlite.column_int(&stmt, 9))
		e.duplicate_count = int(sqlite.column_int(&stmt, 10))
		e.last_seen_at = sqlite.column_text(&stmt, 11)
		e.created_at = sqlite.column_text(&stmt, 12)
		e.updated_at = sqlite.column_text(&stmt, 13)
		e.deleted_at = sqlite.column_text(&stmt, 14)
		e.superseded_by_sync_id = sqlite.column_text(&stmt, 15)
		append(&out, e)
	}
	return exact_slice(out), ""
}

SessionObservations :: proc(s: ^STORE, session_id: string, limit: int) -> ([]Observation, string) {
	limit_n := limit
	if limit_n <= 0 {
		limit_n = 200
	}
	sql := cat("SELECT ", OBS_COLUMNS, ` FROM observations o
		WHERE o.session_id = ? AND o.deleted_at IS NULL
		ORDER BY o.id ASC LIMIT ?`)
	stmt, err := sqlite.prepare(s.db, sql)
	if err != "" {
		return nil, err
	}
	defer sqlite.finalize(&stmt)
	_ = sqlite.bind_text(&stmt, 1, session_id)
	_ = sqlite.bind_int(&stmt, 2, i64(limit_n))
	out := make([dynamic]Observation)
	for {
		has, serr := sqlite.step(&stmt)
		if serr != "" {
			delete(out)
			return nil, serr
		}
		if !has {
			break
		}
		append(&out, scan_observation(&stmt))
	}
	return exact_slice(out), ""
}
