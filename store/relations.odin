// Memory relations and conflict judgments.
//
// Engram stores semantic relationships between observations as portable
// sync_id pairs. This port keeps the same vocabulary and persistence shape,
// while sync delivery remains a later phase.
package store

import "core:fmt"
import "core:math"
import "core:strings"

import "../sqlite"
import "../util"

RELATION_PENDING :: "pending"
RELATION_RELATED :: "related"
RELATION_COMPATIBLE :: "compatible"
RELATION_SCOPED :: "scoped"
RELATION_CONFLICTS_WITH :: "conflicts_with"
RELATION_SUPERSEDES :: "supersedes"
RELATION_NOT_CONFLICT :: "not_conflict"

JUDGMENT_PENDING :: "pending"
JUDGMENT_JUDGED :: "judged"
JUDGMENT_ORPHANED :: "orphaned"
JUDGMENT_IGNORED :: "ignored"

valid_relation_verb :: proc(verb: string) -> bool {
	switch verb {
	case RELATION_RELATED, RELATION_COMPATIBLE, RELATION_SCOPED,
		RELATION_CONFLICTS_WITH, RELATION_SUPERSEDES, RELATION_NOT_CONFLICT:
		return true
	case:
		return false
	}
}

valid_confidence :: proc(value: f64) -> bool {
	if math.is_nan(value) || math.is_inf(value, 1) || math.is_inf(value, -1) {
		return false
	}
	return value >= 0.0 && value <= 1.0
}

Relation :: struct {
	id:                     i64     `json:"id"`,
	sync_id:                string  `json:"sync_id"`,
	source_id:              string  `json:"source_id"`,
	target_id:              string  `json:"target_id"`,
	relation:               string  `json:"relation"`,
	reason:                 string  `json:"reason,omitempty"`,
	evidence:               string  `json:"evidence,omitempty"`,
	confidence:             f64     `json:"confidence,omitempty"`,
	judgment_status:        string  `json:"judgment_status"`,
	marked_by_actor:        string  `json:"marked_by_actor,omitempty"`,
	marked_by_kind:         string  `json:"marked_by_kind,omitempty"`,
	marked_by_model:        string  `json:"marked_by_model,omitempty"`,
	session_id:             string  `json:"session_id,omitempty"`,
	superseded_at:          string  `json:"superseded_at,omitempty"`,
	superseded_by_sync_id:  string  `json:"superseded_by_relation_sync_id,omitempty"`,
	created_at:             string  `json:"created_at"`,
	updated_at:             string  `json:"updated_at"`,
}

Relation_Item :: struct {
	id:              i64    `json:"id"`,
	sync_id:         string `json:"sync_id"`,
	relation:        string `json:"relation"`,
	judgment_status: string `json:"judgment_status"`,
	source_id:       string `json:"source_id"`,
	source_title:    string `json:"source_title"`,
	target_id:       string `json:"target_id"`,
	target_title:    string `json:"target_title"`,
	created_at:      string `json:"created_at"`,
	updated_at:      string `json:"updated_at"`,
}

Relation_Stats :: struct {
	project:            string            `json:"project"`,
	by_relation:        map[string]int    `json:"by_relation"`,
	by_judgment_status: map[string]int    `json:"by_judgment_status"`,
	deferred:           int               `json:"deferred"`,
	dead:               int               `json:"dead"`,
}

Judge_Relation_Params :: struct {
	judgment_id:     string,
	relation:        string,
	reason:          string,
	evidence:        string,
	confidence:      f64,
	has_confidence:  bool,
	marked_by_actor: string,
	marked_by_kind:  string,
	marked_by_model: string,
	session_id:      string,
}

Judge_By_Semantic_Params :: struct {
	source_id:  string,
	target_id:  string,
	relation:   string,
	confidence: f64,
	reasoning:  string,
	model:      string,
}

Scan_Options :: struct {
	project:  string,
	limit:    int,
	apply:    bool,
	max_insert: int,
}

