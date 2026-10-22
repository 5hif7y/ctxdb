// Direct JSON backup export/import (Engram backup version 0.2.0).
package store

import "core:encoding/json"
import "../sqlite"
import "../util"

EXPORT_VERSION :: "0.2.0"
LEGACY_EXPORT_VERSION :: "0.1.0"

Backup_Observation :: struct {
	id:                    i64    `json:"id"`,
	sync_id:               string `json:"sync_id"`,
	session_id:            string `json:"session_id"`,
	type:                  string `json:"type"`,
	title:                 string `json:"title"`,
	content:               string `json:"content"`,
	tool_name:             string `json:"tool_name,omitempty"`,
	project:               string `json:"project,omitempty"`,
	scope:                 string `json:"scope"`,
	topic_key:             string `json:"topic_key,omitempty"`,
	revision_count:        int    `json:"revision_count"`,
	duplicate_count:       int    `json:"duplicate_count"`,
	last_seen_at:          string `json:"last_seen_at,omitempty"`,
	review_after:          string `json:"review_after,omitempty"`,
	superseded_by_sync_id: string `json:"superseded_by_sync_id,omitempty"`,
	pinned:                bool   `json:"pinned"`,
	created_at:            string `json:"created_at"`,
	updated_at:            string `json:"updated_at"`,
	deleted_at:            string `json:"deleted_at,omitempty"`,
}

Prompt_Tombstone :: struct {
	sync_id:         string `json:"sync_id"`,
	session_id:      string `json:"session_id"`,
	project:         string `json:"project,omitempty"`,
	source_inbox_id: string `json:"source_inbox_id,omitempty"`,
	deleted_at:      string `json:"deleted_at"`,
}

Export_Data :: struct {
	version:           string               `json:"version"`,
	exported_at:       string               `json:"exported_at"`,
	sessions:          []Session            `json:"sessions"`,
	observations:      []Backup_Observation `json:"observations"`,
	prompts:           []Prompt             `json:"prompts"`,
	relations:         []Relation           `json:"relations,omitempty"`,
	prompt_tombstones: []Prompt_Tombstone   `json:"prompt_tombstones,omitempty"`,
}

Import_Result :: struct {
	sessions_imported:          int `json:"sessions_imported"`,
	observations_imported:      int `json:"observations_imported"`,
	observations_updated:       int `json:"observations_updated"`,
	observations_skipped_stale: int `json:"observations_skipped_stale"`,
	prompts_imported:           int `json:"prompts_imported"`,
	relations_imported:         int `json:"relations_imported"`,
}

backup_observation :: proc(obs: Observation) -> Backup_Observation {
	return Backup_Observation{
		id = obs.id,
		sync_id = obs.sync_id,
		session_id = obs.session_id,
		type = obs.type,
		title = obs.title,
		content = obs.content,
		tool_name = obs.tool_name,
		project = obs.project,
		scope = obs.scope,
		topic_key = obs.topic_key,
		revision_count = obs.revision_count,
		duplicate_count = obs.duplicate_count,
		last_seen_at = obs.last_seen_at,
		review_after = obs.review_after,
		superseded_by_sync_id = obs.superseded_by_sync_id,
		pinned = obs.pinned,
		created_at = obs.created_at,
		updated_at = obs.updated_at,
		deleted_at = obs.deleted_at,
	}
}

