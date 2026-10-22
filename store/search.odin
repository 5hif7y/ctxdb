package store

import "core:fmt"
import "core:strings"

import "../sqlite"
import "../util"

SEARCH_FTS_TITLE_WEIGHT :: 5.0
SEARCH_FTS_CONTENT_WEIGHT :: 1.0
SEARCH_FTS_TOPIC_WEIGHT :: 3.0
SEARCH_PINNED_BOOST :: 0.10
SEARCH_RECENCY_BOOST :: 0.06
SEARCH_RECENCY_HALF_SCORE_DAYS :: 30.0
SEARCH_STABILITY_BOOST :: 0.04
SEARCH_STABILITY_DIMINISHING_SCALE :: 4.0

scan_search_result :: proc(stmt: ^sqlite.STMT) -> SearchResult {
	sr: SearchResult
	base := scan_observation(stmt, 0)
	// Assigning the embedded fields individually keeps the struct layout
	// explicit and avoids relying on `using` assignment semantics.
	sr.id = base.id
	sr.sync_id = base.sync_id
	sr.session_id = base.session_id
	sr.type = base.type
	sr.title = base.title
	sr.content = base.content
	sr.tool_name = base.tool_name
	sr.project = base.project
	sr.scope = base.scope
	sr.topic_key = base.topic_key
	sr.revision_count = base.revision_count
	sr.duplicate_count = base.duplicate_count
	sr.last_seen_at = base.last_seen_at
	sr.review_after = base.review_after
	sr.pinned = base.pinned
	sr.created_at = base.created_at
	sr.updated_at = base.updated_at
	sr.deleted_at = base.deleted_at
	sr.superseded_by_sync_id = base.superseded_by_sync_id
	sr.rank = sqlite.column_double(stmt, 19)
	return sr
}

Search :: proc(s: ^STORE, query: string, opts: SearchOptions) -> ([]SearchResult, string) {
	switch opts.match_mode {
	case "", "all", "any":
	case:
		return nil, fmt.tprintf("invalid match_mode %q: must be \"all\" or \"any\"", opts.match_mode)
	}
	if strings.trim_space(query) == "" {
		return nil, ""
	}
	project_name, _ := util.NormalizeProject(opts.project)
	limit := opts.limit
	if limit <= 0 {
		limit = 10
	}
	if limit > s.cfg.max_search_results {
		limit = s.cfg.max_search_results
	}

	results := make([dynamic]SearchResult)
	seen := make(map[i64]bool)
	defer delete(seen)

	// Exact topic-key lookup is a direct hit before ranked search.
	if strings.contains(query, "/") {
		sql := cat("SELECT ", OBS_COLUMNS, ", -1000.0 AS rank FROM observations o WHERE o.topic_key = ? AND o.deleted_at IS NULL")
		if opts.type != "" {
			sql = cat(sql, " AND o.type = ?")
		}
		if project_name != "" {
			sql = cat(sql, " AND LOWER(o.project) = ?")
		}
		if opts.scope != "" {
			sql = cat(sql, " AND o.scope = ?")
		}
		sql = cat(sql, " ORDER BY o.updated_at DESC LIMIT ?")
		stmt, err := sqlite.prepare(s.db, sql)
		if err == "" {
			idx := 1
			_ = sqlite.bind_text(&stmt, idx, query)
			idx += 1
			if opts.type != "" {
				_ = sqlite.bind_text(&stmt, idx, opts.type)
				idx += 1
			}
			if project_name != "" {
				_ = sqlite.bind_text(&stmt, idx, project_name)
				idx += 1
			}
			if opts.scope != "" {
				_ = sqlite.bind_text(&stmt, idx, util.NormalizeScope(opts.scope))
				idx += 1
			}
			_ = sqlite.bind_int(&stmt, idx, i64(limit))
			for {
				has_row, serr := sqlite.step(&stmt)
				if serr != "" {
					sqlite.finalize(&stmt)
					delete(results)
					return nil, serr
				}
				if !has_row {
					break
				}
				sr := scan_search_result(&stmt)
				if !seen[sr.id] {
					seen[sr.id] = true
					append(&results, sr)
				}
			}
			sqlite.finalize(&stmt)
		}
	}

	if util.HasShortFTSTerm(query) {
		like_results, lerr := search_like(s, query, opts, project_name, limit)
		if lerr != "" {
			delete(results)
			return nil, lerr
		}
		defer delete(like_results)
		for sr in like_results {
			if len(results) >= limit {
				break
			}
			if !seen[sr.id] {
				seen[sr.id] = true
				append(&results, sr)
			}
		}
		return exact_slice(results), ""
	}

	fts_results, ferr := search_fts(s, query, opts, project_name, limit)
	if ferr != "" {
		delete(results)
		return nil, ferr
	}
	defer delete(fts_results)
	for sr in fts_results {
		if len(results) >= limit {
			break
		}
		if !seen[sr.id] {
			seen[sr.id] = true
			append(&results, sr)
		}
	}
	if len(results) > limit {
		return results[:limit], ""
	}
	return exact_slice(results), ""
}

