package store

import "../sqlite"
import "../util"

AddPrompt :: proc(s: ^STORE, p: AddPromptParams) -> (i64, string) {
	content := util.StripPrivateTags(p.content)
	if content == "" {
		return 0, ERR_CONTENT_REQUIRED
	}
	project_name, perr := resolve_write_project(s, p.session_id, p.project)
	if perr != "" {
		return 0, perr
	}
	project_name, _ = util.NormalizeProject(project_name)

	if p.source_inbox_id != "" {
		stmt, err := sqlite.prepare(s.db, `
			SELECT id FROM user_prompts
			WHERE session_id = ? AND source_inbox_id = ? LIMIT 1`)
		if err == "" {
			defer sqlite.finalize(&stmt)
			_ = sqlite.bind_text(&stmt, 1, p.session_id)
			_ = sqlite.bind_text(&stmt, 2, p.source_inbox_id)
			has_row, serr := sqlite.step(&stmt)
			if serr == "" && has_row {
				return sqlite.column_int(&stmt, 0), ""
			}
		}
	}

	stmt, err := sqlite.prepare(s.db, `
		INSERT INTO user_prompts (sync_id, source_inbox_id, session_id, content, project)
		VALUES (?, ?, ?, ?, ?)`)
	if err != "" {
		return 0, err
	}
	defer sqlite.finalize(&stmt)
	_ = sqlite.bind_text(&stmt, 1, util.NewSyncID("prompt"))
	_ = bind_nullable(&stmt, 2, p.source_inbox_id)
	_ = sqlite.bind_text(&stmt, 3, p.session_id)
	_ = sqlite.bind_text(&stmt, 4, content)
	_ = bind_nullable(&stmt, 5, project_name)
	if _, serr := sqlite.step(&stmt); serr != "" {
		return 0, serr
	}
	return sqlite.last_insert_rowid(s.db), ""
}

RecentPrompts :: proc(s: ^STORE, project_arg: string, limit_arg: int) -> ([]Prompt, string) {
	project_name, _ := util.NormalizeProject(project_arg)
	limit := limit_arg
	if limit <= 0 {
		limit = 20
	}
	sql := "SELECT id, ifnull(sync_id,''), session_id, content, ifnull(project,''), created_at, ifnull(source_inbox_id,'') FROM user_prompts"
	if project_name != "" {
		sql = cat(sql, " WHERE project = ?")
	}
	sql = cat(sql, " ORDER BY created_at DESC, id DESC LIMIT ?")
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
	out := make([dynamic]Prompt)
	for {
		has_row, serr := sqlite.step(&stmt)
		if serr != "" {
			delete(out)
			return nil, serr
		}
		if !has_row {
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
		append(&out, p)
	}
	return exact_slice(out), ""
}

SearchPrompts :: proc(s: ^STORE, query, project_arg: string, limit_arg: int) -> ([]Prompt, string) {
	project_name, _ := util.NormalizeProject(project_arg)
	limit := limit_arg
	if limit <= 0 {
		limit = 10
	}
	sql := ""
	if util.HasShortFTSTerm(query) {
		sql = `SELECT p.id, ifnull(p.sync_id,''), p.session_id, p.content, ifnull(p.project,''), p.created_at, ifnull(p.source_inbox_id,'')
			FROM user_prompts p WHERE `
		terms := util.SplitSearchTerms(query)
	defer delete(terms)
		defer delete(terms)
		if len(terms) == 0 {
			return nil, ""
		}
		for i in 0 ..< len(terms) {
			if i > 0 {
				sql = cat(sql, " AND ")
			}
			sql = cat(sql, `(p.content LIKE ? ESCAPE '\' OR p.project LIKE ? ESCAPE '\')`)
		}
		if project_name != "" {
			sql = cat(sql, " AND p.project = ?")
		}
		sql = cat(sql, " ORDER BY p.created_at DESC, p.id DESC LIMIT ?")
		stmt, err := sqlite.prepare(s.db, sql)
		if err != "" {
			return nil, err
		}
		defer sqlite.finalize(&stmt)
		idx := 1
		for term in terms {
			pattern := cat("%", util.EscapeLike(term), "%")
			_ = sqlite.bind_text(&stmt, idx, pattern)
			idx += 1
			_ = sqlite.bind_text(&stmt, idx, pattern)
			idx += 1
		}
		if project_name != "" {
			_ = sqlite.bind_text(&stmt, idx, project_name)
			idx += 1
		}
		_ = sqlite.bind_int(&stmt, idx, i64(limit))
		return collect_prompts(&stmt)
	}

	sql = `SELECT p.id, ifnull(p.sync_id,''), p.session_id, p.content, ifnull(p.project,''), p.created_at, ifnull(p.source_inbox_id,'')
		FROM prompts_fts fts CROSS JOIN user_prompts p ON p.id = fts.rowid
		WHERE prompts_fts MATCH ?`
	if project_name != "" {
		sql = cat(sql, " AND p.project = ?")
	}
	sql = cat(sql, " ORDER BY fts.rank LIMIT ?")
	stmt, err := sqlite.prepare(s.db, sql)
	if err != "" {
		return nil, err
	}
	defer sqlite.finalize(&stmt)
	fts_query := util.SanitizeFTS(query)
	_ = sqlite.bind_text(&stmt, 1, fts_query)
	idx := 2
	if project_name != "" {
		_ = sqlite.bind_text(&stmt, idx, project_name)
		idx += 1
	}
	_ = sqlite.bind_int(&stmt, idx, i64(limit))
	return collect_prompts(&stmt)
}

collect_prompts :: proc(stmt: ^sqlite.STMT) -> ([]Prompt, string) {
	out := make([dynamic]Prompt)
	for {
		has_row, serr := sqlite.step(stmt)
		if serr != "" {
			delete(out)
			return nil, serr
		}
		if !has_row {
			break
		}
		p: Prompt
		p.id = sqlite.column_int(stmt, 0)
		p.sync_id = sqlite.column_text(stmt, 1)
		p.session_id = sqlite.column_text(stmt, 2)
		p.content = sqlite.column_text(stmt, 3)
		p.project = sqlite.column_text(stmt, 4)
		p.created_at = sqlite.column_text(stmt, 5)
		p.source_inbox_id = sqlite.column_text(stmt, 6)
		append(&out, p)
	}
	return exact_slice(out), ""
}
