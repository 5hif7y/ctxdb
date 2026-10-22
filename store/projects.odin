package store

import "core:fmt"
import "core:strings"

import "../sqlite"
import "../util"

GetStats :: proc(s: ^STORE) -> (Stats, string) {
	return stats_for_project(s, "")
}

GetStatsProject :: proc(s: ^STORE, project_arg: string) -> (Stats, string) {
	project_name, _ := util.NormalizeProject(project_arg)
	if strings.trim_space(project_name) == "" {
		return {}, ERR_PROJECT_REQUIRED
	}
	return stats_for_project(s, project_name)
}

stats_for_project :: proc(s: ^STORE, project_name: string) -> (Stats, string) {
	stats: Stats
	sessions_sql := "SELECT COUNT(*) FROM sessions"
	if project_name != "" {
		sessions_sql = cat(sessions_sql, " WHERE LOWER(project) = ?")
	}
	stmt, err := sqlite.prepare(s.db, sessions_sql)
	if err != "" {
		return {}, err
	}
	if project_name != "" {
		_ = sqlite.bind_text(&stmt, 1, project_name)
	}
	if has, serr := sqlite.step(&stmt); serr == "" && has {
		stats.total_sessions = int(sqlite.column_int(&stmt, 0))
	}
	sqlite.finalize(&stmt)

	obs_sql := "SELECT COUNT(*) FROM observations WHERE deleted_at IS NULL"
	prompt_sql := "SELECT COUNT(*) FROM user_prompts"
	if project_name != "" {
		obs_sql = cat(obs_sql, " AND LOWER(project) = ?")
		prompt_sql = cat(prompt_sql, " WHERE LOWER(project) = ?")
	}
	stmt, err = sqlite.prepare(s.db, obs_sql)
	if err != "" {
		return {}, err
	}
	if project_name != "" {
		_ = sqlite.bind_text(&stmt, 1, project_name)
	}
	if has, serr := sqlite.step(&stmt); serr == "" && has {
		stats.total_observations = int(sqlite.column_int(&stmt, 0))
	}
	sqlite.finalize(&stmt)

	stmt, err = sqlite.prepare(s.db, prompt_sql)
	if err != "" {
		return {}, err
	}
	if project_name != "" {
		_ = sqlite.bind_text(&stmt, 1, project_name)
	}
	if has, serr := sqlite.step(&stmt); serr == "" && has {
		stats.total_prompts = int(sqlite.column_int(&stmt, 0))
	}
	sqlite.finalize(&stmt)

	projects_sql := "SELECT project FROM observations WHERE project IS NOT NULL AND project != '' AND deleted_at IS NULL"
	if project_name != "" {
		projects_sql = cat(projects_sql, " AND LOWER(project) = ?")
	}
	projects_sql = cat(projects_sql, " GROUP BY project ORDER BY MAX(created_at) DESC")
	stmt, err = sqlite.prepare(s.db, projects_sql)
	if err != "" {
		return {}, err
	}
	if project_name != "" {
		_ = sqlite.bind_text(&stmt, 1, project_name)
	}
	projects := make([dynamic]string)
	for {
		has, serr := sqlite.step(&stmt)
		if serr != "" {
			sqlite.finalize(&stmt)
			delete(projects)
			return {}, serr
		}
		if !has {
			break
		}
		append(&projects, sqlite.column_text(&stmt, 0))
	}
	sqlite.finalize(&stmt)
	stats.projects = projects[:]
	return stats, ""
}

ListProjectNames :: proc(s: ^STORE) -> ([]string, string) {
	stmt, err := sqlite.prepare(s.db, `
		SELECT project FROM observations WHERE project IS NOT NULL AND project != '' AND deleted_at IS NULL
		UNION
		SELECT project FROM sessions WHERE project IS NOT NULL AND project != ''
		UNION
		SELECT project FROM user_prompts WHERE project IS NOT NULL AND project != ''
		ORDER BY project`)
	if err != "" {
		return nil, err
	}
	defer sqlite.finalize(&stmt)
	out := make([dynamic]string)
	for {
		has, serr := sqlite.step(&stmt)
		if serr != "" {
			delete(out)
			return nil, serr
		}
		if !has {
			break
		}
		append(&out, sqlite.column_text(&stmt, 0))
	}
	return exact_slice(out), ""
}