Scan_Result :: struct {
	project:           string `json:"project"`,
	inspected:         int    `json:"inspected"`,
	candidates_found:  int    `json:"candidates_found"`,
	already_related:   int    `json:"already_related"`,
	inserted:          int    `json:"inserted"`,
	capped:            bool   `json:"capped"`,
	dry_run:           bool   `json:"dry_run"`,
}

GetObservationBySyncID :: proc(s: ^STORE, sync_id: string) -> (Observation, string) {
	sql := cat("SELECT ", OBS_COLUMNS, " FROM observations o WHERE o.sync_id = ? AND o.deleted_at IS NULL")
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

observation_effective_project :: proc(s: ^STORE, sync_id: string) -> (string, string) {
	stmt, err := sqlite.prepare(s.db, `
		SELECT coalesce(nullif(o.project,''), s.project, '')
		FROM observations o LEFT JOIN sessions s ON s.id = o.session_id
		WHERE o.sync_id = ?`)
	if err != "" {
		return "", err
	}
	defer sqlite.finalize(&stmt)
	_ = sqlite.bind_text(&stmt, 1, sync_id)
	has, serr := sqlite.step(&stmt)
	if serr != "" {
		return "", serr
	}
	if !has {
		return "", ""
	}
	return sqlite.column_text(&stmt, 0), ""
}

validate_cross_project :: proc(s: ^STORE, source_sync, target_sync: string) -> string {
	src, serr := observation_effective_project(s, source_sync)
	if serr != "" {
		return serr
	}
	tgt, terr := observation_effective_project(s, target_sync)
	if terr != "" {
		return terr
	}
	if src != "" && tgt != "" && src != tgt {
		return "relation rejected: source and target observations are in different projects"
	}
	return ""
}

get_relation :: proc(s: ^STORE, sync_id: string) -> (Relation, string) {
	stmt, err := sqlite.prepare(s.db, `
		SELECT r.id, r.sync_id, ifnull(r.source_id,''), ifnull(r.target_id,''), r.relation,
		       ifnull(r.reason,''), ifnull(r.evidence,''), r.confidence, r.judgment_status,
		       ifnull(r.marked_by_actor,''), ifnull(r.marked_by_kind,''), ifnull(r.marked_by_model,''),
		       ifnull(r.session_id,''), ifnull(r.superseded_at,''),
		       ifnull(ss.sync_id,''), r.created_at, r.updated_at
		FROM memory_relations r
		LEFT JOIN memory_relations ss ON ss.id = r.superseded_by_relation_id
		WHERE r.sync_id = ?`)
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
		return {}, "relation not found"
	}
	rel: Relation
	rel.id = sqlite.column_int(&stmt, 0)
	rel.sync_id = sqlite.column_text(&stmt, 1)
	rel.source_id = sqlite.column_text(&stmt, 2)
	rel.target_id = sqlite.column_text(&stmt, 3)
	rel.relation = sqlite.column_text(&stmt, 4)
	rel.reason = sqlite.column_text(&stmt, 5)
	rel.evidence = sqlite.column_text(&stmt, 6)
	if !sqlite.column_is_null(&stmt, 7) {
		rel.confidence = sqlite.column_double(&stmt, 7)
	}
	rel.judgment_status = sqlite.column_text(&stmt, 8)
	rel.marked_by_actor = sqlite.column_text(&stmt, 9)
	rel.marked_by_kind = sqlite.column_text(&stmt, 10)
	rel.marked_by_model = sqlite.column_text(&stmt, 11)
	rel.session_id = sqlite.column_text(&stmt, 12)
	rel.superseded_at = sqlite.column_text(&stmt, 13)
	rel.superseded_by_sync_id = sqlite.column_text(&stmt, 14)
	rel.created_at = sqlite.column_text(&stmt, 15)
	rel.updated_at = sqlite.column_text(&stmt, 16)
	return rel, ""
}

GetRelation :: proc(s: ^STORE, sync_id: string) -> (Relation, string) {
	return get_relation(s, sync_id)
}