search_fts :: proc(s: ^STORE, query: string, opts: SearchOptions, project_name: string, limit: int) -> ([]SearchResult, string) {
	fts_query := util.SanitizeFTS(query)
	if opts.match_mode == "any" {
		// "any" drops the implicit AND by joining quoted terms with OR.
		terms := util.SplitSearchTerms(query)
	defer delete(terms)
		defer delete(terms)
		quoted := make([dynamic]string, 0, len(terms))
		defer delete(quoted)
		for term in terms {
			escaped, _ := strings.replace_all(term, `"`, `""`)
			append(&quoted, cat(`"`, escaped, `"`))
		}
		fts_query = strings.join(quoted[:], " OR ")
	}

	raw_rank := fmt.tprintf(
		"bm25(observations_fts, %.1f, %.1f, 0.0, 0.0, 0.0, %.1f)",
		SEARCH_FTS_TITLE_WEIGHT,
		SEARCH_FTS_CONTENT_WEIGHT,
		SEARCH_FTS_TOPIC_WEIGHT,
	)
	composite_rank := fmt.tprintf(`%s * (
		1.0 +
		CASE WHEN o.pinned THEN %.2f ELSE 0.0 END +
		%.2f * (1.0 / (1.0 + MAX(0.0, julianday('now') - COALESCE(julianday(o.last_seen_at), julianday(o.updated_at), julianday(o.created_at), julianday('now'))) / %.1f)) +
		%.2f * ((MAX(0, COALESCE(o.revision_count, 0)) + MAX(0, COALESCE(o.duplicate_count, 0))) / (MAX(0, COALESCE(o.revision_count, 0)) + MAX(0, COALESCE(o.duplicate_count, 0)) + %.1f))
	)`, raw_rank, SEARCH_PINNED_BOOST, SEARCH_RECENCY_BOOST, SEARCH_RECENCY_HALF_SCORE_DAYS,
		SEARCH_STABILITY_BOOST, SEARCH_STABILITY_DIMINISHING_SCALE)

	sql := cat("SELECT ", OBS_COLUMNS, ", ", raw_rank, ` AS rank
		FROM observations_fts fts
		CROSS JOIN observations o ON o.id = fts.rowid
		WHERE observations_fts MATCH ? AND o.deleted_at IS NULL`)
	if opts.type != "" {
		sql = cat(sql, " AND o.type = ?")
	}
	if project_name != "" {
		sql = cat(sql, " AND LOWER(o.project) = ?")
	}
	if opts.scope != "" {
		sql = cat(sql, " AND o.scope = ?")
	}
	sql = cat(sql, " ORDER BY ", composite_rank, " ASC, COALESCE(NULLIF(o.sync_id, ''), printf('%020d', o.id)) ASC, o.id ASC LIMIT ?")

	stmt, err := sqlite.prepare(s.db, sql)
	if err != "" {
		return nil, err
	}
	defer sqlite.finalize(&stmt)
	idx := 1
	_ = sqlite.bind_text(&stmt, idx, fts_query)
	idx += 1
	if opts.type != "" {
		_ = sqlite.bind_text(&stmt, idx, opts.type)
		idx += 1
	}
	if project_name != "" {
		_ = sqlite.bind_text(&stmt, idx, project_name)
		idx += 1
	}
	if opts.scope != "" {
		_ = sqlite.bind_text(&stmt, idx, util.NormalizeScope(opts.scope))
		idx += 1
	}
	_ = sqlite.bind_int(&stmt, idx, i64(limit))
	return collect_search(&stmt)
}