ListProjectsWithStats :: proc(s: ^STORE) -> ([]ProjectStats, string) {
	names, err := ListProjectNames(s)
	if err != "" {
		return nil, err
	}
	defer delete(names)
	out := make([dynamic]ProjectStats, 0, len(names))
	obs_count := make(map[string]int)
	sess_count := make(map[string]int)
	prompt_count := make(map[string]int)
	defer delete(obs_count)
	defer delete(sess_count)
	defer delete(prompt_count)

	collect_counts(s, "SELECT project, COUNT(*) FROM observations WHERE project IS NOT NULL AND project != '' AND deleted_at IS NULL GROUP BY project", &obs_count)
	collect_counts(s, "SELECT project, COUNT(*) FROM sessions WHERE project IS NOT NULL AND project != '' GROUP BY project", &sess_count)
	collect_counts(s, "SELECT project, COUNT(*) FROM user_prompts WHERE project IS NOT NULL AND project != '' GROUP BY project", &prompt_count)

	for name in names {
		ps: ProjectStats
		ps.name = name
		ps.observation_count = obs_count[name]
		ps.session_count = sess_count[name]
		ps.prompt_count = prompt_count[name]
		append(&out, ps)
	}
	return exact_slice(out), ""
}

// FormatContext renders the "## Memory from Previous Sessions" markdown block.
FormatContext :: proc(s: ^STORE, project_name, scope: string, opts: ContextOptions) -> (string, string) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	sessions: []SessionSummary
	prompts: []Prompt
	pinned: []Observation
	observations: []Observation
	err := ""

	if opts.sessions >= 0 {
		limit := opts.sessions
		if limit == 0 {
			limit = 5
		}
		sessions, err = RecentSessions(s, project_name, limit)
		if err != "" {
			return "", err
		}
	}
	if opts.prompts >= 0 {
		limit := opts.prompts
		if limit == 0 {
			limit = 10
		}
		prompts, err = RecentPrompts(s, project_name, limit)
		if err != "" {
			return "", err
		}
	}
	if opts.pinned == 0 {
		pinned, err = PinnedObservations(s, project_name, scope)
		if err != "" {
			return "", err
		}
	}
	if opts.observations >= 0 {
		limit := opts.observations
		if limit == 0 {
			limit = s.cfg.max_context_results
		}
		observations, err = RecentUnpinnedObservations(s, project_name, scope, limit)
		if err != "" {
			return "", err
		}
	}

	if len(sessions) == 0 && len(pinned) == 0 && len(observations) == 0 && len(prompts) == 0 {
		return "", ""
	}

	strings.write_string(&b, "## Memory from Previous Sessions\n\n")
	if len(sessions) > 0 {
		strings.write_string(&b, "### Recent Sessions\n")
		for sess in sessions {
			summary := ""
			if sess.summary != "" {
				summary = cat(": ", util.TruncateRunes(sess.summary, 200))
			}
			fmt.sbprintf(&b, "- **%s** (%s)%s [%d observations]\n", sess.project, sess.started_at, summary, sess.observation_count)
		}
		strings.write_string(&b, "\n")
	}
	if len(prompts) > 0 {
		strings.write_string(&b, "### Recent User Prompts\n")
		for p in prompts {
			fmt.sbprintf(&b, "- %s: %s\n", p.created_at, util.TruncateRunes(p.content, 200))
		}
		strings.write_string(&b, "\n")
	}
	if len(pinned) > 0 {
		strings.write_string(&b, "### Pinned\n")
		for obs in pinned {
			write_observation_bullet(&b, obs, opts.compact)
		}
		strings.write_string(&b, "\n")
	}
	if len(observations) > 0 {
		strings.write_string(&b, "### Recent Observations\n")
		for obs in observations {
			write_observation_bullet(&b, obs, opts.compact)
		}
		strings.write_string(&b, "\n")
	}

	result := strings.clone(strings.to_string(b))
	delete(sessions)
	delete(prompts)
	delete(pinned)
	delete(observations)
	if opts.max_bytes > 0 && len(result) > opts.max_bytes {
		return util.TruncateRunes(result, opts.max_bytes), ""
	}
	return result, ""
}