JudgeRelation :: proc(s: ^STORE, p: Judge_Relation_Params) -> (Relation, string) {
	if !valid_relation_verb(p.relation) {
		return {}, fmt.tprintf("invalid relation verb %q — must be one of: related, compatible, scoped, conflicts_with, supersedes, not_conflict", p.relation)
	}
	existing, gerr := get_relation(s, p.judgment_id)
	if gerr != "" {
		return {}, gerr
	}
	if cerr := validate_cross_project(s, existing.source_id, existing.target_id); cerr != "" {
		return {}, cerr
	}
	confidence: Maybe(f64)
	if p.has_confidence {
		if !valid_confidence(p.confidence) {
			return {}, "confidence must be between 0.0 and 1.0"
		}
		confidence = p.confidence
	}
	if err := sqlite.exec(s.db, "BEGIN IMMEDIATE"); err != "" {
		return {}, err
	}
	stmt, perr := sqlite.prepare(s.db, `
		UPDATE memory_relations
		SET relation = ?, reason = ?, evidence = ?, confidence = ?,
		    judgment_status = 'judged',
		    marked_by_actor = ?, marked_by_kind = ?, marked_by_model = ?,
		    session_id = ?, updated_at = datetime('now')
		WHERE sync_id = ?`)
	if perr != "" {
		_ = sqlite.exec(s.db, "ROLLBACK")
		return {}, perr
	}
	_ = sqlite.bind_text(&stmt, 1, p.relation)
	_ = bind_nullable(&stmt, 2, p.reason)
	_ = bind_nullable(&stmt, 3, p.evidence)
	if c, ok := confidence.?; ok {
		_ = sqlite.bind_double(&stmt, 4, c)
	} else {
		_ = sqlite.bind_null(&stmt, 4)
	}
	_ = bind_nullable(&stmt, 5, p.marked_by_actor)
	_ = bind_nullable(&stmt, 6, p.marked_by_kind)
	_ = bind_nullable(&stmt, 7, p.marked_by_model)
	_ = bind_nullable(&stmt, 8, p.session_id)
	_ = sqlite.bind_text(&stmt, 9, p.judgment_id)
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
	return get_relation(s, p.judgment_id)
}