Export :: proc(s: ^STORE, project_arg: string) -> (Export_Data, string) {
	project_name, _ := util.NormalizeProject(project_arg)
	data := Export_Data{
		version = EXPORT_VERSION,
		exported_at = Now(s.db),
	}

	session_sql := "SELECT id, ifnull(project,''), ifnull(ownership_mode,''), directory, started_at, ifnull(ended_at,''), ifnull(summary,'') FROM sessions"
	if project_name != "" {
		session_sql = cat(session_sql, ` WHERE id IN (
			SELECT id FROM sessions WHERE project = ?
			UNION SELECT session_id FROM observations WHERE project = ?
			UNION SELECT session_id FROM user_prompts WHERE project = ?)`)
	}
	session_sql = cat(session_sql, " ORDER BY started_at")
	stmt, err := sqlite.prepare(s.db, session_sql)
	if err != "" {
		return data, err
	}
	if project_name != "" {
		_ = sqlite.bind_text(&stmt, 1, project_name)
		_ = sqlite.bind_text(&stmt, 2, project_name)
		_ = sqlite.bind_text(&stmt, 3, project_name)
	}
	sessions := make([dynamic]Session)
	for {
		has, serr := sqlite.step(&stmt)
		if serr != "" {
			sqlite.finalize(&stmt)
			delete(sessions)
			return data, serr
		}
		if !has {
			break
		}
		sess: Session
		sess.id = sqlite.column_text(&stmt, 0)
		sess.project = sqlite.column_text(&stmt, 1)
		sess.ownership_mode = sqlite.column_text(&stmt, 2)
		sess.directory = sqlite.column_text(&stmt, 3)
		sess.started_at = sqlite.column_text(&stmt, 4)
		sess.ended_at = sqlite.column_text(&stmt, 5)
		sess.summary = sqlite.column_text(&stmt, 6)
		append(&sessions, sess)
	}
	sqlite.finalize(&stmt)
	data.sessions = exact_slice(sessions)

	obs_sql := cat("SELECT ", OBS_COLUMNS, " FROM observations o")
	if project_name != "" {
		obs_sql = cat(obs_sql, ` WHERE o.id IN (
			SELECT id FROM observations WHERE project = ?
			UNION ALL SELECT o.id FROM sessions s JOIN observations o ON o.session_id = s.id
			WHERE s.project = ? AND (o.project IS NULL OR o.project = ''))`)
	}
	obs_sql = cat(obs_sql, " ORDER BY o.id")
	stmt, err = sqlite.prepare(s.db, obs_sql)
	if err != "" {
		return data, err
	}
	if project_name != "" {
		_ = sqlite.bind_text(&stmt, 1, project_name)
		_ = sqlite.bind_text(&stmt, 2, project_name)
	}
	observations := make([dynamic]Backup_Observation)
	for {
		has, serr := sqlite.step(&stmt)
		if serr != "" {
			sqlite.finalize(&stmt)
			delete(observations)
			return data, serr
		}
		if !has {
			break
		}
		append(&observations, backup_observation(scan_observation(&stmt)))
	}
	sqlite.finalize(&stmt)
	data.observations = exact_slice(observations)

	prompt_sql := "SELECT id, ifnull(sync_id,''), session_id, content, ifnull(project,''), created_at, ifnull(source_inbox_id,'') FROM user_prompts"
	if project_name != "" {
		prompt_sql = cat(prompt_sql, " WHERE project = ?")
	}
	prompt_sql = cat(prompt_sql, " ORDER BY id")
	stmt, err = sqlite.prepare(s.db, prompt_sql)
	if err != "" {
		return data, err
	}
	if project_name != "" {
		_ = sqlite.bind_text(&stmt, 1, project_name)
	}
	prompts := make([dynamic]Prompt)
	for {
		has, serr := sqlite.step(&stmt)
		if serr != "" {
			sqlite.finalize(&stmt)
			delete(prompts)
			return data, serr
		}
		if !has {
			break
		}
		p: Prompt
		p.id = sqlite.column_int(&stmt, 0)
		p.sync_id = sqlite.column_text(&stmt, 1)
		p.session_id = sqlite.column_text(&stmt, 2)
		p.content = sqlite.column_text(&stmt, 3)
		p.project = sqlite.column_text(&stmt, 4)
		p.created_at = sqlite.column_text(&stmt, 5)
		p.source_inbox_id = sqlite.column_text(&stmt, 6)
		append(&prompts, p)
	}
	sqlite.finalize(&stmt)
	data.prompts = exact_slice(prompts)

	rel_sql := `
		SELECT r.id, r.sync_id, ifnull(r.source_id,''), ifnull(r.target_id,''), r.relation,
		       ifnull(r.reason,''), ifnull(r.evidence,''), ifnull(r.confidence, 0),
		       r.judgment_status, ifnull(r.marked_by_actor,''), ifnull(r.marked_by_kind,''),
		       ifnull(r.marked_by_model,''), ifnull(r.session_id,''), ifnull(r.superseded_at,''),
		       ifnull(ss.sync_id,''), r.created_at, r.updated_at
		FROM memory_relations r
		LEFT JOIN memory_relations ss ON ss.id = r.superseded_by_relation_id`
	if project_name != "" {
		rel_sql = cat(rel_sql, ` WHERE r.source_id IN (SELECT sync_id FROM observations WHERE project = ?)
			AND r.target_id IN (SELECT sync_id FROM observations WHERE project = ?)`)
	}
	rel_sql = cat(rel_sql, " ORDER BY r.created_at, r.sync_id")
	stmt, err = sqlite.prepare(s.db, rel_sql)
	if err != "" {
		return data, err
	}
	if project_name != "" {
		_ = sqlite.bind_text(&stmt, 1, project_name)
		_ = sqlite.bind_text(&stmt, 2, project_name)
	}
	relations := make([dynamic]Relation)
	for {
		has, serr := sqlite.step(&stmt)
		if serr != "" {
			sqlite.finalize(&stmt)
			delete(relations)
			return data, serr
		}
		if !has {
			break
		}
		rel: Relation
		rel.id = sqlite.column_int(&stmt, 0)
		rel.sync_id = sqlite.column_text(&stmt, 1)
		rel.source_id = sqlite.column_text(&stmt, 2)
		rel.target_id = sqlite.column_text(&stmt, 3)
		rel.relation = sqlite.column_text(&stmt, 4)
		rel.reason = sqlite.column_text(&stmt, 5)
		rel.evidence = sqlite.column_text(&stmt, 6)
		rel.confidence = sqlite.column_double(&stmt, 7)
		rel.judgment_status = sqlite.column_text(&stmt, 8)
		rel.marked_by_actor = sqlite.column_text(&stmt, 9)
		rel.marked_by_kind = sqlite.column_text(&stmt, 10)
		rel.marked_by_model = sqlite.column_text(&stmt, 11)
		rel.session_id = sqlite.column_text(&stmt, 12)
		rel.superseded_at = sqlite.column_text(&stmt, 13)
		rel.superseded_by_sync_id = sqlite.column_text(&stmt, 14)
		rel.created_at = sqlite.column_text(&stmt, 15)
		rel.updated_at = sqlite.column_text(&stmt, 16)
		append(&relations, rel)
	}
	sqlite.finalize(&stmt)
	data.relations = exact_slice(relations)

	stmt, err = sqlite.prepare(s.db, "SELECT sync_id, ifnull(session_id,''), ifnull(project,''), ifnull(source_inbox_id,''), deleted_at FROM prompt_tombstones ORDER BY sync_id")
	if err == "" {
		tombstones := make([dynamic]Prompt_Tombstone)
		for {
			has, serr := sqlite.step(&stmt)
			if serr != "" || !has {
				break
			}
			t: Prompt_Tombstone
			t.sync_id = sqlite.column_text(&stmt, 0)
			t.session_id = sqlite.column_text(&stmt, 1)
			t.project = sqlite.column_text(&stmt, 2)
			t.source_inbox_id = sqlite.column_text(&stmt, 3)
			t.deleted_at = sqlite.column_text(&stmt, 4)
			append(&tombstones, t)
		}
		sqlite.finalize(&stmt)
		data.prompt_tombstones = exact_slice(tombstones)
	}
	return data, ""
}