write_observation_bullet :: proc(b: ^strings.Builder, obs: Observation, compact: bool) {
	if compact {
		fmt.sbprintf(b, "- [%s] **%s**\n", obs.type, obs.title)
	} else {
		fmt.sbprintf(b, "- [%s] **%s**: %s\n", obs.type, obs.title, util.TruncateRunes(obs.content, 300))
	}
}

// SuggestTopicKey mirrors Engram's family heuristic.
SuggestTopicKey :: proc(typ, title, content: string) -> string {
	family := infer_topic_family(typ, title, content)
	segment_source := util.StripPrivateTags(title)
	segment := normalize_topic_segment(segment_source)
	if segment == "" {
		words := strings.fields(util.StripPrivateTags(content))
		if len(words) > 8 {
			words = words[:8]
		}
		segment_source = strings.join(words, " ")
		segment = normalize_topic_segment(segment_source)
	}
	if segment == "" {
		segment = "general"
	}
	prefix := cat(family, "-")
	if strings.has_prefix(segment, prefix) {
		segment = segment[len(prefix):]
	}
	if segment == "" || segment == family {
		segment = "general"
	}
	if len(segment) > 120 - len(family) - 1 {
		segment = segment[:120 - len(family) - 1]
	}
	return cat(family, "/", segment)
}

infer_topic_family :: proc(typ, title, content: string) -> string {
	t := strings.to_lower(strings.trim_space(typ))
	switch t {
	case "architecture", "design", "adr", "refactor":
		return "architecture"
	case "bug", "bugfix", "fix", "incident", "hotfix":
		return "bug"
	case "decision":
		return "decision"
	case "pattern", "convention", "guideline":
		return "pattern"
	case "config", "setup", "infra", "infrastructure", "ci":
		return "config"
	case "discovery", "investigation", "root_cause", "root-cause":
		return "discovery"
	case "learning", "learn":
		return "learning"
	case "session_summary":
		return "session"
	}
	text := strings.to_lower(cat(title, " ", content))
	for word in ([]string{"bug", "fix", "panic", "error", "crash", "regression", "incident", "hotfix"}) {
		if strings.contains(text, word) {
			return "bug"
		}
	}
	for word in ([]string{"architecture", "design", "adr", "boundary", "hexagonal", "refactor"}) {
		if strings.contains(text, word) {
			return "architecture"
		}
	}
	for word in ([]string{"decision", "tradeoff", "chose", "choose", "decide"}) {
		if strings.contains(text, word) {
			return "decision"
		}
	}
	for word in ([]string{"pattern", "convention", "naming", "guideline"}) {
		if strings.contains(text, word) {
			return "pattern"
		}
	}
	for word in ([]string{"config", "setup", "environment", "env", "docker", "pipeline"}) {
		if strings.contains(text, word) {
			return "config"
		}
	}
	for word in ([]string{"discovery", "investigate", "investigation", "found", "root cause"}) {
		if strings.contains(text, word) {
			return "discovery"
		}
	}
	for word in ([]string{"learned", "learning"}) {
		if strings.contains(text, word) {
			return "learning"
		}
	}
	if t != "" && t != "manual" {
		return normalize_topic_segment(t)
	}
	return "topic"
}

normalize_topic_segment :: proc(s: string) -> string {
	v := strings.to_lower(strings.trim_space(s))
	if v == "" {
		return ""
	}
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	last_dash := false
	for r in v {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			strings.write_rune(&b, r)
			last_dash = false
		} else if !last_dash && b.buf != nil && len(b.buf) > 0 {
			strings.write_byte(&b, '-')
			last_dash = true
		}
	}
	out := strings.clone(strings.trim(strings.to_string(b), "-"))
	if len(out) > 100 {
		out = out[:100]
	}
	return out
}

collect_counts :: proc(s: ^STORE, query: string, target: ^map[string]int) {
	stmt, qerr := sqlite.prepare(s.db, query)
	if qerr != "" {
		return
	}
	defer sqlite.finalize(&stmt)
	for {
		has, serr := sqlite.step(&stmt)
		if serr != "" || !has {
			break
		}
		name := sqlite.column_text(&stmt, 0)
		target^[name] = int(sqlite.column_int(&stmt, 1))
	}
}