JudgeBySemantic :: proc(s: ^STORE, p: Judge_By_Semantic_Params) -> (string, string) {
	if p.source_id == "" {
		return "", "source_id is required"
	}
	if p.target_id == "" {
		return "", "target_id is required"
	}
	if !valid_relation_verb(p.relation) {
		return "", fmt.tprintf("invalid relation verb %q — must be one of: related, compatible, scoped, conflicts_with, supersedes, not_conflict", p.relation)
	}
	if !valid_confidence(p.confidence) {
		return "", "confidence must be between 0.0 and 1.0"
	}
	if cerr := validate_cross_project(s, p.source_id, p.target_id); cerr != "" {
		return "", cerr
	}

	stmt, err := sqlite.prepare(s.db, `
		SELECT sync_id FROM memory_relations
		WHERE (source_id = ? AND target_id = ?) OR (source_id = ? AND target_id = ?)
		LIMIT 1`)
	if err != "" {
		return "", err
	}
	_ = sqlite.bind_text(&stmt, 1, p.source_id)
	_ = sqlite.bind_text(&stmt, 2, p.target_id)
	_ = sqlite.bind_text(&stmt, 3, p.target_id)
	_ = sqlite.bind_text(&stmt, 4, p.source_id)
	has, serr := sqlite.step(&stmt)
	if serr != "" {
		sqlite.finalize(&stmt)
		return "", serr
	}
	existing_sync := ""
	if has {
		existing_sync = sqlite.column_text(&stmt, 0)
	}
	sqlite.finalize(&stmt)

	if existing_sync == "" {
		existing_sync = util.NewSyncID("rel")
		ins, ierr := sqlite.prepare(s.db, `
			INSERT INTO memory_relations
				(sync_id, source_id, target_id, relation, judgment_status,
				 confidence, reason, marked_by_actor, marked_by_kind, marked_by_model,
				 created_at, updated_at)
			VALUES (?, ?, ?, ?, 'judged', ?, ?, 'engram', 'system', ?, datetime('now'), datetime('now'))`)
		if ierr != "" {
			return "", ierr
		}
		_ = sqlite.bind_text(&ins, 1, existing_sync)
		_ = sqlite.bind_text(&ins, 2, p.source_id)
		_ = sqlite.bind_text(&ins, 3, p.target_id)
		_ = sqlite.bind_text(&ins, 4, p.relation)
		_ = sqlite.bind_double(&ins, 5, p.confidence)
		_ = bind_nullable(&ins, 6, p.reasoning)
		_ = bind_nullable(&ins, 7, p.model)
		_, step_err := sqlite.step(&ins)
		sqlite.finalize(&ins)
		if step_err != "" {
			return "", step_err
		}
		return existing_sync, ""
	}

	upd, uerr := sqlite.prepare(s.db, `
		UPDATE memory_relations
		SET relation = ?, source_id = ?, target_id = ?, judgment_status = 'judged',
		    confidence = ?, reason = ?, marked_by_actor = 'engram', marked_by_kind = 'system',
		    marked_by_model = ?, updated_at = datetime('now')
		WHERE sync_id = ?`)
	if uerr != "" {
		return "", uerr
	}
	_ = sqlite.bind_text(&upd, 1, p.relation)
	_ = sqlite.bind_text(&upd, 2, p.source_id)
	_ = sqlite.bind_text(&upd, 3, p.target_id)
	_ = sqlite.bind_double(&upd, 4, p.confidence)
	_ = bind_nullable(&upd, 5, p.reasoning)
	_ = bind_nullable(&upd, 6, p.model)
	_ = sqlite.bind_text(&upd, 7, existing_sync)
	_, ude := sqlite.step(&upd)
	sqlite.finalize(&upd)
	if ude != "" {
		return "", ude
	}
	return existing_sync, ""
}

ListRelations :: proc(s: ^STORE, project, status: string, limit: int) -> ([]Relation_Item, string) {
	project_name, _ := util.NormalizeProject(project)
	sql := `
		SELECT r.id, r.sync_id, r.relation, r.judgment_status,
		       ifnull(r.source_id,''), ifnull(src.title,''),
		       ifnull(r.target_id,''), ifnull(tgt.title,''),
		       r.created_at, r.updated_at
		FROM memory_relations r
		LEFT JOIN observations src ON src.sync_id = r.source_id AND src.deleted_at IS NULL
		LEFT JOIN observations tgt ON tgt.sync_id = r.target_id AND tgt.deleted_at IS NULL
		WHERE 1=1`
	if project_name != "" {
		sql = cat(sql, " AND (ifnull(src.project,'') = ? OR ifnull(tgt.project,'') = ?)")
	}
	if status != "" {
		sql = cat(sql, " AND r.judgment_status = ?")
	}
	sql = cat(sql, " ORDER BY r.created_at DESC")
	if limit > 0 {
		sql = cat(sql, " LIMIT ?")
	}
	stmt, err := sqlite.prepare(s.db, sql)
	if err != "" {
		return nil, err
	}
	defer sqlite.finalize(&stmt)
	idx := 1
	if project_name != "" {
		_ = sqlite.bind_text(&stmt, idx, project_name)
		idx += 1
		_ = sqlite.bind_text(&stmt, idx, project_name)
		idx += 1
	}
	if status != "" {
		_ = sqlite.bind_text(&stmt, idx, status)
		idx += 1
	}
	if limit > 0 {
		_ = sqlite.bind_int(&stmt, idx, i64(limit))
	}
	out := make([dynamic]Relation_Item)
	for {
		has, serr := sqlite.step(&stmt)
		if serr != "" {
			delete(out)
			return nil, serr
		}
		if !has {
			break
		}
		item: Relation_Item
		item.id = sqlite.column_int(&stmt, 0)
		item.sync_id = sqlite.column_text(&stmt, 1)
		item.relation = sqlite.column_text(&stmt, 2)
		item.judgment_status = sqlite.column_text(&stmt, 3)
		item.source_id = sqlite.column_text(&stmt, 4)
		item.source_title = sqlite.column_text(&stmt, 5)
		item.target_id = sqlite.column_text(&stmt, 6)
		item.target_title = sqlite.column_text(&stmt, 7)
		item.created_at = sqlite.column_text(&stmt, 8)
		item.updated_at = sqlite.column_text(&stmt, 9)
		append(&out, item)
	}
	return exact_slice(out), ""
}