search_like :: proc(s: ^STORE, query: string, opts: SearchOptions, project_name: string, limit: int) -> ([]SearchResult, string) {
	terms := util.SplitSearchTerms(query)
	defer delete(terms)
	if len(terms) == 0 {
		return nil, ""
	}
	sql := cat("SELECT ", OBS_COLUMNS, `, 0.0 AS rank FROM observations o WHERE o.deleted_at IS NULL AND (`)
	joiner := " AND "
	if opts.match_mode == "any" {
		joiner = " OR "
	}
	for i in 0 ..< len(terms) {
		if i > 0 {
			sql = cat(sql, joiner)
		}
		sql = cat(sql, `(o.title LIKE ? ESCAPE '\' OR o.content LIKE ? ESCAPE '\' OR o.tool_name LIKE ? ESCAPE '\' OR o.type LIKE ? ESCAPE '\' OR o.project LIKE ? ESCAPE '\' OR o.topic_key LIKE ? ESCAPE '\')`)
	}
	sql = cat(sql, ")")
	if opts.type != "" {
		sql = cat(sql, " AND o.type = ?")
	}
	if project_name != "" {
		sql = cat(sql, " AND LOWER(o.project) = ?")
	}
	if opts.scope != "" {
		sql = cat(sql, " AND o.scope = ?")
	}
	sql = cat(sql, " ORDER BY datetime(o.updated_at) DESC, o.id DESC LIMIT ?")

	stmt, err := sqlite.prepare(s.db, sql)
	if err != "" {
		return nil, err
	}
	defer sqlite.finalize(&stmt)
	idx := 1
	for term in terms {
		pattern := cat("%", util.EscapeLike(term), "%")
		for _ in 0 ..< 6 {
			_ = sqlite.bind_text(&stmt, idx, pattern)
			idx += 1
		}
	}
	if opts.type != "" {
		_ = sqlite.bind_text(&stmt, idx, opts.type)
		idx += 1
	}
	if project_name != "" {
		_ = sqlite.bind_text(&stmt, idx, project_name)
		idx += 1
	}
	if opts.scope != "" {
		_ = sqlite.bind_text(&stmt, idx, util.NormalizeScope(opts.scope))
		idx += 1
	}
	_ = sqlite.bind_int(&stmt, idx, i64(limit))
	return collect_search(&stmt)
}

collect_search :: proc(stmt: ^sqlite.STMT) -> ([]SearchResult, string) {
	out := make([dynamic]SearchResult)
	for {
		has_row, serr := sqlite.step(stmt)
		if serr != "" {
			delete(out)
			return nil, serr
		}
		if !has_row {
			break
		}
		append(&out, scan_search_result(stmt))
	}
	return exact_slice(out), ""
}

// String helpers used by MCP compact rendering.
truncate_for_search :: proc(s: string) -> string {
	return util.TruncateRunes(s, 300)
}

AsObservation :: proc(r: SearchResult) -> Observation {
	o: Observation
	o.id = r.id
	o.sync_id = r.sync_id
	o.session_id = r.session_id
	o.type = r.type
	o.title = r.title
	o.content = r.content
	o.tool_name = r.tool_name
	o.project = r.project
	o.scope = r.scope
	o.topic_key = r.topic_key
	o.revision_count = r.revision_count
	o.duplicate_count = r.duplicate_count
	o.last_seen_at = r.last_seen_at
	o.review_after = r.review_after
	o.pinned = r.pinned
	o.created_at = r.created_at
	o.updated_at = r.updated_at
	o.deleted_at = r.deleted_at
	o.superseded_by_sync_id = r.superseded_by_sync_id
	return o
}