Import :: proc(s: ^STORE, data: Export_Data) -> (Import_Result, string) {
	result: Import_Result
	if data.version != "" && data.version != LEGACY_EXPORT_VERSION && data.version != EXPORT_VERSION {
		return result, cat("unsupported export version ", data.version)
	}
	if err := sqlite.exec(s.db, "BEGIN IMMEDIATE"); err != "" {
		return result, err
	}
	for sess in data.sessions {
		ins, ierr := sqlite.prepare(s.db, `
			INSERT OR IGNORE INTO sessions (id, project, ownership_mode, directory, started_at, ended_at, summary)
			VALUES (?, ?, coalesce(?, 'shared'), ?, ?, ?, ?)`)
		if ierr != "" {
			_ = sqlite.exec(s.db, "ROLLBACK")
			return result, ierr
		}
		_ = sqlite.bind_text(&ins, 1, sess.id)
		_ = sqlite.bind_text(&ins, 2, sess.project)
		_ = bind_nullable(&ins, 3, sess.ownership_mode)
		_ = sqlite.bind_text(&ins, 4, sess.directory)
		_ = sqlite.bind_text(&ins, 5, sess.started_at)
		_ = bind_nullable(&ins, 6, sess.ended_at)
		_ = bind_nullable(&ins, 7, sess.summary)
		_, serr := sqlite.step(&ins)
		sqlite.finalize(&ins)
		if serr != "" {
			_ = sqlite.exec(s.db, "ROLLBACK")
			return result, serr
		}
		if sqlite.changes(s.db) > 0 {
			result.sessions_imported += 1
		}
	}

	for obs in data.observations {
		sync_id := obs.sync_id
		if sync_id == "" {
			sync_id = util.NewSyncID("obs")
		}
		existing, gerr := GetObservationBySyncIDIncludingDeleted(s, sync_id)
		if gerr == "" {
			incoming := obs.updated_at
			current := existing.updated_at
			if incoming == "" || current == "" || incoming <= current {
				result.observations_skipped_stale += 1
				continue
			}
			upd, uerr := sqlite.prepare(s.db, `
				UPDATE observations
				SET session_id = ?, type = ?, title = ?, content = ?, tool_name = ?,
				    project = ?, scope = ?, topic_key = ?, normalized_hash = ?,
				    revision_count = ?, duplicate_count = ?, last_seen_at = ?,
				    review_after = ?, pinned = ?, created_at = ?, updated_at = ?, deleted_at = ?,
				    superseded_by_sync_id = ?
				WHERE id = ?`)
			if uerr != "" {
				_ = sqlite.exec(s.db, "ROLLBACK")
				return result, uerr
			}
			_ = sqlite.bind_text(&upd, 1, obs.session_id)
			_ = sqlite.bind_text(&upd, 2, obs.type)
			_ = sqlite.bind_text(&upd, 3, obs.title)
			_ = sqlite.bind_text(&upd, 4, obs.content)
			_ = bind_nullable(&upd, 5, obs.tool_name)
			_ = bind_nullable(&upd, 6, obs.project)
			_ = sqlite.bind_text(&upd, 7, util.NormalizeScope(obs.scope))
			_ = bind_nullable(&upd, 8, util.NormalizeTopicKey(obs.topic_key))
			_ = sqlite.bind_text(&upd, 9, util.HashNormalized(obs.content))
			_ = sqlite.bind_int(&upd, 10, i64(obs.revision_count))
			_ = sqlite.bind_int(&upd, 11, i64(obs.duplicate_count))
			_ = bind_nullable(&upd, 12, obs.last_seen_at)
			_ = bind_nullable(&upd, 13, obs.review_after)
			_ = sqlite.bind_int(&upd, 14, obs.pinned ? 1 : 0)
			_ = sqlite.bind_text(&upd, 15, obs.created_at)
			_ = sqlite.bind_text(&upd, 16, obs.updated_at)
			_ = bind_nullable(&upd, 17, obs.deleted_at)
			_ = bind_nullable(&upd, 18, obs.superseded_by_sync_id)
			_ = sqlite.bind_int(&upd, 19, existing.id)
			_, ude := sqlite.step(&upd)
			sqlite.finalize(&upd)
			if ude != "" {
				_ = sqlite.exec(s.db, "ROLLBACK")
				return result, ude
			}
			result.observations_updated += 1
			continue
		}
		ins, ierr := sqlite.prepare(s.db, `
			INSERT INTO observations
				(sync_id, session_id, type, title, content, tool_name, project, scope, topic_key,
				 normalized_hash, revision_count, duplicate_count, last_seen_at, review_after,
				 pinned, created_at, updated_at, deleted_at, superseded_by_sync_id)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
		if ierr != "" {
			_ = sqlite.exec(s.db, "ROLLBACK")
			return result, ierr
		}
		_ = sqlite.bind_text(&ins, 1, sync_id)
		_ = sqlite.bind_text(&ins, 2, obs.session_id)
		_ = sqlite.bind_text(&ins, 3, obs.type)
		_ = sqlite.bind_text(&ins, 4, obs.title)
		_ = sqlite.bind_text(&ins, 5, obs.content)
		_ = bind_nullable(&ins, 6, obs.tool_name)
		_ = bind_nullable(&ins, 7, obs.project)
		_ = sqlite.bind_text(&ins, 8, util.NormalizeScope(obs.scope))
		_ = bind_nullable(&ins, 9, util.NormalizeTopicKey(obs.topic_key))
		_ = sqlite.bind_text(&ins, 10, util.HashNormalized(obs.content))
		_ = sqlite.bind_int(&ins, 11, i64(max(1, obs.revision_count)))
		_ = sqlite.bind_int(&ins, 12, i64(max(1, obs.duplicate_count)))
		_ = bind_nullable(&ins, 13, obs.last_seen_at)
		_ = bind_nullable(&ins, 14, obs.review_after)
		_ = sqlite.bind_int(&ins, 15, obs.pinned ? 1 : 0)
		_ = sqlite.bind_text(&ins, 16, obs.created_at)
		_ = sqlite.bind_text(&ins, 17, obs.updated_at)
		_ = bind_nullable(&ins, 18, obs.deleted_at)
		_ = bind_nullable(&ins, 19, obs.superseded_by_sync_id)
		_, serr := sqlite.step(&ins)
		sqlite.finalize(&ins)
		if serr != "" {
			_ = sqlite.exec(s.db, "ROLLBACK")
			return result, serr
		}
		result.observations_imported += 1
	}

	for p in data.prompts {
		sync_id := p.sync_id
		if sync_id == "" {
			sync_id = util.NewSyncID("prompt")
		}
		ins, ierr := sqlite.prepare(s.db, `
			INSERT INTO user_prompts (sync_id, session_id, content, project, created_at, source_inbox_id)
			SELECT ?, ?, ?, ?, ?, ?
			WHERE NOT EXISTS (SELECT 1 FROM user_prompts WHERE sync_id = ?)`)
		if ierr != "" {
			_ = sqlite.exec(s.db, "ROLLBACK")
			return result, ierr
		}
		_ = sqlite.bind_text(&ins, 1, sync_id)
		_ = sqlite.bind_text(&ins, 2, p.session_id)
		_ = sqlite.bind_text(&ins, 3, p.content)
		_ = bind_nullable(&ins, 4, p.project)
		_ = sqlite.bind_text(&ins, 5, p.created_at)
		_ = bind_nullable(&ins, 6, p.source_inbox_id)
		_ = sqlite.bind_text(&ins, 7, sync_id)
		_, serr := sqlite.step(&ins)
		sqlite.finalize(&ins)
		if serr != "" {
			_ = sqlite.exec(s.db, "ROLLBACK")
			return result, serr
		}
		if sqlite.changes(s.db) > 0 {
			result.prompts_imported += 1
		}
	}

	for rel in data.relations {
		ins, ierr := sqlite.prepare(s.db, `
			INSERT OR IGNORE INTO memory_relations
				(sync_id, source_id, target_id, relation, reason, evidence, confidence,
				 judgment_status, marked_by_actor, marked_by_kind, marked_by_model,
				 session_id, superseded_at, created_at, updated_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
		if ierr != "" {
			_ = sqlite.exec(s.db, "ROLLBACK")
			return result, ierr
		}
		_ = sqlite.bind_text(&ins, 1, rel.sync_id)
		_ = bind_nullable(&ins, 2, rel.source_id)
		_ = bind_nullable(&ins, 3, rel.target_id)
		_ = sqlite.bind_text(&ins, 4, rel.relation)
		_ = bind_nullable(&ins, 5, rel.reason)
		_ = bind_nullable(&ins, 6, rel.evidence)
		_ = sqlite.bind_double(&ins, 7, rel.confidence)
		_ = sqlite.bind_text(&ins, 8, rel.judgment_status)
		_ = bind_nullable(&ins, 9, rel.marked_by_actor)
		_ = bind_nullable(&ins, 10, rel.marked_by_kind)
		_ = bind_nullable(&ins, 11, rel.marked_by_model)
		_ = bind_nullable(&ins, 12, rel.session_id)
		_ = bind_nullable(&ins, 13, rel.superseded_at)
		_ = sqlite.bind_text(&ins, 14, rel.created_at)
		_ = sqlite.bind_text(&ins, 15, rel.updated_at)
		_, serr := sqlite.step(&ins)
		sqlite.finalize(&ins)
		if serr != "" {
			_ = sqlite.exec(s.db, "ROLLBACK")
			return result, serr
		}
		if sqlite.changes(s.db) > 0 {
			result.relations_imported += 1
		}
	}

	for t in data.prompt_tombstones {
		ins, ierr := sqlite.prepare(s.db, `
			INSERT OR IGNORE INTO prompt_tombstones (sync_id, session_id, project, source_inbox_id, deleted_at)
			VALUES (?, ?, ?, ?, ?)`)
		if ierr != "" {
			_ = sqlite.exec(s.db, "ROLLBACK")
			return result, ierr
		}
		_ = sqlite.bind_text(&ins, 1, t.sync_id)
		_ = bind_nullable(&ins, 2, t.session_id)
		_ = bind_nullable(&ins, 3, t.project)
		_ = bind_nullable(&ins, 4, t.source_inbox_id)
		_ = sqlite.bind_text(&ins, 5, t.deleted_at)
		_, _ = sqlite.step(&ins)
		sqlite.finalize(&ins)
	}

	if err := sqlite.exec(s.db, "COMMIT"); err != "" {
		_ = sqlite.exec(s.db, "ROLLBACK")
		return result, err
	}
	return result, ""
}

GetObservationBySyncIDIncludingDeleted :: proc(s: ^STORE, sync_id: string) -> (Observation, string) {
	sql := cat("SELECT ", OBS_COLUMNS, " FROM observations o WHERE o.sync_id = ?")
	stmt, err := sqlite.prepare(s.db, sql)
	if err != "" {
		return {}, err
	}
	defer sqlite.finalize(&stmt)
	_ = sqlite.bind_text(&stmt, 1, sync_id)
	has, serr := sqlite.step(&stmt)
	if serr != "" {
		return {}, serr
	}
	if !has {
		return {}, ERR_OBSERVATION_NOT_FOUND
	}
	return scan_observation(&stmt), ""
}

Marshal_Export :: proc(data: Export_Data) -> ([]byte, json.Marshal_Error) {
	return json.marshal(data, json.Marshal_Options{pretty = true, use_spaces = true, spaces = 2})
}

GetObservationSaveResult :: proc(s: ^STORE, operation_id: string) -> (i64, string) {
	if operation_id == "" {
		return 0, ""
	}
	stmt, err := sqlite.prepare(s.db, `
		SELECT operation.fingerprint, ifnull(o.id, 0)
		FROM observation_save_operations operation
		LEFT JOIN observations o ON o.id = operation.observation_id AND o.deleted_at IS NULL
		WHERE operation.operation_id = ?`)
	if err != "" {
		return 0, err
	}
	defer sqlite.finalize(&stmt)
	_ = sqlite.bind_text(&stmt, 1, operation_id)
	has, serr := sqlite.step(&stmt)
	if serr != "" {
		return 0, serr
	}
	if !has {
		return 0, ""
	}
	fingerprint := sqlite.column_text(&stmt, 0)
	id := sqlite.column_int(&stmt, 1)
	if fingerprint == "" {
		return 0, ERR_OPERATION_EXPIRED
	}
	if id == 0 {
		return 0, ERR_OPERATION_EXPIRED
	}
	return id, ""
}