RelationStats :: proc(s: ^STORE, project: string) -> (Relation_Stats, string) {
	project_name, _ := util.NormalizeProject(project)
	stats := Relation_Stats{
		project = project_name,
		by_relation = make(map[string]int),
		by_judgment_status = make(map[string]int),
	}
	query := `
		SELECT r.relation, r.judgment_status, COUNT(*)
		FROM memory_relations r
		LEFT JOIN observations src ON src.sync_id = r.source_id AND src.deleted_at IS NULL
		LEFT JOIN observations tgt ON tgt.sync_id = r.target_id AND tgt.deleted_at IS NULL
		WHERE 1=1`
	if project_name != "" {
		query = cat(query, " AND (ifnull(src.project,'') = ? OR ifnull(tgt.project,'') = ?)")
	}
	query = cat(query, " GROUP BY r.relation, r.judgment_status")
	stmt, err := sqlite.prepare(s.db, query)
	if err != "" {
		return stats, err
	}
	defer sqlite.finalize(&stmt)
	if project_name != "" {
		_ = sqlite.bind_text(&stmt, 1, project_name)
		_ = sqlite.bind_text(&stmt, 2, project_name)
	}
	for {
		has, serr := sqlite.step(&stmt)
		if serr != "" {
			return stats, serr
		}
		if !has {
			break
		}
		relation := sqlite.column_text(&stmt, 0)
		status := sqlite.column_text(&stmt, 1)
		count := int(sqlite.column_int(&stmt, 2))
		stats.by_relation[relation] = stats.by_relation[relation] + count
		stats.by_judgment_status[status] = stats.by_judgment_status[status] + count
	}
	stats.deferred = count_table(s, "sync_apply_deferred", "apply_status = 'pending'")
	stats.dead = count_table(s, "sync_apply_deferred", "apply_status = 'dead'")
	return stats, ""
}

count_table :: proc(s: ^STORE, table: string, filter: string) -> int {
	sql := cat("SELECT COUNT(*) FROM ", table)
	if filter != "" {
		sql = cat(sql, " WHERE ", filter)
	}
	stmt, err := sqlite.prepare(s.db, sql)
	if err != "" {
		return 0
	}
	defer sqlite.finalize(&stmt)
	has, serr := sqlite.step(&stmt)
	if serr != "" || !has {
		return 0
	}
	return int(sqlite.column_int(&stmt, 0))
}

// ScanProject is a deterministic local conflict-candidate pass. It does not
// call an LLM; semantic verdicts are persisted separately with mem_compare or
// mem_judge.
ScanProject :: proc(s: ^STORE, opts: Scan_Options) -> (Scan_Result, string) {
	project_name, _ := util.NormalizeProject(opts.project)
	if project_name == "" {
		return {}, ERR_PROJECT_REQUIRED
	}
	limit := opts.limit
	if limit <= 0 {
		limit = 100
	}
	max_insert := opts.max_insert
	if max_insert <= 0 {
		max_insert = 100
	}
	result := Scan_Result{project = project_name, dry_run = !opts.apply}
	stmt, err := sqlite.prepare(s.db, `
		SELECT id, ifnull(sync_id,''), title, type, scope
		FROM observations
		WHERE LOWER(project) = ? AND deleted_at IS NULL
		ORDER BY id ASC LIMIT ?`)
	if err != "" {
		return result, err
	}
	defer sqlite.finalize(&stmt)
	_ = sqlite.bind_text(&stmt, 1, project_name)
	_ = sqlite.bind_int(&stmt, 2, i64(limit))

	type_sources := make([dynamic]struct {
		id:      i64,
		sync_id: string,
		title:   string,
		type:    string,
		scope:   string,
	})
	defer delete(type_sources)
	for {
		has, serr := sqlite.step(&stmt)
		if serr != "" {
			return result, serr
		}
		if !has {
			break
		}
		append(&type_sources, {
			id = sqlite.column_int(&stmt, 0),
			sync_id = sqlite.column_text(&stmt, 1),
			title = sqlite.column_text(&stmt, 2),
			type = sqlite.column_text(&stmt, 3),
			scope = sqlite.column_text(&stmt, 4),
		})
	}
	result.inspected = len(type_sources)

	for source in type_sources {
		fts_query := util.SanitizeFTS(source.title)
		if strings.trim_space(fts_query) == "" {
			continue
		}
		cand_stmt, cerr := sqlite.prepare(s.db, `
			SELECT o.id, ifnull(o.sync_id,''), o.title
			FROM observations_fts fts
			CROSS JOIN observations o ON o.id = fts.rowid
			WHERE observations_fts MATCH ?
			  AND o.deleted_at IS NULL
			  AND LOWER(o.project) = ?
			  AND o.id != ?
			ORDER BY bm25(observations_fts) ASC
			LIMIT 3`)
		if cerr != "" {
			continue
		}
		_ = sqlite.bind_text(&cand_stmt, 1, fts_query)
		_ = sqlite.bind_text(&cand_stmt, 2, project_name)
		_ = sqlite.bind_int(&cand_stmt, 3, source.id)
		for {
			has, serr := sqlite.step(&cand_stmt)
			if serr != "" || !has {
				break
			}
			candidate_sync := sqlite.column_text(&cand_stmt, 1)
			if candidate_sync == "" {
				continue
			}
			result.candidates_found += 1
			exists, eerr := relation_pair_exists(s, source.sync_id, candidate_sync)
			if eerr != "" {
				continue
			}
			if exists {
				result.already_related += 1
				continue
			}
			if !opts.apply || result.inserted >= max_insert {
				if result.inserted >= max_insert {
					result.capped = true
				}
				continue
			}
			if ierr := insert_pending_relation(s, source.sync_id, candidate_sync); ierr != "" {
				continue
			}
			result.inserted += 1
		}
		sqlite.finalize(&cand_stmt)
	}
	return result, ""
}

relation_pair_exists :: proc(s: ^STORE, a, b: string) -> (bool, string) {
	stmt, err := sqlite.prepare(s.db, `
		SELECT 1 FROM memory_relations
		WHERE (source_id = ? AND target_id = ?) OR (source_id = ? AND target_id = ?)
		LIMIT 1`)
	if err != "" {
		return false, err
	}
	defer sqlite.finalize(&stmt)
	_ = sqlite.bind_text(&stmt, 1, a)
	_ = sqlite.bind_text(&stmt, 2, b)
	_ = sqlite.bind_text(&stmt, 3, b)
	_ = sqlite.bind_text(&stmt, 4, a)
	has, serr := sqlite.step(&stmt)
	if serr != "" {
		return false, serr
	}
	return has, ""
}

insert_pending_relation :: proc(s: ^STORE, source_sync, target_sync: string) -> string {
	stmt, err := sqlite.prepare(s.db, `
		INSERT INTO memory_relations
			(sync_id, source_id, target_id, relation, judgment_status, created_at, updated_at)
		VALUES (?, ?, ?, 'pending', 'pending', datetime('now'), datetime('now'))`)
	if err != "" {
		return err
	}
	defer sqlite.finalize(&stmt)
	_ = sqlite.bind_text(&stmt, 1, util.NewSyncID("rel"))
	_ = sqlite.bind_text(&stmt, 2, source_sync)
	_ = sqlite.bind_text(&stmt, 3, target_sync)
	_, serr := sqlite.step(&stmt)
	return serr
}
